#include "fpga_host.h"
#include "ggml.h"
#include "quants.h"

#include <algorithm>
#include <cerrno>
#include <climits>
#include <cmath>
#include <cstdarg>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <dirent.h>
#include <fcntl.h>
#include <pthread.h>
#include <sched.h>
#include <sys/mman.h>
#include <sys/time.h>
#include <unistd.h>
#include <string>
#include <vector>

#define FPGA_LOG_FILE "/tmp/fpga_debug.log"
#define FPGA_HOST_TRACE_VERSION "zcu104-gemma3-q8-phase1m-stage-summary"

/**
 * Physical base addresses used by the Linux host to access FPGA resources.
 * MY_IP/REG/LMM point to the VPU AXI4-Full slave. DMA points to the ZDMA controller. DDR points to the high DDR staging area used before and after DMA transfers.
 */
#define MY_IP_BASE_ADDRESS 0x00000000A0000000LL
#define REG_BASE_PHYS 0x00000000A0000000LL
#define LMM_BASE_PHYS 0x00000000A0000000LL

#define DMA_BASE_PHYS 0x00000000fd500000LL
#define DMA_MMAP_SIZE 0x0000000000010000LL

#define DDR_BASE_PHYS 0x0000000800000000LL
#define DDR_MMAP_SIZE 0x0000000080000000LL

static int g_log_flush_every = 256;
static int g_log_pending_lines = 0;

/**
 * Open and reuse the FPGA debug log stream.
 * The stream is shared by all logging helpers and falls back to stderr if the file cannot be opened.
 */
static FILE *fpga_log_fp(void)
{
    static FILE *fp = nullptr;
    if (!fp)
    {
        fp = fopen(FPGA_LOG_FILE, "a");
        if (!fp)
        {
            fp = stderr;
        }

        const time_t now = time(nullptr);
        fprintf(fp, "\n============================================================\n");
        fprintf(fp, "[FPGA] host log started at %ld\n", (long)now);
        fprintf(fp, "============================================================\n");
        fflush(fp);
    }
    return fp;
}

/**
 * Convert a mapped pointer to an integer address for diagnostics.
 * This is used only for readable logs and does not perform address translation.
 */
static unsigned long long fpga_ptr_addr(const volatile void *ptr)
{
    return (unsigned long long)reinterpret_cast<uintptr_t>(ptr);
}

/**
 * Flush the FPGA log according to the current flush policy.
 * force_flush is used for errors and hardware-failure logs that must be visible immediately.
 */
static void fpga_log_finish_line(FILE *fp, bool force_flush)
{
    g_log_pending_lines++;
    if (force_flush || g_log_flush_every <= 1 || g_log_pending_lines >= g_log_flush_every)
    {
        fflush(fp);
        g_log_pending_lines = 0;
    }
}

/**
 * Write one tagged FPGA log line.
 * enabled gates optional log families, tag selects the log prefix, force_flush controls flushing, and fmt plus variadic arguments form the message.
 */
static void fpga_log_line(bool enabled, const char *tag, bool force_flush, const char *fmt, ...)
{
    if (!enabled)
    {
        return;
    }

    FILE *fp = fpga_log_fp();
    fprintf(fp, "[FPGA][%s] ", tag);
    va_list ap;
    va_start(ap, fmt);
    vfprintf(fp, fmt, ap);
    va_end(ap);
    fprintf(fp, "\n");
    fpga_log_finish_line(fp, force_flush);
}

#define LOGI(fmt, ...) fpga_log_line(true, "INFO", false, fmt, ##__VA_ARGS__)
#define LOGE(fmt, ...) fpga_log_line(true, "ERROR", true, fmt, ##__VA_ARGS__)
#define LOGW(fmt, ...) fpga_log_line(true, "WARNING", true, fmt, ##__VA_ARGS__)
#define LOGDMA(fmt, ...) fpga_log_line(kLogDmaDetail &&g_dma_timing_enabled, "DMA", true, fmt, ##__VA_ARGS__)
#define LOGIP(fmt, ...) fpga_log_line(kLogTileDetail &&g_ip_timing_enabled, "IPTIME", true, fmt, ##__VA_ARGS__)
#define LOGSTAGE(fmt, ...) fpga_log_line(g_stage_summary_enabled, "STAGE", false, fmt, ##__VA_ARGS__)
#define LOGTILE(fmt, ...) fpga_log_line(kLogTileDetail, "TILE", false, fmt, ##__VA_ARGS__)
#define LOGTOKEN(fmt, ...) fpga_log_line(true, "TOKEN", true, fmt, ##__VA_ARGS__)
#define LOGDATA(fmt, ...) fpga_log_line(g_trace_data_enabled, "DATA", true, fmt, ##__VA_ARGS__)
#define LOGSELF(fmt, ...) fpga_log_line(true, "SELFTEST", true, fmt, ##__VA_ARGS__)
#define LOGRESULT(fmt, ...) fpga_log_line(g_result_audit_enabled, "RESULT", false, fmt, ##__VA_ARGS__)
#define LOGLAYOUT(fmt, ...) fpga_log_line(g_layout_audit_enabled, "LAYOUT", false, fmt, ##__VA_ARGS__)
#define LOGMISMATCH(fmt, ...) fpga_log_line(true, "MISMATCH", true, fmt, ##__VA_ARGS__)
#define LOGHWFAIL(fmt, ...) fpga_log_line(true, "HW_FAIL", true, fmt, ##__VA_ARGS__)

/**
 * Runtime mapping sizes and local VPU register offsets.
 * These constants must match the RTL address decoder in AXI4_Mapping.v; otherwise register writes or memory-window transfers will target the wrong hardware resource.
 */
static constexpr uint64_t VPU_BASE_PHYS = MY_IP_BASE_ADDRESS;
static constexpr size_t VPU_REG_MMAP_MIN = 0x00001000;
static constexpr size_t VPU_DEV_MEM_MMAP = 0x10000000;
static constexpr size_t DDR_DEV_MEM_MMAP = 0x80000000;

static constexpr uint32_t REG_CTRL = 0x00000000;
static constexpr uint32_t REG_STATUS = 0x00000010;
static constexpr uint32_t REG_ROWS = 0x00000020;
static constexpr uint32_t REG_COLS = 0x00000030;
static constexpr uint32_t REG_COL_BEATS = 0x00000040;
static constexpr uint32_t REG_SCALE = 0x00000050;
static constexpr uint32_t REG_MODE = 0x00000060;
static constexpr uint32_t REG_LIMITS = 0x00000070;
static constexpr uint32_t REG_PROGRESS = 0x00000080;
static constexpr uint32_t REG_CAPS = 0x00000090;

static constexpr uint32_t CTRL_START = 0x00000001;
static constexpr uint32_t CTRL_CLEAR_DONE = 0x00000002;
static constexpr uint32_t STATUS_DONE = 0x00000001;
static constexpr uint32_t STATUS_BUSY = 0x00000002;
static constexpr uint32_t STATUS_ERROR = 0x00000004;

/**
 * RTL-facing local memory windows.
 * ACT_BASE receives quantized activation beats, WEIGHT_BASE receives Q8_0 weight beats, and RESULT_BASE exposes INT32 partial results produced by Matrix_Vector_Multiplication.v and PMAU_Full.v.
 */
static constexpr uint32_t ACT_BASE = 0x00010000;
static constexpr uint32_t ACT_END = 0x00020000;
static constexpr uint32_t WEIGHT_BASE = 0x00100000;
static constexpr uint32_t WEIGHT_END = 0x00200000;
static constexpr uint32_t RESULT_BASE = 0x00200000;
static constexpr uint32_t RESULT_END = 0x00210000;
static constexpr size_t DDR_REQUIRED_BYTES = RESULT_END;

/**
 * VPU datapath geometry mirrored from RTL parameters.
 * Each hardware beat carries 16 INT8 lanes. One Q8_0 block has 32 values, so one block is transmitted as two 128-bit beats.
 */
static constexpr int VPU_NUM_LANES = 16;
static constexpr int VPU_QK8_0 = 32;
static constexpr int VPU_BLOCK_BEATS = VPU_QK8_0 / VPU_NUM_LANES;
static constexpr int VPU_RESULT_PACK_LANES = 4;
static constexpr int VPU_PACKED_Q8_MAX_BLOCKS = 64;
static constexpr int VPU_DEFAULT_ROWS = 256;
static constexpr int VPU_DEFAULT_BEATS = 128;
static constexpr int VPU_DEFAULT_COLS = VPU_DEFAULT_BEATS * VPU_NUM_LANES;
static constexpr int VPU_DEFAULT_RESULT_WORDS =
    (VPU_DEFAULT_ROWS * VPU_PACKED_Q8_MAX_BLOCKS + VPU_RESULT_PACK_LANES - 1) /
    VPU_RESULT_PACK_LANES;
static constexpr uint32_t VPU_MODE_PACKED_Q8 = 0x00000001;
static constexpr uint32_t VPU_FP16_ONE = 0x00003C00;

static constexpr long long FPGA_DEFAULT_DMA_TIMEOUT_US = 5000000LL;
static constexpr long long FPGA_DEFAULT_IP_TIMEOUT_US = 5000000LL;
static constexpr int FPGA_DEFAULT_STATUS_EVERY = 128;
static constexpr int FPGA_DEFAULT_PROFILE_EVERY = 128;
static constexpr long long FPGA_DEFAULT_LARGE_MATRIX_MIN_MACS = 1000000LL;
static constexpr bool kLogTileDetail = false;
static constexpr bool kLogPollStatus = false;
static constexpr bool kLogDmaDetail = false;
static constexpr bool kDefaultStageSummary = true;
static constexpr bool kPreferZdmaPath = true;
static constexpr bool FPGA_ENABLE_ACTIVATION_CACHE = false;
static constexpr bool FPGA_DEFAULT_DEBUG_COMPARE = false;
static constexpr int FPGA_DEFAULT_DEBUG_COMPARE_LIMIT = 64;
static constexpr int64_t FPGA_MAX_SAFE_OFFLOAD_N = 65536;
static constexpr bool kDefaultFpgaResultAudit = false;
static constexpr int kFpgaResultAuditMaxCalls = 80;
static constexpr bool kDefaultFpgaLayoutAudit = false;
static constexpr int kFpgaLayoutAuditMaxCalls = 32;
static constexpr bool kForceAllMatmulCpu = false;
static constexpr bool kFpgaOnlyFFN = false;
static constexpr bool kFpgaOnlyAttentionProjection = false;
static constexpr bool kDisableFpgaForPrefill = false;
static constexpr bool kDisableFpgaForDecode = false;
static constexpr bool kForceDirectVpuPathForAudit = false;
static constexpr bool kAbortOnNonFiniteResult = true;
static constexpr bool kSanitizeNonFiniteWeightScales = true;
static constexpr int kNonFiniteWeightScaleLogLimit = 32;
static constexpr float kFp16MaxFinite = 65504.0f;
static constexpr int kNonFiniteActivationScaleLogLimit = 32;

/**
 * 32-bit register word used for ZDMA MMIO register access.
 * The typedef keeps the DMA register structure explicit about hardware register width.
 */
typedef uint32_t U32;

/**
 * Memory-mapped layout of the ZDMA controller registers used by the host driver.
 * The padding fields preserve hardware offsets so writes such as ZDMA_CH_CTRL2 and descriptor words land on the correct ZDMA registers.
 */
struct dma_ctrl
{
    U32 ZDMA_ERR_CTRL;
    U32 dmy0[63];
    U32 ZDMA_CH_ISR;
    U32 ZDMA_CH_IMR;
    U32 ZDMA_CH_IEN;
    U32 ZDMA_CH_IDS;
    U32 ZDMA_CH_CTRL0;
    U32 ZDMA_CH_CTRL1;
    U32 ZDMA_CH_FCI;
    U32 ZDMA_CH_STATUS;
    U32 ZDMA_CH_DATA_ATTR;
    U32 ZDMA_CH_DSCR_ATTR;
    U32 ZDMA_CH_SRC_DSCR_WORD0;
    U32 ZDMA_CH_SRC_DSCR_WORD1;
    U32 ZDMA_CH_SRC_DSCR_WORD2;
    U32 ZDMA_CH_SRC_DSCR_WORD3;
    U32 ZDMA_CH_DST_DSCR_WORD0;
    U32 ZDMA_CH_DST_DSCR_WORD1;
    U32 ZDMA_CH_DST_DSCR_WORD2;
    U32 ZDMA_CH_DST_DSCR_WORD3;
    U32 ZDMA_CH_WR_ONLY_WORD0;
    U32 ZDMA_CH_WR_ONLY_WORD1;
    U32 ZDMA_CH_WR_ONLY_WORD2;
    U32 ZDMA_CH_WR_ONLY_WORD3;
    U32 ZDMA_CH_SRC_START_LSB;
    U32 ZDMA_CH_SRC_START_MSB;
    U32 ZDMA_CH_DST_START_LSB;
    U32 ZDMA_CH_DST_START_MSB;
    U32 dmy1[9];
    U32 ZDMA_CH_RATE_CTRL;
    U32 ZDMA_CH_IRQ_SRC_ACCT;
    U32 ZDMA_CH_IRQ_DST_ACCT;
    U32 dmy2[26];
    U32 ZDMA_CH_CTRL2;
};

static_assert(offsetof(dma_ctrl, ZDMA_CH_ISR) == 0x100, "unexpected ZDMA_CH_ISR offset");
static_assert(offsetof(dma_ctrl, ZDMA_CH_CTRL2) == 0x200, "unexpected ZDMA_CH_CTRL2 offset");

static constexpr uint32_t ZDMA_STATUS_STATE_MASK = 0x00000003;
static constexpr uint32_t ZDMA_CTRL2_START = 0x00000001;
static constexpr uint32_t ZDMA_DATA_ATTR_AXCACHE = 0x04C3D30F;

/**
 * Q8_0 block layout shared with ggml quantized tensors.
 * d is the FP16 scale for the 32 INT8 values in qs. The VPU receives qs as hardware input, while the host uses d later to reconstruct F32 output contributions.
 */
typedef struct
{
    uint16_t d;
    int8_t qs[VPU_QK8_0];
} block_q8_0_t;

static_assert(sizeof(block_q8_0_t) == sizeof(uint16_t) + VPU_QK8_0, "unexpected q8_0 block layout");

/**
 * Per-stage timing and data-volume counters.
 * A stage corresponds to one accepted ggml matmul tensor handled by the FPGA path. These fields feed the [FPGA][STAGE] log line.
 */
typedef struct
{
    long long prep_us;
    long long dma_act_us;
    long long dma_weight_us;
    long long dma_result_us;
    long long ip_compute_us;
    long long host_accum_us;
    size_t activation_bytes;
    size_t weight_bytes;
    size_t result_bytes;
    long long vpu_runs;
    long long nonfinite_weight_scales;
    long long sanitized_weight_scales;
    long long nonfinite_activation_scales;
    long long activation_scale_overflows;
} fpga_stage_totals_t;

/**
 * Scratch buffers reused across FPGA matmul calls.
 * The vectors hold quantized activation blocks, scales, raw INT32 partials returned by RTL, and F32 accumulators before writing the ggml destination tensor.
 */
typedef struct
{
    std::vector<block_q8_0_t> act_blocks_all;
    std::vector<float> act_scales;
    std::vector<float> weight_scales;
    std::vector<int32_t> partial;
    std::vector<float> accum;
    const struct ggml_tensor *cached_src1;
    const void *cached_src1_data;
    int64_t cached_m;
    int64_t cached_k;
    size_t cached_nb0;
    size_t cached_nb1;
    bool activation_cache_valid;
} fpga_scratch_t;

typedef struct
{
    const struct ggml_tensor *tensor;
    const void *data;
    int64_t k;
    int64_t n;
    size_t nb0;
    size_t nb1;
    bool finite;
    long long bad_count;
} fpga_weight_scale_preflight_entry_t;

/**
 * Summary entry used to remember the slowest observed FPGA stages.
 * The cleanup path prints these entries so performance bottlenecks can be reviewed after inference.
 */
typedef struct
{
    char tensor[96];
    char phase[8];
    int layer;
    long long vpu_runs;
    double total_ms;
    double prep_ms;
    double host_accum_ms;
    double ip_compute_ms;
    double transfer_in_ms;
    double transfer_out_ms;
} fpga_top_entry_t;

/**
 * Process-wide driver state.
 * g_dma, g_vpu, and g_ddr are the active memory mappings used to reach the ZDMA controller, the RTL VPU local-memory map, and the DDR staging area. The counters below them record accepted FPGA calls, CPU fallback decisions, transfer time, VPU execution time, and numerical-audit results for the final debug summary.
 */
static int g_mem_fd = -1;
static volatile dma_ctrl *g_dma = nullptr;
static volatile uint8_t *g_vpu = nullptr;
static uint8_t *g_ddr = nullptr;
static void *g_dma_map_base = nullptr;
static void *g_vpu_map_base = nullptr;
static void *g_ddr_map_base = nullptr;
static size_t g_dma_map_size = 0;
static size_t g_vpu_map_size = 0;
static size_t g_ddr_map_size = 0;
static std::string g_dma_map_source;
static std::string g_vpu_map_source;
static std::string g_ddr_map_source;
static pthread_mutex_t g_mutex = PTHREAD_MUTEX_INITIALIZER;
static fpga_scratch_t g_scratch;
static std::vector<fpga_weight_scale_preflight_entry_t> g_weight_scale_preflight_cache;

static long long g_fpga_start_us = 0;
static long long g_fpga_count = 0;
static long long g_fpga_vpu_runs = 0;
static long long g_reject_count = 0;
static long long g_fpga_allowed_count = 0;
static long long g_cpu_fallback_count = 0;
static long long g_fpga_skipped_token_embd_count = 0;
static long long g_fpga_skipped_large_n_count = 0;
static long long g_fpga_skipped_not_allowlisted_count = 0;
static long long g_prefill_calls = 0;
static long long g_decode_calls = 0;
static long long g_prefill_cpu_fallback = 0;
static long long g_decode_cpu_fallback = 0;
static long long g_prefill_mismatch_count = 0;
static long long g_decode_mismatch_count = 0;
static long long g_nonfinite_result_count = 0;
static long long g_nonfinite_weight_scale_count = 0;
static long long g_sanitized_weight_scale_count = 0;
static int g_nonfinite_weight_scale_log_count = 0;
static long long g_nonfinite_activation_scale_count = 0;
static long long g_activation_scale_overflow_count = 0;
static int g_nonfinite_activation_scale_log_count = 0;
static int g_activation_scale_overflow_log_count = 0;
static long long g_total_prep_us = 0;
static long long g_total_transfer_in_us = 0;
static long long g_total_ip_compute_us = 0;
static long long g_total_transfer_out_us = 0;
static long long g_total_host_accum_us = 0;
static long long g_total_stage_us = 0;
static long long g_prefill_total_us = 0;
static long long g_decode_total_us = 0;
static long long g_activation_cache_hits = 0;
static long long g_activation_cache_misses = 0;
static long long g_last_token_us = 0;
static int g_last_token_seq = INT_MIN;
static long long g_token_matmuls = 0;
static int g_debug_compare_count = 0;
static int g_result_audit_count = 0;
static int g_result_audit_first_count = 0;
static int g_result_audit_layer0_count = 0;
static int g_result_audit_last_layer_count = 0;
static int g_result_audit_decode_count = 0;
static int g_layout_audit_count = 0;
static fpga_top_entry_t g_top_slowest[10] = {};

static int g_vpu_max_rows = VPU_DEFAULT_ROWS;
static int g_vpu_max_beats = VPU_DEFAULT_BEATS;
static int g_vpu_max_cols = VPU_DEFAULT_COLS;
static int g_packed_q8_supported = 0;
static int g_packed_q8_max_blocks = 1;
static int g_packed_q8_result_words = VPU_DEFAULT_RESULT_WORDS;
static int g_compact_weight_layout = 0;

static bool g_dma_timing_enabled = true;
static bool g_ip_timing_enabled = true;
static bool g_stage_summary_enabled = kDefaultStageSummary;
static bool g_status_stderr = false;
static bool g_trace_data_enabled = false;
static bool g_debug_compare_enabled = FPGA_DEFAULT_DEBUG_COMPARE;
static bool g_result_audit_enabled = kDefaultFpgaResultAudit;
static bool g_layout_audit_enabled = kDefaultFpgaLayoutAudit;
static bool g_cleanup_done = false;
static bool g_atexit_registered = false;
static bool g_abort_on_cpu_fallback = true;
static bool g_ddr_msync_unsupported = false;
static bool g_use_zdma_path = false;
static bool g_zdma_selftest_passed = false;
static int g_profile_every = FPGA_DEFAULT_PROFILE_EVERY;
static int g_ip_status_every = FPGA_DEFAULT_STATUS_EVERY;
static int g_debug_compare_limit = FPGA_DEFAULT_DEBUG_COMPARE_LIMIT;
static long long g_dma_timeout_us = FPGA_DEFAULT_DMA_TIMEOUT_US;
static long long g_ip_timeout_us = FPGA_DEFAULT_IP_TIMEOUT_US;
static long long g_large_matrix_min_macs = FPGA_DEFAULT_LARGE_MATRIX_MIN_MACS;
static double g_fpga_clock_mhz = 0.0;

static int g_current_layer_id = 0;
int g_current_seq_pos = 0;
static int g_is_attention_op = 0;

/**
 * Transformer tensor categories accepted by the FPGA offload path.
 * The category is derived from the tensor name and prevents unrelated tensors from being sent to RTL.
 */
enum fpga_tensor_category_t
{
    FPGA_TENSOR_UNKNOWN = -1,
    FPGA_TENSOR_ATTN_Q = 0,
    FPGA_TENSOR_ATTN_K,
    FPGA_TENSOR_ATTN_V,
    FPGA_TENSOR_ATTN_OUTPUT,
    FPGA_TENSOR_FFN_GATE,
    FPGA_TENSOR_FFN_UP,
    FPGA_TENSOR_FFN_DOWN,
    FPGA_TENSOR_CATEGORY_COUNT
};

enum fpga_compare_status_t
{
    FPGA_COMPARE_PASS = 0,
    FPGA_COMPARE_SKIPPED,
    FPGA_COMPARE_SUBSTITUTED,
    FPGA_COMPARE_MISMATCH_KEPT
};

/**
 * Reason codes used when a tensor is intentionally kept on the CPU path.
 * The counters distinguish output/logits tensors, tensors that exceed current VPU limits, and tensors outside the transformer allowlist.
 */
enum fpga_skip_kind_t
{
    FPGA_SKIP_NONE = 0,
    FPGA_SKIP_LOGITS_OUTPUT,
    FPGA_SKIP_LARGE_N,
    FPGA_SKIP_NOT_ALLOWLISTED,
    FPGA_SKIP_QUALITY_GUARD
};

static bool g_debug_compare_seen_category[FPGA_TENSOR_CATEGORY_COUNT] = {};
static bool g_debug_compare_seen_last_layer_ffn_down = false;
static bool g_logged_skip_logits_output = false;
static bool g_logged_skip_large_n = false;
static bool g_logged_skip_not_allowlisted = false;
static bool g_logged_skip_safe_mode = false;
static bool g_logged_skip_quality_guard = false;

/**
 * Return a monotonic-enough wall-clock timestamp in microseconds for profiling.
 * The driver uses this value to split prep, DMA, IP compute, result copy, and host accumulation time.
 */
static long long now_us(void)
{
    struct timeval tv;
    gettimeofday(&tv, nullptr);
    return (long long)tv.tv_sec * 1000000LL + (long long)tv.tv_usec;
}

/**
 * Read a boolean environment flag that is enabled by common true values.
 * name is the environment variable name checked at runtime.
 */
static bool env_flag_enabled(const char *name)
{
    const char *value = getenv(name);
    if (!value || value[0] == '\0')
    {
        return false;
    }
    return strcmp(value, "1") == 0 ||
           strcmp(value, "true") == 0 ||
           strcmp(value, "TRUE") == 0 ||
           strcmp(value, "yes") == 0 ||
           strcmp(value, "YES") == 0 ||
           strcmp(value, "on") == 0 ||
           strcmp(value, "ON") == 0;
}

/**
 * Read a boolean environment flag that is disabled by common false values.
 * name is the environment variable name checked at runtime.
 */
static bool env_flag_disabled(const char *name)
{
    const char *value = getenv(name);
    if (!value || value[0] == '\0')
    {
        return false;
    }
    return strcmp(value, "0") == 0 ||
           strcmp(value, "false") == 0 ||
           strcmp(value, "FALSE") == 0 ||
           strcmp(value, "no") == 0 ||
           strcmp(value, "NO") == 0 ||
           strcmp(value, "off") == 0 ||
           strcmp(value, "OFF") == 0;
}

/**
 * Read an integer environment override with range validation.
 * fallback is used when the variable is absent or invalid; min_value and max_value protect the driver from unsafe settings.
 */
static int env_int_value(const char *name, int fallback, int min_value, int max_value)
{
    const char *value = getenv(name);
    if (!value || value[0] == '\0')
    {
        return fallback;
    }
    char *end = nullptr;
    errno = 0;
    const long parsed = strtol(value, &end, 0);
    if (errno != 0 || end == value)
    {
        return fallback;
    }
    return (int)std::max<long>(min_value, std::min<long>(parsed, max_value));
}

/**
 * Read a 64-bit integer environment override with range validation.
 * This is used for timeout and profiling thresholds that can exceed 32-bit range.
 */
static long long env_int64_value(const char *name, long long fallback, long long min_value, long long max_value)
{
    const char *value = getenv(name);
    if (!value || value[0] == '\0')
    {
        return fallback;
    }
    char *end = nullptr;
    errno = 0;
    const long long parsed = strtoll(value, &end, 0);
    if (errno != 0 || end == value)
    {
        return fallback;
    }
    return std::max(min_value, std::min(parsed, max_value));
}

/**
 * Read a floating-point environment override with range validation.
 * The value is used for optional profiling metadata such as the FPGA clock frequency.
 */
static double env_double_value(const char *name, double fallback, double min_value, double max_value)
{
    const char *value = getenv(name);
    if (!value || value[0] == '\0')
    {
        return fallback;
    }
    char *end = nullptr;
    errno = 0;
    const double parsed = strtod(value, &end);
    if (errno != 0 || end == value)
    {
        return fallback;
    }
    return std::max(min_value, std::min(parsed, max_value));
}

/**
 * Log a fatal FPGA driver error and abort the process.
 * The driver uses this when silent CPU fallback would make correctness or performance measurements invalid.
 */
static void fpga_fatal(const char *fmt, ...)
{
    FILE *fp = fpga_log_fp();
    fprintf(fp, "[FPGA][ERROR] ");
    va_list ap;
    va_start(ap, fmt);
    vfprintf(fp, fmt, ap);
    va_end(ap);
    fprintf(fp, "\n");
    fflush(fp);

    fprintf(stderr, "[FPGA][ERROR] ");
    va_start(ap, fmt);
    vfprintf(stderr, fmt, ap);
    va_end(ap);
    fprintf(stderr, "\n");
    fflush(stderr);
    abort();
}

/**
 * Issue a full memory fence around MMIO and DMA-visible memory operations.
 * This keeps CPU stores ordered before the hardware observes control or data registers.
 */
static inline void mmio_fence(void)
{
    __sync_synchronize();
}

/**
 * Report whether the ZDMA register window is mapped and usable.
 */
static inline bool dma_is_mapped(void)
{
    return g_dma != nullptr && g_dma_map_base != nullptr && g_dma_map_base != MAP_FAILED;
}

/**
 * Report whether the VPU register/local-memory window is mapped and usable.
 */
static inline bool vpu_is_mapped(void)
{
    return g_vpu != nullptr && g_vpu_map_base != nullptr && g_vpu_map_base != MAP_FAILED;
}

/**
 * Report whether the DDR staging window is mapped and usable.
 */
static inline bool ddr_is_mapped(void)
{
    return g_ddr != nullptr && g_ddr_map_base != nullptr && g_ddr_map_base != MAP_FAILED;
}

/**
 * Read one 32-bit value from the VPU MMIO space.
 * off is an RTL register or local-memory offset relative to the VPU base.
 */
static inline uint32_t vpu_rd32(uint32_t off)
{
    return *(volatile uint32_t *)(g_vpu + off);
}

/**
 * Write one 32-bit value to the VPU MMIO space.
 * off is an RTL register or local-memory offset relative to the VPU base; val is the value observed by AXI4_Mapping.v.
 */
static inline void vpu_wr32(uint32_t off, uint32_t val)
{
    *(volatile uint32_t *)(g_vpu + off) = val;
}

/**
 * Round value up to the next multiple of alignment.
 * Used before clearing or syncing hardware-visible windows.
 */
static size_t align_up_size(size_t value, size_t alignment)
{
    return (value + alignment - 1U) & ~(alignment - 1U);
}

/**
 * Check that a byte range stays within a half-open address interval.
 * The driver uses this before touching ACT, WEIGHT, RESULT, or DDR windows.
 */
static bool range_fits(uint32_t off, size_t bytes, uint32_t begin, uint32_t end)
{
    return bytes > 0 && off >= begin && off < end && bytes <= (size_t)(end - off);
}

/**
 * Check whether a local offset and byte count fit inside the mapped DDR staging window.
 */
static bool ddr_range_fits(uint32_t off, size_t bytes)
{
    return ddr_is_mapped() && bytes > 0 && (uint64_t)off + (uint64_t)bytes <= (uint64_t)g_ddr_map_size;
}

/**
 * Return a host pointer into the DDR staging mapping after range validation.
 * off is the local DDR offset, bytes is the accessible length.
 */
[[maybe_unused]] static uint8_t *ddr_ptr(uint32_t off, size_t bytes)
{
    if (!ddr_range_fits(off, bytes))
    {
        fpga_fatal("DDR mapped range overflow off=0x%08x bytes=%zu mapped_size=0x%zx", off, bytes, g_ddr_map_size);
    }
    return g_ddr + off;
}

/**
 * Check whether a local VPU offset and byte count fit inside an RTL-visible memory window.
 */
static bool vpu_range_fits(uint32_t off, size_t bytes, uint32_t begin, uint32_t end)
{
    return vpu_is_mapped() && range_fits(off, bytes, begin, end);
}

/**
 * Return the active row stride used by the RTL-visible WEIGHT window.
 * Current RTL advertises REG_CAPS[1] and uses compact active-stride layout:
 * row_stride = active_col_beats.  Older bitstreams without that capability use
 * the legacy padded stride: row_stride = MAX_COL_BEATS.
 */
static inline int weight_row_stride_beats(int active_col_beats)
{
    return g_compact_weight_layout ? active_col_beats : g_vpu_max_beats;
}

/**
 * Compute the RTL-visible WEIGHT window offset for one row and one 128-bit beat.
 */
static inline uint32_t weight_word_offset(int row, int beat, int active_col_beats)
{
    const int row_stride = weight_row_stride_beats(active_col_beats);
    return WEIGHT_BASE + (uint32_t)(row * row_stride + beat) * 16U;
}

/**
 * Compute the byte span that must be staged for the current WEIGHT tile.
 */
static inline size_t weight_span_bytes_for_rows(int rows, int active_col_beats)
{
    if (rows <= 0 || active_col_beats <= 0)
    {
        return 0;
    }

    const int row_stride = weight_row_stride_beats(active_col_beats);
    return (size_t)(((rows - 1) * row_stride) + active_col_beats) * 16U;
}

/**
 * Compute the RTL-visible ACT window offset for one activation 128-bit beat.
 * The VPU reads this window as the quantized activation vector input.
 */
static inline uint32_t act_word_offset(int beat)
{
    return ACT_BASE + (uint32_t)beat * 16U;
}

/**
 * Compute the RTL-visible RESULT window offset for one packed 128-bit result word.
 * Each word can contain four INT32 partial results in packed Q8 mode.
 */
static inline uint32_t result_word_offset(uint32_t result_word)
{
    return RESULT_BASE + result_word * 16U;
}

/**
 * Pack four adjacent INT8 lane bytes into one little-endian 32-bit word.
 * This is the host-side representation of one quarter of a 128-bit AXI beat.
 */
static inline uint32_t load_le32_from_i8(const int8_t *ptr)
{
    uint32_t value = 0;
    memcpy(&value, ptr, sizeof(value));
    return value;
}

/**
 * Write a 32-bit word directly into a VPU local memory window through MMIO.
 */
static inline void vpu_mem_wr32(uint32_t off, uint32_t val)
{
    *(volatile uint32_t *)(g_vpu + off) = val;
}

/**
 * Read a 32-bit word directly from a VPU local memory window through MMIO.
 */
static inline uint32_t vpu_mem_rd32(uint32_t off)
{
    return *(volatile uint32_t *)(g_vpu + off);
}

/**
 * Write a 32-bit word into the DDR staging buffer used by ZDMA.
 */
static inline void ddr_mem_wr32(uint32_t off, uint32_t val)
{
    *(volatile uint32_t *)(g_ddr + off) = val;
}

/**
 * Read a 32-bit word from the DDR staging buffer used by ZDMA.
 */
static inline uint32_t ddr_mem_rd32(uint32_t off)
{
    return *(volatile uint32_t *)(g_ddr + off);
}

/**
 * Write one 128-bit INT8 beat directly into the VPU local window.
 * lanes contains 16 INT8 values that RTL will treat as activation or weight data depending on the offset.
 */
static void vpu_write_i8x16(uint32_t off, const int8_t *lanes)
{
    if (!vpu_is_mapped() || (off & 0xFU) != 0U)
    {
        fpga_fatal("invalid VPU write16 off=0x%08x", off);
    }
    for (uint32_t lane_word = 0; lane_word < 4U; ++lane_word)
    {
        vpu_mem_wr32(off + lane_word * 4U, load_le32_from_i8(lanes + lane_word * 4U));
    }
    mmio_fence();
}

/**
 * Write one 128-bit INT8 beat into the DDR staging window.
 * The staged beat is later copied by ZDMA into ACT_BASE or WEIGHT_BASE for RTL processing.
 */
static void ddr_write_i8x16(uint32_t off, const int8_t *lanes)
{
    if (!ddr_range_fits(off, 16U) || (off & 0xFU) != 0U)
    {
        fpga_fatal("invalid DDR write16 off=0x%08x", off);
    }
    for (uint32_t lane_word = 0; lane_word < 4U; ++lane_word)
    {
        ddr_mem_wr32(off + lane_word * 4U, load_le32_from_i8(lanes + lane_word * 4U));
    }
    mmio_fence();
}

/**
 * Read one 128-bit result word directly from the VPU local window.
 * out receives four INT32 lanes produced by the RTL result BRAM.
 */
static void vpu_read_i32x4(uint32_t off, int32_t out[4])
{
    if (!vpu_is_mapped() || (off & 0xFU) != 0U)
    {
        fpga_fatal("invalid VPU read16 off=0x%08x", off);
    }
    for (uint32_t lane_word = 0; lane_word < 4U; ++lane_word)
    {
        out[lane_word] = (int32_t)vpu_mem_rd32(off + lane_word * 4U);
    }
    mmio_fence();
}

/**
 * Read one 128-bit result word from the DDR staging window.
 * This path is used after ZDMA copies RESULT_BASE back from the VPU.
 */
static void ddr_read_i32x4(uint32_t off, int32_t out[4])
{
    if (!ddr_range_fits(off, 16U) || (off & 0xFU) != 0U)
    {
        fpga_fatal("invalid DDR read16 off=0x%08x", off);
    }
    for (uint32_t lane_word = 0; lane_word < 4U; ++lane_word)
    {
        out[lane_word] = (int32_t)ddr_mem_rd32(off + lane_word * 4U);
    }
    mmio_fence();
}

/**
 * Clear a VPU local memory window through direct MMIO writes.
 * The driver uses this to avoid stale ACT, WEIGHT, or RESULT data.
 */
static void vpu_clear_window(uint32_t off, size_t bytes)
{
    if (!vpu_is_mapped() || (off & 0x3U) != 0U || (bytes & 0x3U) != 0U)
    {
        fpga_fatal("invalid VPU clear off=0x%08x bytes=%zu", off, bytes);
    }
    for (size_t byte = 0; byte < bytes; byte += 4U)
    {
        vpu_mem_wr32(off + (uint32_t)byte, 0U);
    }
    mmio_fence();
}

/**
 * Clear a DDR staging window before a ZDMA transfer.
 * Clearing result staging helps detect stale or missing hardware output.
 */
static void ddr_clear_window(uint32_t off, size_t bytes)
{
    if (!ddr_range_fits(off, bytes) || (off & 0x3U) != 0U || (bytes & 0x3U) != 0U)
    {
        fpga_fatal("invalid DDR clear off=0x%08x bytes=%zu", off, bytes);
    }
    for (size_t byte = 0; byte < bytes; byte += 4U)
    {
        ddr_mem_wr32(off + (uint32_t)byte, 0U);
    }
    mmio_fence();
}

/**
 * Dump a VPU memory window as 32-bit words for self-test and layout debugging.
 */
static void log_vpu_u32_words(const char *label, uint32_t off, size_t bytes)
{
    char buf[384];
    size_t pos = 0;
    buf[0] = '\0';
    for (size_t byte = 0; byte < bytes && pos + 12 < sizeof(buf); byte += 4U)
    {
        const uint32_t value = vpu_mem_rd32(off + (uint32_t)byte);
        const int wrote = snprintf(buf + pos, sizeof(buf) - pos, "%s%08x", byte ? " " : "", value);
        if (wrote <= 0)
        {
            break;
        }
        pos += (size_t)wrote;
    }
    LOGSELF("%s off=0x%08x bytes=%zu u32=[%s]", label ? label : "dump", off, bytes, buf);
}

/**
 * Return a stable tensor name for logs and allowlist checks.
 * Unknown names are converted to a literal placeholder instead of using a null pointer.
 */
static const char *tensor_name_or_unknown(const struct ggml_tensor *tensor)
{
    return (tensor && tensor->name[0] != '\0') ? tensor->name : "?";
}

/**
 * Return true when a C string starts with a prefix.
 */
static bool str_starts_with(const char *s, const char *prefix)
{
    if (!s || !prefix)
    {
        return false;
    }
    return strncmp(s, prefix, strlen(prefix)) == 0;
}

/**
 * Return true when a C string ends with a suffix.
 */
static bool str_ends_with(const char *s, const char *suffix)
{
    if (!s || !suffix)
    {
        return false;
    }
    const size_t len = strlen(s);
    const size_t suffix_len = strlen(suffix);
    return len >= suffix_len && strcmp(s + len - suffix_len, suffix) == 0;
}

/**
 * Identify embedding, logits, or output projection tensors that stay on the CPU baseline.
 * These tensors are intentionally excluded from the current VPU offload path.
 */
static bool is_logits_or_output_projection_tensor(const char *name)
{
    return name &&
           (strcmp(name, "token_embd.weight") == 0 ||
            strcmp(name, "output.weight") == 0 ||
            strcmp(name, "lm_head.weight") == 0 ||
            strcmp(name, "tok_embeddings.weight") == 0);
}

/**
 * Classify a transformer block weight tensor by name.
 * Only known attention projection and FFN projection names are eligible for FPGA offload.
 */
static fpga_tensor_category_t fpga_tensor_category(const char *name)
{
    if (!name || !str_starts_with(name, "blk."))
    {
        return FPGA_TENSOR_UNKNOWN;
    }
    if (str_ends_with(name, ".attn_q.weight"))
    {
        return FPGA_TENSOR_ATTN_Q;
    }
    if (str_ends_with(name, ".attn_k.weight"))
    {
        return FPGA_TENSOR_ATTN_K;
    }
    if (str_ends_with(name, ".attn_v.weight"))
    {
        return FPGA_TENSOR_ATTN_V;
    }
    if (str_ends_with(name, ".attn_output.weight"))
    {
        return FPGA_TENSOR_ATTN_OUTPUT;
    }
    if (str_ends_with(name, ".ffn_gate.weight"))
    {
        return FPGA_TENSOR_FFN_GATE;
    }
    if (str_ends_with(name, ".ffn_up.weight"))
    {
        return FPGA_TENSOR_FFN_UP;
    }
    if (str_ends_with(name, ".ffn_down.weight"))
    {
        return FPGA_TENSOR_FFN_DOWN;
    }
    return FPGA_TENSOR_UNKNOWN;
}

/**
 * Return a readable name for an FPGA tensor category used in logs.
 */
static const char *fpga_tensor_category_name(fpga_tensor_category_t category)
{
    switch (category)
    {
    case FPGA_TENSOR_ATTN_Q:
        return "attn_q";
    case FPGA_TENSOR_ATTN_K:
        return "attn_k";
    case FPGA_TENSOR_ATTN_V:
        return "attn_v";
    case FPGA_TENSOR_ATTN_OUTPUT:
        return "attn_output";
    case FPGA_TENSOR_FFN_GATE:
        return "ffn_gate";
    case FPGA_TENSOR_FFN_UP:
        return "ffn_up";
    case FPGA_TENSOR_FFN_DOWN:
        return "ffn_down";
    default:
        return "unknown";
    }
}

/**
 * Return true for FFN gate/up/down categories.
 */
static bool fpga_tensor_category_is_ffn(fpga_tensor_category_t category)
{
    return category == FPGA_TENSOR_FFN_GATE ||
           category == FPGA_TENSOR_FFN_UP ||
           category == FPGA_TENSOR_FFN_DOWN;
}

/**
 * Return true for attention q/k/v/output projection categories.
 */
static bool fpga_tensor_category_is_attention_projection(fpga_tensor_category_t category)
{
    return category == FPGA_TENSOR_ATTN_Q ||
           category == FPGA_TENSOR_ATTN_K ||
           category == FPGA_TENSOR_ATTN_V ||
           category == FPGA_TENSOR_ATTN_OUTPUT;
}

/**
 * Apply compile-time debug gates before running a tensor on FPGA.
 * category identifies the tensor type, m distinguishes prefill from decode, and reason receives the CPU-baseline explanation.
 */
static bool fpga_debug_safe_mode_allows(
    fpga_tensor_category_t category,
    int64_t m,
    const char **reason)
{
    if (reason)
    {
        *reason = nullptr;
    }
    if (kForceAllMatmulCpu)
    {
        if (reason)
        {
            *reason = "debug_safe_mode_all_matmul_cpu";
        }
        return false;
    }
    if (kFpgaOnlyFFN && !fpga_tensor_category_is_ffn(category))
    {
        if (reason)
        {
            *reason = "debug_safe_mode_only_ffn";
        }
        return false;
    }
    if (kFpgaOnlyAttentionProjection && !fpga_tensor_category_is_attention_projection(category))
    {
        if (reason)
        {
            *reason = "debug_safe_mode_only_attention_projection";
        }
        return false;
    }
    if (kDisableFpgaForPrefill && m > 1)
    {
        if (reason)
        {
            *reason = "debug_safe_mode_prefill_cpu_baseline";
        }
        return false;
    }
    if (kDisableFpgaForDecode && m == 1)
    {
        if (reason)
        {
            *reason = "debug_safe_mode_decode_cpu_baseline";
        }
        return false;
    }
    return true;
}

/**
 * Decide whether a tensor name and output width may enter the FPGA matmul path.
 * reason and kind describe why a tensor is skipped so counters and logs remain explainable.
 */
static bool fpga_tensor_allowed(
    const char *tensor_name,
    int64_t n,
    const char **reason,
    fpga_skip_kind_t *kind)
{
    if (reason)
    {
        *reason = nullptr;
    }
    if (kind)
    {
        *kind = FPGA_SKIP_NONE;
    }

    if (is_logits_or_output_projection_tensor(tensor_name))
    {
        if (reason)
        {
            *reason = "logits/output_projection_cpu_baseline";
        }
        if (kind)
        {
            *kind = FPGA_SKIP_LOGITS_OUTPUT;
        }
        return false;
    }

    if (n > FPGA_MAX_SAFE_OFFLOAD_N)
    {
        if (reason)
        {
            *reason = "N_too_large_for_current_VPU";
        }
        if (kind)
        {
            *kind = FPGA_SKIP_LARGE_N;
        }
        return false;
    }

    if (fpga_tensor_category(tensor_name) != FPGA_TENSOR_UNKNOWN)
    {
        return true;
    }

    if (reason)
    {
        *reason = "not_transformer_block_allowlist";
    }
    if (kind)
    {
        *kind = FPGA_SKIP_NOT_ALLOWLISTED;
    }
    return false;
}

/**
 * Log the first occurrence of each skip class and update skip counters.
 * The function avoids flooding logs while preserving the reason for CPU execution.
 */
static void log_fpga_tensor_skip_once(
    const char *tensor_name,
    int64_t k,
    int64_t n,
    int64_t m,
    const char *reason,
    fpga_skip_kind_t kind)
{
    bool should_log = false;
    switch (kind)
    {
    case FPGA_SKIP_LOGITS_OUTPUT:
        g_fpga_skipped_token_embd_count++;
        should_log = !g_logged_skip_logits_output;
        g_logged_skip_logits_output = true;
        break;
    case FPGA_SKIP_LARGE_N:
        g_fpga_skipped_large_n_count++;
        should_log = !g_logged_skip_large_n;
        g_logged_skip_large_n = true;
        break;
    case FPGA_SKIP_NOT_ALLOWLISTED:
        g_fpga_skipped_not_allowlisted_count++;
        should_log = !g_logged_skip_not_allowlisted;
        g_logged_skip_not_allowlisted = true;
        break;
    case FPGA_SKIP_QUALITY_GUARD:
        should_log = !g_logged_skip_quality_guard;
        g_logged_skip_quality_guard = true;
        break;
    case FPGA_SKIP_NONE:
    default:
        break;
    }

    if (should_log)
    {
        LOGI("skip tensor=%s shape=K%lld_N%lld_M%lld reason=%s action=cpu_baseline",
             tensor_name ? tensor_name : "?",
             (long long)k,
             (long long)n,
             (long long)m,
             reason ? reason : "unknown");
    }
}

/**
 * Keep tensors with known bad Q8_0 scale patterns on the upstream CPU path.
 * The decision is name-based so every ggml worker thread makes the same choice
 * without a per-call scan or thread-local disagreement.
 */
[[maybe_unused]] static bool fpga_quality_guard_forces_cpu(
    const char *tensor_name,
    const char **reason)
{
    if (reason)
    {
        *reason = nullptr;
    }
    if (!tensor_name)
    {
        return false;
    }

    static const char *const known_bad_scale_tensors[] = {
        "blk.5.ffn_up.weight",
        "blk.6.ffn_gate.weight",
        "blk.6.ffn_up.weight",
        "blk.8.ffn_gate.weight",
    };

    for (const char *bad_name : known_bad_scale_tensors)
    {
        if (std::strcmp(tensor_name, bad_name) == 0)
        {
            if (reason)
            {
                *reason = "quality_guard_known_nonfinite_q8_weight_scale";
            }
            return true;
        }
    }

    static const char *const known_activation_overflow_tensors[] = {
        "blk.5.ffn_down.weight",
    };

    for (const char *sensitive_name : known_activation_overflow_tensors)
    {
        if (std::strcmp(tensor_name, sensitive_name) == 0)
        {
            if (reason)
            {
                *reason = "quality_guard_known_activation_scale_overflow";
            }
            return true;
        }
    }
    return false;
}

/**
 * Update aggregate fallback counters for prefill or decode calls.
 * m equals the ggml M dimension; m == 1 is decode and m > 1 is prefill.
 */
static void record_cpu_fallback(int64_t m)
{
    g_cpu_fallback_count++;
    if (m == 1)
    {
        g_decode_cpu_fallback++;
    }
    else
    {
        g_prefill_cpu_fallback++;
    }
}

/**
 * Extract the transformer layer index from a tensor name when possible.
 * fallback is used when the name does not encode a layer id.
 */
static int infer_layer_id_from_name(const char *name, int fallback)
{
    if (!name || name[0] == '\0')
    {
        return fallback;
    }

    int layer = -1;
    if (sscanf(name, "blk.%d.", &layer) == 1 ||
        sscanf(name, "layers.%d.", &layer) == 1 ||
        sscanf(name, "model.layers.%d.", &layer) == 1)
    {
        return layer;
    }
    return fallback;
}

/**
 * Compute the total multiply-accumulate count for a K x N x M matmul.
 */
static long long matrix_mac_count(int64_t k, int64_t n, int64_t m)
{
    if (k <= 0 || n <= 0 || m <= 0)
    {
        return 0;
    }
    if (k > LLONG_MAX / n || k * n > LLONG_MAX / m)
    {
        return LLONG_MAX;
    }
    return (long long)(k * n * m);
}

/**
 * Return the inference phase name based on M.
 * M == 1 is decode; larger M values are prefill or batched prompt processing.
 */
static const char *decode_or_prefill(int64_t m)
{
    return m == 1 ? "decode" : "prefill";
}

/**
 * Maintain the top slowest FPGA stages for cleanup-time reporting.
 * The timing fields are copied from a completed STAGE log entry.
 */
static void record_top_stage(
    const char *tensor_name,
    int layer_id,
    const char *phase,
    long long vpu_runs,
    double total_ms,
    double prep_ms,
    double transfer_in_ms,
    double ip_compute_ms,
    double transfer_out_ms,
    double host_accum_ms)
{
    int slot = -1;
    for (int i = 0; i < 10; ++i)
    {
        if (g_top_slowest[i].total_ms <= 0.0)
        {
            slot = i;
            break;
        }
    }
    if (slot < 0 && total_ms > g_top_slowest[9].total_ms)
    {
        slot = 9;
    }
    if (slot < 0)
    {
        return;
    }

    fpga_top_entry_t entry = {};
    snprintf(entry.tensor, sizeof(entry.tensor), "%s", tensor_name ? tensor_name : "?");
    snprintf(entry.phase, sizeof(entry.phase), "%s", phase ? phase : "?");
    entry.layer = layer_id;
    entry.vpu_runs = vpu_runs;
    entry.total_ms = total_ms;
    entry.prep_ms = prep_ms;
    entry.transfer_in_ms = transfer_in_ms;
    entry.ip_compute_ms = ip_compute_ms;
    entry.transfer_out_ms = transfer_out_ms;
    entry.host_accum_ms = host_accum_ms;

    g_top_slowest[slot] = entry;
    for (int i = slot; i > 0 && g_top_slowest[i].total_ms > g_top_slowest[i - 1].total_ms; --i)
    {
        std::swap(g_top_slowest[i], g_top_slowest[i - 1]);
    }
}

/**
 * Read a small sysfs text file into a string.
 * Used when discovering UIO names, addresses, and sizes.
 */
static bool read_text_file(const std::string &path, std::string *out)
{
    FILE *fp = fopen(path.c_str(), "r");
    if (!fp)
    {
        return false;
    }
    char buf[256];
    if (!fgets(buf, sizeof(buf), fp))
    {
        fclose(fp);
        return false;
    }
    fclose(fp);
    *out = buf;
    while (!out->empty() && (out->back() == '\n' || out->back() == '\r' || out->back() == ' ' || out->back() == '\t'))
    {
        out->pop_back();
    }
    return true;
}

typedef struct
{
    std::string uio;
    std::string dev_path;
    std::string name;
    uint64_t addr;
    size_t size;
} uio_region_t;

/**
 * Parse a sysfs integer string that may be decimal or hexadecimal.
 */
static bool parse_u64_text(const std::string &text, uint64_t *out)
{
    char *end = nullptr;
    errno = 0;
    const unsigned long long parsed = strtoull(text.c_str(), &end, 0);
    if (errno != 0 || end == text.c_str())
    {
        return false;
    }
    *out = (uint64_t)parsed;
    return true;
}

/**
 * Read the name, device path, physical address, and size of one UIO region.
 */
static bool read_uio_region(const std::string &uio, uio_region_t *info)
{
    std::string name;
    std::string addr_text;
    std::string size_text;
    if (!read_text_file("/sys/class/uio/" + uio + "/name", &name) ||
        !read_text_file("/sys/class/uio/" + uio + "/maps/map0/addr", &addr_text) ||
        !read_text_file("/sys/class/uio/" + uio + "/maps/map0/size", &size_text))
    {
        return false;
    }

    uint64_t addr = 0;
    uint64_t size = 0;
    if (!parse_u64_text(addr_text, &addr) || !parse_u64_text(size_text, &size) || size == 0)
    {
        return false;
    }

    info->uio = uio;
    info->dev_path = "/dev/" + uio;
    info->name = name;
    info->addr = addr;
    info->size = (size_t)size;
    return true;
}

/**
 * Find a UIO device by expected name and/or physical address.
 * This prevents mapping the wrong DMA, DDR, or VPU resource.
 */
static bool find_uio_by_name_and_addr(
    const char *name0,
    const char *name1,
    uint64_t required_addr,
    bool require_addr,
    uio_region_t *out)
{
    DIR *dir = opendir("/sys/class/uio");
    if (!dir)
    {
        return false;
    }

    bool found = false;
    struct dirent *ent = nullptr;
    while ((ent = readdir(dir)) != nullptr)
    {
        if (ent->d_name[0] == '.')
        {
            continue;
        }

        uio_region_t info;
        if (!read_uio_region(ent->d_name, &info))
        {
            continue;
        }

        const bool name_ok =
            (name0 && info.name == name0) ||
            (name1 && info.name == name1);
        const bool addr_ok = info.addr == required_addr;
        if ((name_ok && (!require_addr || addr_ok)) || (!name0 && !name1 && addr_ok))
        {
            *out = info;
            found = true;
            break;
        }
    }

    closedir(dir);
    return found;
}

/**
 * Map a UIO region after validating its physical address and minimum size.
 * The resulting pointer is used for MMIO or DDR staging depending on the tag.
 */
static bool map_uio_checked(
    const uio_region_t &info,
    size_t required_size,
    const char *tag,
    void **map_base,
    size_t *map_size,
    std::string *source)
{
    if (info.size < required_size)
    {
        LOGE("%s UIO %s name=%s addr=0x%llx too small: size=0x%zx required=0x%zx",
             tag, info.dev_path.c_str(), info.name.c_str(),
             (unsigned long long)info.addr, info.size, required_size);
        return false;
    }

    int fd = open(info.dev_path.c_str(), O_RDWR | O_SYNC);
    if (fd < 0)
    {
        LOGE("open %s for %s failed errno=%d (%s)", info.dev_path.c_str(), tag, errno, strerror(errno));
        return false;
    }

    void *ptr = mmap(nullptr, info.size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    const int saved_errno = errno;
    close(fd);
    if (ptr == MAP_FAILED)
    {
        LOGE("mmap %s for %s size=0x%zx failed errno=%d (%s)",
             info.dev_path.c_str(), tag, info.size, saved_errno, strerror(saved_errno));
        return false;
    }

    *map_base = ptr;
    *map_size = info.size;
    *source = info.dev_path + "(" + info.name + ",O_SYNC)";
    LOGI("mapped %s via UIO dev=%s name=%s addr=0x%llx virt=0x%llx size=0x%zx",
         tag, info.dev_path.c_str(), info.name.c_str(),
         (unsigned long long)info.addr, fpga_ptr_addr((volatile void *)ptr), info.size);
    return true;
}

/**
 * Legacy helper that finds a UIO device by name and returns its device path and map size.
 */
static bool find_uio_device(const char *wanted_name, std::string *dev_path, size_t *map_size)
{
    DIR *dir = opendir("/sys/class/uio");
    if (!dir)
    {
        return false;
    }

    bool found = false;
    struct dirent *ent = nullptr;
    while ((ent = readdir(dir)) != nullptr)
    {
        if (ent->d_name[0] == '.')
        {
            continue;
        }

        const std::string uio = ent->d_name;
        std::string name;
        if (!read_text_file("/sys/class/uio/" + uio + "/name", &name))
        {
            continue;
        }
        if (name != wanted_name)
        {
            continue;
        }

        std::string size_text;
        if (!read_text_file("/sys/class/uio/" + uio + "/maps/map0/size", &size_text))
        {
            continue;
        }
        char *end = nullptr;
        errno = 0;
        const unsigned long long parsed = strtoull(size_text.c_str(), &end, 0);
        if (errno != 0 || end == size_text.c_str() || parsed == 0ULL)
        {
            continue;
        }

        *dev_path = "/dev/" + uio;
        *map_size = (size_t)parsed;
        found = true;
        break;
    }

    closedir(dir);
    return found;
}

/**
 * Legacy helper that maps a named UIO device without physical-address matching.
 */
static bool map_uio_region(
    const char *uio_name,
    size_t required_size,
    const char *tag,
    void **map_base,
    size_t *map_size,
    std::string *source)
{
    std::string dev_path;
    size_t uio_size = 0;
    if (!find_uio_device(uio_name, &dev_path, &uio_size))
    {
        return false;
    }
    if (uio_size < required_size)
    {
        LOGE("UIO %s for %s is too small: size=0x%zx required=0x%zx; trying /dev/mem fallback",
             uio_name, tag, uio_size, required_size);
        return false;
    }

    int fd = open(dev_path.c_str(), O_RDWR | O_SYNC);
    if (fd < 0)
    {
        LOGE("open %s for %s failed errno=%d (%s); trying /dev/mem fallback",
             dev_path.c_str(), tag, errno, strerror(errno));
        return false;
    }
    void *ptr = mmap(nullptr, uio_size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    const int saved_errno = errno;
    close(fd);
    if (ptr == MAP_FAILED)
    {
        LOGE("mmap %s for %s size=0x%zx failed errno=%d (%s); trying /dev/mem fallback",
             dev_path.c_str(), tag, uio_size, saved_errno, strerror(saved_errno));
        return false;
    }

    *map_base = ptr;
    *map_size = uio_size;
    *source = dev_path + "(" + uio_name + ",O_SYNC)";
    LOGDMA("mapped %s via UIO name=%s dev=%s virt=%p size=0x%zx",
           tag, uio_name, dev_path.c_str(), ptr, uio_size);
    return true;
}

/**
 * Open /dev/mem once for direct physical memory mappings.
 */
static bool ensure_mem_fd(void)
{
    if (g_mem_fd >= 0)
    {
        return true;
    }
    g_mem_fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (g_mem_fd < 0)
    {
        LOGE("open /dev/mem failed errno=%d (%s). Run with sudo.", errno, strerror(errno));
        return false;
    }
    return true;
}

/**
 * Map a physical address range through /dev/mem as a fallback when UIO is unavailable.
 */
static bool map_devmem_region(
    uint64_t phys,
    size_t bytes,
    const char *tag,
    void **map_base,
    size_t *map_size,
    std::string *source)
{
    if (!ensure_mem_fd())
    {
        return false;
    }
    void *ptr = mmap(nullptr, bytes, PROT_READ | PROT_WRITE, MAP_SHARED, g_mem_fd, (off_t)phys);
    if (ptr == MAP_FAILED)
    {
        LOGE("mmap /dev/mem %s phys=0x%llx size=0x%zx failed errno=%d (%s)",
             tag, (unsigned long long)phys, bytes, errno, strerror(errno));
        return false;
    }
    *map_base = ptr;
    *map_size = bytes;
    *source = "/dev/mem(O_SYNC)";
    LOGDMA("mapped %s via /dev/mem phys=0x%llx virt=%p size=0x%zx",
           tag, (unsigned long long)phys, ptr, bytes);
    return true;
}

/**
 * Map a hardware region by preferring UIO and falling back to /dev/mem.
 * The function records the mapping source so logs identify how the driver reached the hardware.
 */
static bool map_region_prefer_uio(
    const char *uio_name,
    uint64_t phys,
    size_t devmem_size,
    size_t required_size,
    const char *tag,
    void **map_base,
    size_t *map_size,
    std::string *source)
{
    if (map_uio_region(uio_name, required_size, tag, map_base, map_size, source))
    {
        return true;
    }
    return map_devmem_region(phys, devmem_size, tag, map_base, map_size, source);
}

/**
 * Legacy combined mapper for DMA, VPU, and DDR regions.
 * The current initialization path maps VPU first and maps ZDMA/DDR only after direct self-tests pass.
 */
[[maybe_unused]] static bool map_registers_dma_ddr(void)
{
    if (!map_region_prefer_uio("dma-controller", DMA_BASE_PHYS, DMA_MMAP_SIZE,
                               sizeof(dma_ctrl), "ZDMA", &g_dma_map_base,
                               &g_dma_map_size, &g_dma_map_source))
    {
        return false;
    }
    g_dma = (volatile dma_ctrl *)g_dma_map_base;

    if (!map_region_prefer_uio("MY_IP", REG_BASE_PHYS, VPU_DEV_MEM_MMAP,
                               VPU_REG_MMAP_MIN, "MY_IP/VPU", &g_vpu_map_base,
                               &g_vpu_map_size, &g_vpu_map_source))
    {
        return false;
    }
    g_vpu = (volatile uint8_t *)g_vpu_map_base;

    if (!map_region_prefer_uio("ddr_high", DDR_BASE_PHYS, DDR_DEV_MEM_MMAP,
                               DDR_REQUIRED_BYTES, "ddr_high", &g_ddr_map_base,
                               &g_ddr_map_size, &g_ddr_map_source))
    {
        return false;
    }
    g_ddr = (uint8_t *)g_ddr_map_base;
    return true;
}

/**
 * Map only the VPU register and local-memory window.
 * This enables register reads, capability discovery, and direct self-tests before ZDMA is selected.
 */
static bool map_vpu_only(void)
{
    if (!map_region_prefer_uio("MY_IP", REG_BASE_PHYS, VPU_DEV_MEM_MMAP,
                               VPU_REG_MMAP_MIN, "MY_IP/VPU", &g_vpu_map_base,
                               &g_vpu_map_size, &g_vpu_map_source))
    {
        return false;
    }
    g_vpu = (volatile uint8_t *)g_vpu_map_base;
    return true;
}

/**
 * Map ZDMA and DDR staging after verifying their UIO runtime addresses.
 * This path is selected only when both DMA and DDR staging match the expected hardware design.
 */
static bool map_zdma_ddr_checked(void)
{
    if (dma_is_mapped() && ddr_is_mapped())
    {
        return true;
    }

    uio_region_t dma_info;
    if (!find_uio_by_name_and_addr("dma", "dma-controller", DMA_BASE_PHYS, true, &dma_info))
    {
        if (!find_uio_by_name_and_addr(nullptr, nullptr, DMA_BASE_PHYS, true, &dma_info))
        {
            LOGI("ZDMA UIO not found at phys=0x%llx with name dma/dma-controller or addr match; keeping direct_vpu_mmio",
                 (unsigned long long)DMA_BASE_PHYS);
            return false;
        }
        LOGI("ZDMA UIO selected by physical address match dev=%s name=%s addr=0x%llx",
             dma_info.dev_path.c_str(), dma_info.name.c_str(), (unsigned long long)dma_info.addr);
    }
    if (dma_info.addr != DMA_BASE_PHYS)
    {
        LOGE("ZDMA runtime addr mismatch dev=%s name=%s addr=0x%llx expected=0x%llx",
             dma_info.dev_path.c_str(), dma_info.name.c_str(),
             (unsigned long long)dma_info.addr, (unsigned long long)DMA_BASE_PHYS);
        return false;
    }
    if (!map_uio_checked(dma_info, sizeof(dma_ctrl), "ZDMA", &g_dma_map_base,
                         &g_dma_map_size, &g_dma_map_source))
    {
        return false;
    }
    g_dma = (volatile dma_ctrl *)g_dma_map_base;

    uio_region_t ddr_info;
    if (!find_uio_by_name_and_addr("ddr_high", nullptr, DDR_BASE_PHYS, true, &ddr_info))
    {
        LOGI("ddr_high UIO not found at phys=0x%llx; keeping direct_vpu_mmio",
             (unsigned long long)DDR_BASE_PHYS);
        return false;
    }
    if (ddr_info.addr != DDR_BASE_PHYS)
    {
        LOGE("ddr_high runtime addr mismatch dev=%s addr=0x%llx expected=0x%llx",
             ddr_info.dev_path.c_str(),
             (unsigned long long)ddr_info.addr, (unsigned long long)DDR_BASE_PHYS);
        return false;
    }
    if (ddr_info.size < DDR_REQUIRED_BYTES)
    {
        LOGE("ddr_high too small dev=%s size=0x%zx required=0x%zx",
             ddr_info.dev_path.c_str(), ddr_info.size, DDR_REQUIRED_BYTES);
        return false;
    }
    if (!map_uio_checked(ddr_info, DDR_REQUIRED_BYTES, "ddr_high", &g_ddr_map_base,
                         &g_ddr_map_size, &g_ddr_map_source))
    {
        return false;
    }
    g_ddr = (uint8_t *)g_ddr_map_base;

    LOGI("ZDMA runtime checks passed dma_dev=%s dma_addr=0x%llx ddr_dev=%s ddr_addr=0x%llx ddr_size=0x%zx",
         dma_info.dev_path.c_str(), (unsigned long long)dma_info.addr,
         ddr_info.dev_path.c_str(), (unsigned long long)ddr_info.addr, ddr_info.size);
    return true;
}

/**
 * Synchronize a DDR staging range before or after DMA when the mapping supports msync.
 * invalidate selects whether CPU caches should be invalidated after a device-to-DDR transfer.
 */
static bool msync_ddr_range(uint32_t off, size_t bytes, bool invalidate, const char *tag)
{
    if (!ddr_range_fits(off, bytes))
    {
        LOGE("DDR msync range overflow tag=%s off=0x%08x bytes=%zu mapped_size=0x%zx",
             tag, off, bytes, g_ddr_map_size);
        return false;
    }

    if (g_ddr_msync_unsupported)
    {
        mmio_fence();
        return true;
    }

    const long page = sysconf(_SC_PAGESIZE);
    const uintptr_t begin = (uintptr_t)(g_ddr + off);
    const uintptr_t aligned_begin = begin & ~((uintptr_t)page - 1U);
    const uintptr_t end = begin + bytes;
    const size_t len = align_up_size((size_t)(end - aligned_begin), (size_t)page);
    const int flags = MS_SYNC | (invalidate ? MS_INVALIDATE : 0);
    mmio_fence();
    if (msync((void *)aligned_begin, len, flags) != 0)
    {
        const int saved_errno = errno;
        const bool sync_mapping =
            g_ddr_map_source.find("O_SYNC") != std::string::npos ||
            g_ddr_map_source.find("/dev/uio") != std::string::npos;

        if (sync_mapping && (saved_errno == EINVAL || saved_errno == ENOSYS))
        {
            g_ddr_msync_unsupported = true;
            LOGI("msync unsupported for ddr_high source=%s errno=%d (%s); continuing with CPU barriers/O_SYNC mapping assumption",
                 g_ddr_map_source.c_str(), saved_errno, strerror(saved_errno));
            mmio_fence();
            return true;
        }

        LOGE("msync ddr_high tag=%s off=0x%08x bytes=%zu invalidate=%d errno=%d (%s)",
             tag, off, bytes, invalidate ? 1 : 0, saved_errno, strerror(saved_errno));
        return false;
    }
    mmio_fence();
    return true;
}

/**
 * Translate a DDR physical address into the local DDR staging offset.
 * Returns false when the address is outside the mapped high-DDR window.
 */
static bool phys_to_ddr_offset(uint64_t phys, size_t bytes, uint32_t *off)
{
    if (phys < DDR_BASE_PHYS)
    {
        return false;
    }
    const uint64_t delta = phys - DDR_BASE_PHYS;
    if (delta > UINT32_MAX || delta + bytes > g_ddr_map_size)
    {
        return false;
    }
    *off = (uint32_t)delta;
    return true;
}

/**
 * Write a 64-bit ZDMA source or destination address as low/high 32-bit descriptor words.
 */
static void zdma_set_addr(volatile U32 *lo, volatile U32 *hi, uint64_t value)
{
    *lo = (U32)(value & 0xFFFFFFFFULL);
    *hi = (U32)(value >> 32);
}

/**
 * Log the important ZDMA control and status registers after a DMA failure.
 */
static void zdma_dump(const char *tag)
{
    LOGE("ZDMA dump tag=%s status=0x%08x isr=0x%08x ctrl0=0x%08x ctrl1=0x%08x ctrl2=0x%08x data_attr=0x%08x",
         tag ? tag : "?",
         g_dma ? g_dma->ZDMA_CH_STATUS : 0xFFFFFFFFU,
         g_dma ? g_dma->ZDMA_CH_ISR : 0xFFFFFFFFU,
         g_dma ? g_dma->ZDMA_CH_CTRL0 : 0xFFFFFFFFU,
         g_dma ? g_dma->ZDMA_CH_CTRL1 : 0xFFFFFFFFU,
         g_dma ? g_dma->ZDMA_CH_CTRL2 : 0xFFFFFFFFU,
         g_dma ? g_dma->ZDMA_CH_DATA_ATTR : 0xFFFFFFFFU);
}

/**
 * Clear all ZDMA descriptor address and size registers before a new transfer setup.
 */
static void zdma_clear_descriptors(void)
{
    g_dma->ZDMA_CH_SRC_DSCR_WORD0 = 0;
    g_dma->ZDMA_CH_SRC_DSCR_WORD1 = 0;
    g_dma->ZDMA_CH_SRC_DSCR_WORD2 = 0;
    g_dma->ZDMA_CH_SRC_DSCR_WORD3 = 0;
    g_dma->ZDMA_CH_DST_DSCR_WORD0 = 0;
    g_dma->ZDMA_CH_DST_DSCR_WORD1 = 0;
    g_dma->ZDMA_CH_DST_DSCR_WORD2 = 0;
    g_dma->ZDMA_CH_DST_DSCR_WORD3 = 0;
    g_dma->ZDMA_CH_WR_ONLY_WORD0 = 0;
    g_dma->ZDMA_CH_WR_ONLY_WORD1 = 0;
    g_dma->ZDMA_CH_WR_ONLY_WORD2 = 0;
    g_dma->ZDMA_CH_WR_ONLY_WORD3 = 0;
    g_dma->ZDMA_CH_SRC_START_LSB = 0;
    g_dma->ZDMA_CH_SRC_START_MSB = 0;
    g_dma->ZDMA_CH_DST_START_LSB = 0;
    g_dma->ZDMA_CH_DST_START_MSB = 0;
}

/**
 * Initialize the ZDMA channel registers used for simple memory-to-memory copies.
 * The driver disables interrupts, sets attributes, clears descriptors, and leaves the channel ready for dma_copy_bytes.
 */
[[maybe_unused]] static bool fpga_dma_init(void)
{
    if (!dma_is_mapped())
    {
        LOGE("ZDMA register pointer is not mapped");
        return false;
    }

    g_dma->ZDMA_ERR_CTRL = 0x00000001;
    g_dma->ZDMA_CH_ISR = 0x00000000;
    g_dma->ZDMA_CH_IMR = 0x00000FFF;
    g_dma->ZDMA_CH_IEN = 0x00000000;
    g_dma->ZDMA_CH_IDS = 0x00000000;
    g_dma->ZDMA_CH_CTRL0 = 0x00000080;
    g_dma->ZDMA_CH_CTRL1 = 0x000003FF;
    g_dma->ZDMA_CH_FCI = 0x00000000;
    g_dma->ZDMA_CH_STATUS = 0x00000000;
    g_dma->ZDMA_CH_DATA_ATTR = ZDMA_DATA_ATTR_AXCACHE;
    g_dma->ZDMA_CH_DSCR_ATTR = 0x00000000;
    zdma_clear_descriptors();
    g_dma->ZDMA_CH_RATE_CTRL = 0x00000000;
    g_dma->ZDMA_CH_IRQ_SRC_ACCT = 0x00000000;
    g_dma->ZDMA_CH_IRQ_DST_ACCT = 0x00000000;
    g_dma->ZDMA_CH_CTRL2 = 0x00000000;
    mmio_fence();

    LOGDMA("ZDMA init base=0x%llx virt=0x%llx status=0x%08x isr=0x%08x ctrl0=0x%08x ctrl1=0x%08x data_attr=0x%08x",
           (unsigned long long)DMA_BASE_PHYS,
           fpga_ptr_addr(g_dma),
           g_dma->ZDMA_CH_STATUS,
           g_dma->ZDMA_CH_ISR,
           g_dma->ZDMA_CH_CTRL0,
           g_dma->ZDMA_CH_CTRL1,
           g_dma->ZDMA_CH_DATA_ATTR);
    return true;
}

/**
 * Copy a byte range between two physical addresses using ZDMA.
 * The source or destination may be DDR staging or an RTL-visible VPU local-memory window.
 */
static bool dma_copy_bytes(uint64_t src_phys, uint64_t dst_phys, size_t bytes, const char *tag)
{
    if (!dma_is_mapped())
    {
        LOGE("ZDMA is not mapped for tag=%s", tag ? tag : "?");
        return false;
    }
    if (bytes == 0 || bytes > UINT32_MAX)
    {
        LOGE("invalid ZDMA byte count tag=%s bytes=%zu", tag ? tag : "?", bytes);
        return false;
    }

    uint32_t src_ddr_off = 0;
    if (phys_to_ddr_offset(src_phys, bytes, &src_ddr_off))
    {
        if (!msync_ddr_range(src_ddr_off, bytes, false, tag))
        {
            return false;
        }
    }

    zdma_set_addr(&g_dma->ZDMA_CH_SRC_DSCR_WORD0, &g_dma->ZDMA_CH_SRC_DSCR_WORD1, src_phys);
    g_dma->ZDMA_CH_SRC_DSCR_WORD2 = (U32)bytes;
    g_dma->ZDMA_CH_SRC_DSCR_WORD3 = 0;
    zdma_set_addr(&g_dma->ZDMA_CH_DST_DSCR_WORD0, &g_dma->ZDMA_CH_DST_DSCR_WORD1, dst_phys);
    g_dma->ZDMA_CH_DST_DSCR_WORD2 = (U32)bytes;
    g_dma->ZDMA_CH_DST_DSCR_WORD3 = 0;
    mmio_fence();

    const long long t0 = now_us();
    g_dma->ZDMA_CH_CTRL2 = ZDMA_CTRL2_START;
    mmio_fence();

    uint32_t status = 0;
    uint32_t state = 0;
    long long polls = 0;
    while (true)
    {
        status = g_dma->ZDMA_CH_STATUS;
        state = status & ZDMA_STATUS_STATE_MASK;
        if ((state == 0U || state == 3U) && polls > 0)
        {
            break;
        }
        if (now_us() - t0 > g_dma_timeout_us)
        {
            LOGE("ZDMA timeout tag=%s src=0x%llx dst=0x%llx bytes=%zu status=0x%08x state=%u",
                 tag ? tag : "?",
                 (unsigned long long)src_phys,
                 (unsigned long long)dst_phys,
                 bytes,
                 status,
                 state);
            zdma_dump(tag);
            return false;
        }
        polls++;
        if ((polls & 0x3FF) == 0)
        {
            sched_yield();
        }
    }

    const long long t1 = now_us();
    uint32_t dst_ddr_off = 0;
    if (phys_to_ddr_offset(dst_phys, bytes, &dst_ddr_off))
    {
        if (!msync_ddr_range(dst_ddr_off, bytes, true, tag))
        {
            return false;
        }
    }

    LOGDMA("tag=%s src=0x%llx dst=0x%llx bytes=%zu units=bytes ms=%.3f MiB/s=%.1f status=0x%08x isr=0x%08x polls=%lld",
           tag ? tag : "?",
           (unsigned long long)src_phys,
           (unsigned long long)dst_phys,
           bytes,
           (double)(t1 - t0) / 1000.0,
           (t1 > t0) ? (double)bytes * 1000000.0 / ((double)(t1 - t0) * 1024.0 * 1024.0) : 0.0,
           status,
           g_dma->ZDMA_CH_ISR,
           polls);
    return true;
}

/**
 * Copy staged data from DDR into an RTL-visible IP window.
 * offset is normally ACT_BASE or WEIGHT_BASE; bytes is the number of hardware input bytes to deliver to AXI4_Mapping.v.
 */
static bool dma_write_ip_bytes(uint32_t offset, size_t bytes, const char *tag)
{
    return dma_copy_bytes(DDR_BASE_PHYS + (uint64_t)offset,
                          LMM_BASE_PHYS + (uint64_t)offset,
                          bytes,
                          tag);
}

/**
 * Copy RTL result data from the IP window back into DDR staging.
 * offset is normally RESULT_BASE; bytes is the number of hardware result bytes to make visible to the host.
 */
static bool dma_read_ip_bytes(uint32_t offset, size_t bytes, const char *tag)
{
    return dma_copy_bytes(LMM_BASE_PHYS + (uint64_t)offset,
                          DDR_BASE_PHYS + (uint64_t)offset,
                          bytes,
                          tag);
}

/**
 * Program VPU runtime registers before asserting start.
 * rows, col_beats, and mode are consumed by AXI4_Mapping.v and Matrix_Vector_Multiplication.v.
 */
static void configure_vpu(int rows, int col_beats, uint32_t mode)
{
    const int cols = col_beats * VPU_NUM_LANES;
    vpu_wr32(REG_ROWS, (uint32_t)rows);
    vpu_wr32(REG_COLS, (uint32_t)cols);
    vpu_wr32(REG_COL_BEATS, (uint32_t)col_beats);
    vpu_wr32(REG_SCALE, VPU_FP16_ONE);
    vpu_wr32(REG_MODE, mode);
    mmio_fence();
}

/**
 * Poll REG_STATUS until the VPU reports DONE, ERROR, or timeout.
 * final_status receives the last hardware status value for diagnostics.
 */
static bool wait_vpu_done(uint32_t *final_status)
{
    const long long t0 = now_us();
    long long polls = 0;
    while (true)
    {
        const uint32_t status = vpu_rd32(REG_STATUS);
        if (final_status)
        {
            *final_status = status;
        }
        if (kLogPollStatus && (g_ip_status_every > 0) && ((polls % g_ip_status_every) == 0))
        {
            LOGIP("poll=%lld status=0x%08x progress=0x%08x", polls, status, vpu_rd32(REG_PROGRESS));
        }
        if (status & STATUS_ERROR)
        {
            LOGE("VPU reported error status=0x%08x progress=0x%08x",
                 status, vpu_rd32(REG_PROGRESS));
            return false;
        }
        if (status & STATUS_DONE)
        {
            return true;
        }
        if (now_us() - t0 > g_ip_timeout_us)
        {
            LOGE("VPU timeout status=0x%08x progress=0x%08x",
                 status, vpu_rd32(REG_PROGRESS));
            return false;
        }
        polls++;
        if ((polls & 0x3FF) == 0)
        {
            sched_yield();
        }
    }
}

/**
 * Convert a GGML/IEEE-style FP16 scale value to FP32 for host accumulation.
 */
static inline float fp16_to_fp32(uint16_t h)
{
    return ggml_fp16_to_fp32((ggml_fp16_t)h);
}

/**
 * Convert an FP32 scale value to FP16 for Q8_0 activation block storage.
 */
static inline uint16_t fp32_to_fp16(float f)
{
    return (uint16_t)ggml_fp32_to_fp16(f);
}

static inline uint16_t fp32_to_fp16_nonnegative_saturated(float f)
{
    if (!std::isfinite(f) || f <= 0.0f)
    {
        return fp32_to_fp16(0.0f);
    }
    return fp32_to_fp16(std::min(f, kFp16MaxFinite));
}

static bool fpga_weight_scales_are_finite(
    const struct ggml_tensor *src0,
    int64_t k,
    int64_t n,
    const char *tensor_name,
    int layer_id,
    bool log_details,
    long long *bad_count_out);

/**
 * Cached wrapper for the Q8_0 weight-scale preflight.
 * Model weights are immutable after load, so each tensor needs the full scan
 * only once. Later decode calls reuse the decision without re-reading every
 * Q8_0 block scale.
 */
static bool fpga_weight_scales_are_finite_cached(
    const struct ggml_tensor *src0,
    int64_t k,
    int64_t n,
    const char *tensor_name,
    int layer_id,
    long long *bad_count_out)
{
    for (const fpga_weight_scale_preflight_entry_t &entry : g_weight_scale_preflight_cache)
    {
        if (entry.tensor == src0 &&
            entry.data == src0->data &&
            entry.k == k &&
            entry.n == n &&
            entry.nb0 == (size_t)src0->nb[0] &&
            entry.nb1 == (size_t)src0->nb[1])
        {
            if (bad_count_out)
            {
                *bad_count_out = entry.bad_count;
            }
            return entry.finite;
        }
    }

    long long bad_count = 0;
    const bool finite = fpga_weight_scales_are_finite(
        src0,
        k,
        n,
        tensor_name,
        layer_id,
        true,
        &bad_count);

    fpga_weight_scale_preflight_entry_t entry = {};
    entry.tensor = src0;
    entry.data = src0->data;
    entry.k = k;
    entry.n = n;
    entry.nb0 = (size_t)src0->nb[0];
    entry.nb1 = (size_t)src0->nb[1];
    entry.finite = finite;
    entry.bad_count = bad_count;
    g_weight_scale_preflight_cache.push_back(entry);

    if (bad_count_out)
    {
        *bad_count_out = bad_count;
    }
    return finite;
}

static void log_nonfinite_activation_scale(
    const struct ggml_tensor *src1,
    int64_t col,
    int64_t block,
    int64_t k,
    const block_q8_0_t *qb,
    const char *tensor_name,
    int layer_id,
    int64_t m);

static void log_activation_scale_fp16_overflow(
    const struct ggml_tensor *src1,
    int64_t col,
    int64_t block,
    int64_t k,
    const block_q8_0_t *qb,
    float fp32_scale,
    const char *tensor_name,
    int layer_id,
    int64_t m);

static float quantize_q8_0_block_fp32_scale(const float *x, ptrdiff_t stride_bytes, block_q8_0_t *y)
{
    float amax = 0.0f;
    for (int i = 0; i < VPU_QK8_0; ++i)
    {
        const float v = *(const float *)((const char *)x + (ptrdiff_t)i * stride_bytes);
        if (std::isfinite(v))
        {
            amax = std::max(amax, std::fabs(v));
        }
    }

    const float d_raw = amax / 127.0f;
    const float id = d_raw > 0.0f ? 1.0f / d_raw : 0.0f;
    y->d = fp32_to_fp16_nonnegative_saturated(d_raw);
    const float d_stored = fp16_to_fp32(y->d);

    for (int i = 0; i < VPU_QK8_0; ++i)
    {
        const float v = *(const float *)((const char *)x + (ptrdiff_t)i * stride_bytes);
        const int q = std::isfinite(v) ? (int)std::round(v * id) : 0;
        y->qs[i] = (int8_t)std::max(-128, std::min(127, q));
    }
    return d_stored;
}

static bool activation_block_has_nonfinite(const char *base, ptrdiff_t stride_bytes)
{
    for (int i = 0; i < VPU_QK8_0; ++i)
    {
        const float v = *(const float *)(base + (ptrdiff_t)i * stride_bytes);
        if (!std::isfinite(v))
        {
            return true;
        }
    }
    return false;
}

/**
 * Quantize one activation vector column from F32 into Q8_0 blocks.
 * src1 is the ggml activation tensor, m selects the vector, k is its length, and out receives k/32 blocks.
 */
static void quantize_activation_vector_to(
    const struct ggml_tensor *src1,
    int64_t m,
    int64_t k,
    block_q8_0_t *out,
    float *out_scales)
{
    const int64_t nb = k / VPU_QK8_0;
    const char *base = (const char *)src1->data + m * src1->nb[1];
    if (src1->nb[0] == (int64_t)sizeof(float))
    {
        quantize_row_q8_0((const float *)base, out, k);
        for (int64_t ib = 0; ib < nb; ++ib)
        {
            const char *block_base = base + ib * VPU_QK8_0 * (int64_t)sizeof(float);
            float scale = fp16_to_fp32(out[(size_t)ib].d);
            if (!std::isfinite(scale) ||
                activation_block_has_nonfinite(block_base, (ptrdiff_t)sizeof(float)))
            {
                scale = quantize_q8_0_block_fp32_scale(
                    (const float *)block_base,
                    (ptrdiff_t)sizeof(float),
                    &out[(size_t)ib]);
            }
            out_scales[(size_t)ib] = scale;
        }
        return;
    }
    for (int64_t ib = 0; ib < nb; ++ib)
    {
        const float *block_base = (const float *)(base + ib * VPU_QK8_0 * src1->nb[0]);
        out_scales[(size_t)ib] =
            quantize_q8_0_block_fp32_scale(block_base, src1->nb[0], &out[(size_t)ib]);
    }
}

/**
 * Ensure all activation vectors for the current matmul are available as Q8_0 blocks.
 * The function optionally reuses cached blocks and records activation scales used after RTL returns raw INT32 partials.
 */
static void ensure_quantized_activation_matrix(
    const struct ggml_tensor *src1,
    int64_t m,
    int64_t k,
    std::vector<block_q8_0_t> &act_blocks_all,
    std::vector<float> &act_scales,
    fpga_stage_totals_t *totals,
    const char *tensor_name,
    int layer_id)
{
    const bool cache_hit =
        FPGA_ENABLE_ACTIVATION_CACHE &&
        g_scratch.activation_cache_valid &&
        g_scratch.cached_src1 == src1 &&
        g_scratch.cached_src1_data == src1->data &&
        g_scratch.cached_m == m &&
        g_scratch.cached_k == k &&
        g_scratch.cached_nb0 == src1->nb[0] &&
        g_scratch.cached_nb1 == src1->nb[1];

    if (cache_hit)
    {
        g_activation_cache_hits++;
        return;
    }

    const int64_t nb = k / VPU_QK8_0;
    act_blocks_all.resize((size_t)(m * nb));
    act_scales.resize((size_t)(m * nb));
    for (int64_t col = 0; col < m; ++col)
    {
        block_q8_0_t *col_blocks = &act_blocks_all[(size_t)(col * nb)];
        float *col_scales = &act_scales[(size_t)(col * nb)];
        quantize_activation_vector_to(src1, col, k, col_blocks, col_scales);
        for (int64_t ib = 0; ib < nb; ++ib)
        {
            const float act_scale = col_scales[(size_t)ib];
            if (!std::isfinite(act_scale))
            {
                g_nonfinite_activation_scale_count++;
                g_activation_scale_overflow_count++;
                if (totals)
                {
                    totals->nonfinite_activation_scales++;
                    totals->activation_scale_overflows++;
                }
                if (g_nonfinite_activation_scale_log_count < kNonFiniteActivationScaleLogLimit)
                {
                    log_nonfinite_activation_scale(
                        src1,
                        col,
                        ib,
                        k,
                        &col_blocks[(size_t)ib],
                        tensor_name,
                        layer_id,
                        m);
                    g_nonfinite_activation_scale_log_count++;
                    if (g_nonfinite_activation_scale_log_count == kNonFiniteActivationScaleLogLimit)
                    {
                        LOGW("non-finite activation Q8_0 scale log limit reached; further bad activation scales will be counted in summary only");
                    }
                }
            }
            else if (act_scale > kFp16MaxFinite)
            {
                g_activation_scale_overflow_count++;
                if (totals)
                {
                    totals->activation_scale_overflows++;
                }
                if (g_activation_scale_overflow_log_count < kNonFiniteActivationScaleLogLimit)
                {
                    log_activation_scale_fp16_overflow(
                        src1,
                        col,
                        ib,
                        k,
                        &col_blocks[(size_t)ib],
                        act_scale,
                        tensor_name,
                        layer_id,
                        m);
                    g_activation_scale_overflow_log_count++;
                    if (g_activation_scale_overflow_log_count == kNonFiniteActivationScaleLogLimit)
                    {
                        LOGW("activation FP32 scale overflow log limit reached; further FP16-clamped activation scales will be counted in summary only");
                    }
                }
            }
        }
    }

    g_scratch.cached_src1 = src1;
    g_scratch.cached_src1_data = src1->data;
    g_scratch.cached_m = m;
    g_scratch.cached_k = k;
    g_scratch.cached_nb0 = src1->nb[0];
    g_scratch.cached_nb1 = src1->nb[1];
    g_scratch.activation_cache_valid = true;
    g_activation_cache_misses++;
}

/**
 * Return the Q8_0 weight block for a specific output row and K block.
 * The returned qs values are written to WEIGHT_BASE for RTL processing and d is used for host-side scaling.
 */
static const block_q8_0_t *weight_block(
    const struct ggml_tensor *src0,
    int64_t row,
    int64_t block)
{
    const char *row_base = (const char *)src0->data + row * src0->nb[1];
    return (const block_q8_0_t *)(row_base + block * src0->nb[0]);
}

/**
 * Store one F32 value into the ggml destination tensor using its stride layout.
 */
static void store_dst_value(
    const struct ggml_tensor *dst,
    int64_t row,
    int64_t col,
    float value)
{
    char *base = (char *)dst->data;
    *(float *)(base + row * dst->nb[0] + col * dst->nb[1]) = value;
}

/**
 * Load one F32 value from the ggml destination tensor for audits or debug comparison.
 */
static float load_dst_value(
    const struct ggml_tensor *dst,
    int64_t row,
    int64_t col)
{
    const char *base = (const char *)dst->data;
    return *(const float *)(base + row * dst->nb[0] + col * dst->nb[1]);
}

/**
 * Format a short list of FP32 values for diagnostic logs.
 */
static void format_float_samples(const float *values, int count, char *out, size_t out_size)
{
    if (out_size == 0)
    {
        return;
    }
    size_t pos = 0;
    int written = snprintf(out + pos, out_size - pos, "[");
    if (written < 0)
    {
        out[0] = '\0';
        return;
    }
    pos += (size_t)written;
    for (int i = 0; i < count && pos < out_size; ++i)
    {
        written = snprintf(out + pos, out_size - pos, "%s%.6g", i == 0 ? "" : ",", values[i]);
        if (written < 0)
        {
            break;
        }
        const size_t remaining = out_size - pos;
        if ((size_t)written >= remaining)
        {
            pos = out_size - 1;
            break;
        }
        pos += (size_t)written;
    }
    if (pos < out_size)
    {
        snprintf(out + pos, out_size - pos, "]");
    }
    else
    {
        out[out_size - 1] = '\0';
    }
}

/**
 * Format a short list of INT32 result values for diagnostic logs.
 */
static void format_i32_samples(const int32_t *values, int count, char *out, size_t out_size)
{
    if (out_size == 0)
    {
        return;
    }
    size_t pos = 0;
    int written = snprintf(out + pos, out_size - pos, "[");
    if (written < 0)
    {
        out[0] = '\0';
        return;
    }
    pos += (size_t)written;
    for (int i = 0; i < count && pos < out_size; ++i)
    {
        written = snprintf(out + pos, out_size - pos, "%s%d", i == 0 ? "" : ",", values[i]);
        if (written < 0)
        {
            break;
        }
        pos += (size_t)written;
    }
    if (pos < out_size)
    {
        snprintf(out + pos, out_size - pos, "]");
    }
    else
    {
        out[out_size - 1] = '\0';
    }
}

/**
 * Format a short list of INT8 lane values for diagnostic logs.
 */
static void format_i8_samples(const int8_t *values, int count, char *out, size_t out_size)
{
    if (out_size == 0)
    {
        return;
    }
    size_t pos = 0;
    int written = snprintf(out + pos, out_size - pos, "[");
    if (written < 0)
    {
        out[0] = '\0';
        return;
    }
    pos += (size_t)written;
    for (int i = 0; i < count && pos < out_size; ++i)
    {
        written = snprintf(out + pos, out_size - pos, "%s%d", i == 0 ? "" : ",", (int)values[i]);
        if (written < 0)
        {
            break;
        }
        const size_t remaining = out_size - pos;
        if ((size_t)written >= remaining)
        {
            pos = out_size - 1;
            break;
        }
        pos += (size_t)written;
    }
    if (pos < out_size)
    {
        snprintf(out + pos, out_size - pos, "]");
    }
    else
    {
        out[out_size - 1] = '\0';
    }
}

/**
 * Log detailed context for a non-finite Q8_0 weight scale.
 * The log includes tensor layout, row/block coordinates, neighboring scale bits, and sample INT8 payload.
 */
static void log_nonfinite_weight_scale(
    const struct ggml_tensor *src0,
    const block_q8_0_t *wb,
    const char *tensor_name,
    int layer_id,
    int64_t row,
    int local_row,
    int64_t block,
    int group_block,
    float weight_scale)
{
    const char *data = (const char *)src0->data;
    const char *ptr = (const char *)wb;
    const int64_t total_blocks = src0->ne[0] / VPU_QK8_0;
    const long long data_off = (long long)(ptr - data);
    const uint16_t prev_bits = block > 0 ? weight_block(src0, row, block - 1)->d : 0U;
    const uint16_t next_bits = (block + 1 < total_blocks) ? weight_block(src0, row, block + 1)->d : 0U;
    char qs_buf[160];
    format_i8_samples(wb->qs, std::min(8, VPU_QK8_0), qs_buf, sizeof(qs_buf));

    fpga_log_line(true, "NONFINITE_WEIGHT", true,
                  "tensor=%s layer=%d row=%lld local_row=%d block=%lld group_block=%d d_bits=0x%04x d=%.9g prev_d_bits=0x%04x next_d_bits=0x%04x data_off=%lld src0_ne=[%lld,%lld,%lld,%lld] src0_nb=[%lld,%lld,%lld,%lld] q8_blocks=%lld qs_first8=%s",
                  tensor_name ? tensor_name : "?",
                  layer_id,
                  (long long)row,
                  local_row,
                  (long long)block,
                  group_block,
                  (unsigned)wb->d,
                  weight_scale,
                  (unsigned)prev_bits,
                  (unsigned)next_bits,
                  data_off,
                  (long long)src0->ne[0], (long long)src0->ne[1],
                  (long long)src0->ne[2], (long long)src0->ne[3],
                  (long long)src0->nb[0], (long long)src0->nb[1],
                  (long long)src0->nb[2], (long long)src0->nb[3],
                  (long long)total_blocks,
                  qs_buf);
}

/**
 * Scan Q8_0 model weights before offload.
 * FPGA must not sanitize bad model scales and continue, because that produces a
 * different matmul from ggml CPU and can poison later layers.
 */
static bool fpga_weight_scales_are_finite(
    const struct ggml_tensor *src0,
    int64_t k,
    int64_t n,
    const char *tensor_name,
    int layer_id,
    bool log_details,
    long long *bad_count_out)
{
    const int64_t q8_blocks = k / VPU_QK8_0;
    long long bad_count = 0;
    for (int64_t row = 0; row < n; ++row)
    {
        for (int64_t block = 0; block < q8_blocks; ++block)
        {
            const block_q8_0_t *wb = weight_block(src0, row, block);
            const float weight_scale = fp16_to_fp32(wb->d);
            if (std::isfinite(weight_scale))
            {
                continue;
            }

            bad_count++;
            if (log_details && g_nonfinite_weight_scale_log_count < kNonFiniteWeightScaleLogLimit)
            {
                log_nonfinite_weight_scale(
                    src0,
                    wb,
                    tensor_name,
                    layer_id,
                    row,
                    (int)row,
                    block,
                    (int)block,
                    weight_scale);
                g_nonfinite_weight_scale_log_count++;
                if (g_nonfinite_weight_scale_log_count == kNonFiniteWeightScaleLogLimit)
                {
                    LOGW("non-finite Q8_0 weight scale log limit reached; further bad scales will be counted in summary only");
                }
            }
        }
    }

    if (log_details && bad_count > 0)
    {
        g_nonfinite_weight_scale_count += bad_count;
        fpga_log_line(true, "WEIGHT_PREFLIGHT_FAIL", true,
                      "tensor=%s layer=%d shape=K%lld_N%lld bad_weight_scales=%lld action=fpga_sanitize_weight_scale reason=nonfinite_q8_weight_scale",
                      tensor_name ? tensor_name : "?",
                      layer_id,
                      (long long)k,
                      (long long)n,
                      bad_count);
    }
    if (bad_count_out)
    {
        *bad_count_out = bad_count;
    }
    return bad_count == 0;
}

/**
 * Log detailed context for a non-finite activation scale produced during quantization.
 * The log includes source statistics and the Q8_0 block that would have been sent to RTL.
 */
static void log_nonfinite_activation_scale(
    const struct ggml_tensor *src1,
    int64_t col,
    int64_t block,
    int64_t k,
    const block_q8_0_t *qb,
    const char *tensor_name,
    int layer_id,
    int64_t m)
{
    const char *col_base = (const char *)src1->data + col * src1->nb[1];
    const char *block_base = col_base + block * VPU_QK8_0 * src1->nb[0];
    float min_v = INFINITY;
    float max_v = -INFINITY;
    float amax = 0.0f;
    long long nan_count = 0;
    long long inf_count = 0;
    long long finite_count = 0;
    int64_t first_bad = -1;
    float first8[8] = {};
    const int sample_count = std::min(8, VPU_QK8_0);

    for (int i = 0; i < VPU_QK8_0 && block * VPU_QK8_0 + i < k; ++i)
    {
        const float v = *(const float *)(block_base + (ptrdiff_t)i * src1->nb[0]);
        if (i < sample_count)
        {
            first8[i] = v;
        }
        if (std::isnan(v))
        {
            if (first_bad < 0)
            {
                first_bad = block * VPU_QK8_0 + i;
            }
            nan_count++;
            continue;
        }
        if (std::isinf(v))
        {
            if (first_bad < 0)
            {
                first_bad = block * VPU_QK8_0 + i;
            }
            inf_count++;
            continue;
        }
        finite_count++;
        min_v = std::min(min_v, v);
        max_v = std::max(max_v, v);
        amax = std::max(amax, std::fabs(v));
    }

    if (finite_count == 0)
    {
        min_v = NAN;
        max_v = NAN;
    }

    const float ideal_scale = amax / 127.0f;
    const float act_scale = fp16_to_fp32(qb->d);
    const bool fp16_overflow = std::isfinite(ideal_scale) && ideal_scale > kFp16MaxFinite;
    char first_buf[160];
    char qs_buf[160];
    format_float_samples(first8, sample_count, first_buf, sizeof(first_buf));
    format_i8_samples(qb->qs, sample_count, qs_buf, sizeof(qs_buf));
    fpga_log_line(true, "NONFINITE_ACT_SCALE", true,
                  "tensor=%s layer=%d phase=%s col=%lld block=%lld first_bad_src1=%lld d_bits=0x%04x act_scale=%.9g amax=%.9g ideal_scale=%.9g fp16_max=%.9g fp16_overflow=%d src1_min=%.9g src1_max=%.9g src1_nan=%lld src1_inf=%lld src1_ne=[%lld,%lld,%lld,%lld] src1_nb=[%lld,%lld,%lld,%lld] first8=%s qs_first8=%s",
                  tensor_name ? tensor_name : "?",
                  layer_id,
                  decode_or_prefill(m),
                  (long long)col,
                  (long long)block,
                  (long long)first_bad,
                  (unsigned)qb->d,
                  act_scale,
                  amax,
                  ideal_scale,
                  kFp16MaxFinite,
                  fp16_overflow ? 1 : 0,
                  min_v,
                  max_v,
                  nan_count,
                  inf_count,
                  (long long)src1->ne[0], (long long)src1->ne[1],
                  (long long)src1->ne[2], (long long)src1->ne[3],
                  (long long)src1->nb[0], (long long)src1->nb[1],
                  (long long)src1->nb[2], (long long)src1->nb[3],
                  first_buf,
                  qs_buf);
}

/**
 * Log activation blocks whose mathematically correct Q8_0 scale is finite FP32
 * but too large to be represented as finite FP16. RTL only consumes qs, while
 * host accumulation must use the FP16-stored Q8_0 scale to match ggml.
 */
static void log_activation_scale_fp16_overflow(
    const struct ggml_tensor *src1,
    int64_t col,
    int64_t block,
    int64_t k,
    const block_q8_0_t *qb,
    float fp32_scale,
    const char *tensor_name,
    int layer_id,
    int64_t m)
{
    const char *col_base = (const char *)src1->data + col * src1->nb[1];
    const char *block_base = col_base + block * VPU_QK8_0 * src1->nb[0];
    float min_v = INFINITY;
    float max_v = -INFINITY;
    float amax = 0.0f;
    long long finite_count = 0;
    float first8[8] = {};
    const int sample_count = std::min(8, VPU_QK8_0);

    for (int i = 0; i < VPU_QK8_0 && block * VPU_QK8_0 + i < k; ++i)
    {
        const float v = *(const float *)(block_base + (ptrdiff_t)i * src1->nb[0]);
        if (i < sample_count)
        {
            first8[i] = v;
        }
        if (!std::isfinite(v))
        {
            continue;
        }
        finite_count++;
        min_v = std::min(min_v, v);
        max_v = std::max(max_v, v);
        amax = std::max(amax, std::fabs(v));
    }

    if (finite_count == 0)
    {
        min_v = NAN;
        max_v = NAN;
    }

    char first_buf[160];
    char qs_buf[160];
    format_float_samples(first8, sample_count, first_buf, sizeof(first_buf));
    format_i8_samples(qb->qs, sample_count, qs_buf, sizeof(qs_buf));
    fpga_log_line(true, "ACT_SCALE_FP16_CLAMP", true,
                  "tensor=%s layer=%d phase=%s col=%lld block=%lld fp32_scale=%.9g stored_d_bits=0x%04x stored_d=%.9g fp16_max=%.9g amax=%.9g src1_min=%.9g src1_max=%.9g src1_ne=[%lld,%lld,%lld,%lld] src1_nb=[%lld,%lld,%lld,%lld] first8=%s qs_first8=%s host_accum_scale=fp16_stored",
                  tensor_name ? tensor_name : "?",
                  layer_id,
                  decode_or_prefill(m),
                  (long long)col,
                  (long long)block,
                  fp32_scale,
                  (unsigned)qb->d,
                  fp16_to_fp32(qb->d),
                  kFp16MaxFinite,
                  amax,
                  min_v,
                  max_v,
                  (long long)src1->ne[0], (long long)src1->ne[1],
                  (long long)src1->ne[2], (long long)src1->ne[3],
                  (long long)src1->nb[0], (long long)src1->nb[1],
                  (long long)src1->nb[2], (long long)src1->nb[3],
                  first_buf,
                  qs_buf);
}

/**
 * Log min, max, NaN, and Inf statistics for one activation vector column.
 */
static void log_src1_stats_for_col(
    const struct ggml_tensor *src1,
    int64_t col,
    int64_t k)
{
    const char *base = (const char *)src1->data + col * src1->nb[1];
    float min_v = INFINITY;
    float max_v = -INFINITY;
    long long nan_count = 0;
    long long inf_count = 0;
    long long finite_count = 0;
    int64_t first_bad = -1;
    float first8[8] = {};
    const int sample_count = (int)std::min<int64_t>(8, k);

    for (int64_t i = 0; i < k; ++i)
    {
        const float v = *(const float *)(base + i * src1->nb[0]);
        if (i < sample_count)
        {
            first8[i] = v;
        }
        if (std::isnan(v))
        {
            if (first_bad < 0)
            {
                first_bad = i;
            }
            nan_count++;
            continue;
        }
        if (std::isinf(v))
        {
            if (first_bad < 0)
            {
                first_bad = i;
            }
            inf_count++;
            continue;
        }
        finite_count++;
        min_v = std::min(min_v, v);
        max_v = std::max(max_v, v);
    }

    if (finite_count == 0)
    {
        min_v = NAN;
        max_v = NAN;
    }

    char first_buf[160];
    format_float_samples(first8, sample_count, first_buf, sizeof(first_buf));
    fpga_log_line(true, "NONFINITE_SRC1", true,
                  "first_bad_src1=%lld src1_min=%.6g src1_max=%.6g src1_nan=%lld src1_inf=%lld first8=%s",
                  (long long)first_bad,
                  min_v,
                  max_v,
                  nan_count,
                  inf_count,
                  first_buf);
}

/**
 * Update a deterministic checksum with one float value for result auditing.
 */
static uint64_t checksum_update_float(uint64_t checksum, float value)
{
    uint32_t bits = 0;
    memcpy(&bits, &value, sizeof(bits));
    checksum ^= (uint64_t)bits;
    checksum *= 1099511628211ULL;
    return checksum;
}

/**
 * Select whether a result tensor should be audited based on call count, layer, and phase.
 */
static bool should_audit_result(int layer_id, int64_t m)
{
    if (!g_result_audit_enabled || g_result_audit_count >= kFpgaResultAuditMaxCalls)
    {
        return false;
    }
    if (g_result_audit_first_count < 16)
    {
        g_result_audit_first_count++;
        return true;
    }
    if (layer_id == 0 && g_result_audit_layer0_count < 16)
    {
        g_result_audit_layer0_count++;
        return true;
    }
    if (layer_id >= 25 && g_result_audit_last_layer_count < 16)
    {
        g_result_audit_last_layer_count++;
        return true;
    }
    if (m == 1 && g_result_audit_decode_count < 32)
    {
        g_result_audit_decode_count++;
        return true;
    }
    return false;
}

/**
 * Audit the destination tensor after FPGA execution.
 * The function checks finite values, extrema, checksum, and sample outputs before the model consumes dst.
 */
static bool log_result_audit(
    long long call_id,
    const struct ggml_tensor *dst,
    int64_t k,
    int64_t n,
    int64_t m,
    const char *tensor_name,
    int layer_id)
{
    if (!should_audit_result(layer_id, m))
    {
        return true;
    }
    g_result_audit_count++;

    const int64_t total = n * m;
    if (total <= 0)
    {
        LOGE("RESULT audit skipped empty tensor=%s layer=%d shape=K%lld_N%lld_M%lld",
             tensor_name ? tensor_name : "?",
             layer_id,
             (long long)k,
             (long long)n,
             (long long)m);
        return false;
    }

    double sum = 0.0;
    double sum_sq = 0.0;
    float min_v = INFINITY;
    float max_v = -INFINITY;
    long long nan_count = 0;
    long long inf_count = 0;
    long long finite_count = 0;
    float first8[8] = {};
    float last8[8] = {};
    const int first_count = (int)std::min<int64_t>(8, total);
    const int last_count = first_count;
    uint64_t checksum = 1469598103934665603ULL;

    for (int64_t idx = 0; idx < total; ++idx)
    {
        const int64_t row = idx / m;
        const int64_t col = idx - row * m;
        const float v = load_dst_value(dst, row, col);
        checksum = checksum_update_float(checksum, v);
        if (idx < first_count)
        {
            first8[idx] = v;
        }
        if (idx >= total - last_count)
        {
            last8[idx - (total - last_count)] = v;
        }
        if (std::isnan(v))
        {
            nan_count++;
            continue;
        }
        if (std::isinf(v))
        {
            inf_count++;
            continue;
        }
        finite_count++;
        min_v = std::min(min_v, v);
        max_v = std::max(max_v, v);
        sum += (double)v;
        sum_sq += (double)v * (double)v;
    }

    if (finite_count == 0)
    {
        min_v = NAN;
        max_v = NAN;
    }
    const double mean = finite_count > 0 ? sum / (double)finite_count : NAN;
    const double l2 = std::sqrt(sum_sq);
    char first_buf[160];
    char last_buf[160];
    format_float_samples(first8, first_count, first_buf, sizeof(first_buf));
    format_float_samples(last8, last_count, last_buf, sizeof(last_buf));

    LOGRESULT("call=%lld tensor=%s layer=%d phase=%s shape=K%lld_N%lld_M%lld path=%s dst_min=%.6g dst_max=%.6g dst_mean=%.6g dst_l2=%.6g nan=%lld inf=%lld first8=%s last8=%s checksum=0x%016llx",
              call_id,
              tensor_name ? tensor_name : "?",
              layer_id,
              decode_or_prefill(m),
              (long long)k,
              (long long)n,
              (long long)m,
              g_use_zdma_path ? "zdma_ddr_to_ip" : "direct_vpu_mmio",
              min_v,
              max_v,
              mean,
              l2,
              nan_count,
              inf_count,
              first_buf,
              last_buf,
              (unsigned long long)checksum);

    if (nan_count > 0 || inf_count > 0)
    {
        g_nonfinite_result_count++;
        LOGE("RESULT audit found non-finite values tensor=%s layer=%d nan=%lld inf=%lld",
             tensor_name ? tensor_name : "?",
             layer_id,
             nan_count,
             inf_count);
        return false;
    }
    const bool all_zero_result = finite_count == total && sum_sq == 0.0;
    if (all_zero_result)
    {
        LOGE("RESULT audit found all-zero output tensor=%s layer=%d phase=%s shape=K%lld_N%lld_M%lld dst_l2=0 status=RESULT_AUDIT_ALL_ZERO",
             tensor_name ? tensor_name : "?",
             layer_id,
             decode_or_prefill(m),
             (long long)k,
             (long long)n,
             (long long)m);
        return false;
    }
    else if (max_v > 1.0e4f || min_v < -1.0e4f)
    {
        LOGW("RESULT audit large magnitude tensor=%s layer=%d dst_min=%.6g dst_max=%.6g",
             tensor_name ? tensor_name : "?",
             layer_id,
             min_v,
             max_v);
    }
    return true;
}

/**
 * Select whether tensor memory layout should be logged for the current call.
 */
static bool should_audit_layout(int layer_id, int64_t m)
{
    if (!g_layout_audit_enabled || g_layout_audit_count >= kFpgaLayoutAuditMaxCalls)
    {
        return false;
    }
    return g_layout_audit_count < 8 || layer_id == 0 || layer_id >= 25 || m == 1;
}

/**
 * Log ggml tensor dimensions and strides before running the FPGA path.
 * This helps verify that src0, src1, and dst match the layout assumed by the driver.
 */
static void log_layout_audit(
    const struct ggml_tensor *src0,
    const struct ggml_tensor *src1,
    const struct ggml_tensor *dst,
    const char *tensor_name,
    int layer_id)
{
    const int64_t m = src1 ? src1->ne[1] : 0;
    if (!should_audit_layout(layer_id, m))
    {
        return;
    }
    g_layout_audit_count++;
    LOGLAYOUT("tensor=%s layer=%d src0_ne=[%lld,%lld,%lld,%lld] src0_nb=[%zu,%zu,%zu,%zu] src1_ne=[%lld,%lld,%lld,%lld] src1_nb=[%zu,%zu,%zu,%zu] dst_ne=[%lld,%lld,%lld,%lld] dst_nb=[%zu,%zu,%zu,%zu]",
              tensor_name ? tensor_name : "?",
              layer_id,
              (long long)src0->ne[0], (long long)src0->ne[1], (long long)src0->ne[2], (long long)src0->ne[3],
              (size_t)src0->nb[0], (size_t)src0->nb[1], (size_t)src0->nb[2], (size_t)src0->nb[3],
              (long long)src1->ne[0], (long long)src1->ne[1], (long long)src1->ne[2], (long long)src1->ne[3],
              (size_t)src1->nb[0], (size_t)src1->nb[1], (size_t)src1->nb[2], (size_t)src1->nb[3],
              (long long)dst->ne[0], (long long)dst->ne[1], (long long)dst->ne[2], (long long)dst->ne[3],
              (size_t)dst->nb[0], (size_t)dst->nb[1], (size_t)dst->nb[2], (size_t)dst->nb[3]);
}

/**
 * Compute a CPU reference using the same quantized activation qs values and
 * FP16-stored activation scales as ggml's Q8_0 dot product.
 * This is used only when debug comparison is enabled.
 */
static void compute_host_reference_from_quantized_activation(
    const struct ggml_tensor *src0,
    int64_t k,
    int64_t n,
    int64_t m,
    std::vector<float> &ref)
{
    const int64_t nb = k / VPU_QK8_0;
    ref.assign((size_t)(n * m), 0.0f);

    for (int64_t col = 0; col < m; ++col)
    {
        for (int64_t row = 0; row < n; ++row)
        {
            float acc = 0.0f;
            for (int64_t ib = 0; ib < nb; ++ib)
            {
                const block_q8_0_t *wb = weight_block(src0, row, ib);
                const block_q8_0_t *ab = &g_scratch.act_blocks_all[(size_t)(col * nb + ib)];
                int32_t raw = 0;
                for (int lane = 0; lane < VPU_QK8_0; ++lane)
                {
                    raw += (int32_t)wb->qs[lane] * (int32_t)ab->qs[lane];
                }
                const float act_scale = g_scratch.act_scales[(size_t)(col * nb + ib)];
                float weight_scale = fp16_to_fp32(wb->d);
                if (!std::isfinite(weight_scale))
                {
                    weight_scale = 0.0f;
                }
                if (std::isfinite(act_scale))
                {
                    acc += (float)raw * act_scale * weight_scale;
                }
            }
            ref[(size_t)(row * m + col)] = acc;
        }
    }
}

/**
 * Compare FPGA output with a host reference for guarded tensors.
 * On mismatch the function overwrites dst with the reference result so the
 * model does not consume an incorrect FPGA tensor.
 */
static fpga_compare_status_t debug_compare_fpga_dst(
    const struct ggml_tensor *src0,
    const struct ggml_tensor *dst,
    int64_t k,
    int64_t n,
    int64_t m,
    const char *tensor_name,
    int layer_id)
{
    if (!g_debug_compare_enabled)
    {
        return FPGA_COMPARE_SKIPPED;
    }

    if (g_debug_compare_count >= g_debug_compare_limit)
    {
        return FPGA_COMPARE_SKIPPED;
    }

    const fpga_tensor_category_t category = fpga_tensor_category(tensor_name);
    const bool valid_category =
        category >= 0 && category < FPGA_TENSOR_CATEGORY_COUNT;
    const bool need_category_check =
        valid_category && !g_debug_compare_seen_category[(int)category];
    const bool need_last_layer_check =
        category == FPGA_TENSOR_FFN_DOWN &&
        layer_id >= 25 &&
        !g_debug_compare_seen_last_layer_ffn_down;

    g_debug_compare_count++;
    if (need_category_check)
    {
        g_debug_compare_seen_category[(int)category] = true;
    }
    if (need_last_layer_check)
    {
        g_debug_compare_seen_last_layer_ffn_down = true;
    }

    std::vector<float> ref;
    compute_host_reference_from_quantized_activation(src0, k, n, m, ref);

    float max_abs = 0.0f;
    int64_t first_bad = -1;
    float first_ref[8] = {};
    float first_fpga[8] = {};
    bool ref_all_finite = true;
    const int sample_count = (int)std::min<int64_t>(8, n * m);

    for (int64_t row = 0; row < n; ++row)
    {
        for (int64_t col = 0; col < m; ++col)
        {
            const int64_t idx = row * m + col;
            const float expected = ref[(size_t)idx];
            const float got = load_dst_value(dst, row, col);
            if (!std::isfinite(expected))
            {
                ref_all_finite = false;
            }
            if (idx < sample_count)
            {
                first_ref[idx] = expected;
                first_fpga[idx] = got;
            }
            const float diff = std::fabs(expected - got);
            max_abs = std::max(max_abs, diff);
            const float tol = 1.0e-3f + 1.0e-3f * std::max(std::fabs(expected), std::fabs(got));
            if (first_bad < 0 && (!std::isfinite(expected) || !std::isfinite(got) || diff > tol))
            {
                first_bad = idx;
            }
        }
    }

    if (first_bad < 0)
    {
        LOGI("debug compare pass tensor=%s category=%s layer=%d check=%d/%d reference=fp32_act_scale_q8_rawdot max_abs=%.6g",
             tensor_name ? tensor_name : "?",
             fpga_tensor_category_name(category),
             layer_id,
             g_debug_compare_count,
             g_debug_compare_limit,
             max_abs);
        return FPGA_COMPARE_PASS;
    }

    char ref_buf[160];
    char fpga_buf[160];
    format_float_samples(first_ref, sample_count, ref_buf, sizeof(ref_buf));
    format_float_samples(first_fpga, sample_count, fpga_buf, sizeof(fpga_buf));

    if (ref_all_finite)
    {
        for (int64_t row = 0; row < n; ++row)
        {
            for (int64_t col = 0; col < m; ++col)
            {
                store_dst_value(dst, row, col, ref[(size_t)(row * m + col)]);
            }
        }

        LOGMISMATCH("tensor=%s category=%s layer=%d shape=K%lld_N%lld_M%lld check=%d/%d max_abs=%.6g first_bad=%lld cpu_ref_first8=%s fpga_first8=%s action=substitute_cpu_reference",
                    tensor_name ? tensor_name : "?",
                    fpga_tensor_category_name(category),
                    layer_id,
                    (long long)k,
                    (long long)n,
                    (long long)m,
                    g_debug_compare_count,
                    g_debug_compare_limit,
                    max_abs,
                    (long long)first_bad,
                    ref_buf,
                    fpga_buf);
        LOGE("debug compare mismatch tensor=%s category=%s layer=%d; dst overwritten with guarded CPU reference",
             tensor_name ? tensor_name : "?",
             fpga_tensor_category_name(category),
             layer_id);
        return FPGA_COMPARE_SUBSTITUTED;
    }

    LOGMISMATCH("tensor=%s category=%s layer=%d shape=K%lld_N%lld_M%lld check=%d/%d max_abs=%.6g first_bad=%lld cpu_ref_first8=%s fpga_first8=%s action=keep_fpga_dst_reference_nonfinite",
                tensor_name ? tensor_name : "?",
                fpga_tensor_category_name(category),
                layer_id,
                (long long)k,
                (long long)n,
                (long long)m,
                g_debug_compare_count,
                g_debug_compare_limit,
                max_abs,
                (long long)first_bad,
                ref_buf,
                fpga_buf);
    LOGE("debug compare mismatch tensor=%s category=%s layer=%d; CPU reference contains non-finite values, so dst was not overwritten",
         tensor_name ? tensor_name : "?",
         fpga_tensor_category_name(category),
         layer_id);
    return FPGA_COMPARE_MISMATCH_KEPT;
}

/**
 * Write one INT8x16 beat directly to VPU local memory.
 * This helper is kept for direct-MMIO audit and self-test paths.
 */
/**
 * Write one 16-lane INT8 beat directly to the RTL-visible VPU memory window.
 * off is the byte address inside ACT_BASE or WEIGHT_BASE, and lanes points to the 16 signed INT8 values consumed by the hardware datapath.
 */
[[maybe_unused]] static void write_i8x16_to_vpu(uint32_t off, const int8_t *lanes)
{
    vpu_write_i8x16(off, lanes);
}

/**
 * Write one INT8x16 beat to the active staging target.
 * When ZDMA is active the beat goes to DDR staging; otherwise it goes directly to the RTL-visible VPU window.
 */
static void write_i8x16_to_stage(uint32_t off, const int8_t *lanes)
{
    if (g_use_zdma_path)
    {
        ddr_write_i8x16(off, lanes);
    }
    else
    {
        vpu_write_i8x16(off, lanes);
    }
}

/**
 * Read one packed INT32x4 result beat directly from VPU local memory.
 */
[[maybe_unused]] static void read_result_i32x4_from_vpu(uint32_t result_word, int32_t out[4])
{
    vpu_read_i32x4(result_word_offset(result_word), out);
}

/**
 * Read one packed INT32x4 result beat from the active result source.
 * When ZDMA is active the beat is read from DDR staging after dma_read_ip_bytes copied RESULT_BASE back.
 */
static void read_result_i32x4_from_stage(uint32_t result_word, int32_t out[4])
{
    if (g_use_zdma_path)
    {
        ddr_read_i32x4(result_word_offset(result_word), out);
    }
    else
    {
        vpu_read_i32x4(result_word_offset(result_word), out);
    }
}

/**
 * Clear the active staging target for ACT, WEIGHT, or RESULT data.
 * This prevents stale data from being interpreted as valid RTL input or output.
 */
static void clear_stage_window(uint32_t off, size_t bytes)
{
    if (g_use_zdma_path)
    {
        ddr_clear_window(off, bytes);
    }
    else
    {
        vpu_clear_window(off, bytes);
    }
}

/**
 * Execute one RTL VPU tile after ACT and WEIGHT data have been staged.
 * The function configures registers, copies ACT/WEIGHT into RTL-visible windows, starts the VPU, waits for DONE, and copies RESULT back.
 * rows is the number of output rows in the current tile. col_beats is the number of 16-lane INT8 beats that define the K dimension for this execution. mode selects the RTL execution format, such as packed Q8_0. act_bytes, weight_bytes, and result_bytes are the exact hardware-visible byte counts for ACT_BASE, WEIGHT_BASE, and RESULT_BASE. tensor_name, layer_id, k, n, m, and tile_id are diagnostic context fields used when a transfer or RTL execution fails. totals accumulates transfer, compute, and byte counters for the stage log.
 */
static bool run_vpu_window_transfer(
    int rows,
    int col_beats,
    uint32_t mode,
    size_t act_bytes,
    size_t weight_bytes,
    size_t result_bytes,
    const char *tensor_name,
    int layer_id,
    int64_t k,
    int64_t n,
    int64_t m,
    uint16_t tile_id,
    fpga_stage_totals_t *totals)
{
    vpu_wr32(REG_CTRL, CTRL_CLEAR_DONE);
    configure_vpu(rows, col_beats, mode);
    if (!vpu_range_fits(ACT_BASE, act_bytes, ACT_BASE, ACT_END) ||
        !vpu_range_fits(WEIGHT_BASE, weight_bytes, WEIGHT_BASE, WEIGHT_END) ||
        !vpu_range_fits(RESULT_BASE, result_bytes, RESULT_BASE, RESULT_END))
    {
        LOGE("direct VPU window overflow act=%zu weight_span=%zu result=%zu",
             act_bytes, weight_bytes, result_bytes);
        LOGHWFAIL("stage=RANGE tensor=%s layer=%d phase=%s path=%s shape=K%lld_N%lld_M%lld tile=%u rows=%d col_beats=%d act_bytes=%zu weight_bytes=%zu result_bytes=%zu act_window=[0x%08x,0x%08x) weight_window=[0x%08x,0x%08x) result_window=[0x%08x,0x%08x)",
                  tensor_name ? tensor_name : "?",
                  layer_id,
                  decode_or_prefill(m),
                  g_use_zdma_path ? "zdma_ddr_to_ip" : "direct_vpu_mmio",
                  (long long)k, (long long)n, (long long)m,
                  tile_id,
                  rows,
                  col_beats,
                  act_bytes,
                  weight_bytes,
                  result_bytes,
                  ACT_BASE, ACT_END, WEIGHT_BASE, WEIGHT_END, RESULT_BASE, RESULT_END);
        return false;
    }
    if (g_use_zdma_path &&
        (!ddr_range_fits(ACT_BASE, act_bytes) ||
         !ddr_range_fits(WEIGHT_BASE, weight_bytes) ||
         !ddr_range_fits(RESULT_BASE, result_bytes)))
    {
        LOGE("ZDMA DDR staging range overflow act=%zu weight_span=%zu result=%zu ddr_size=0x%zx",
             act_bytes, weight_bytes, result_bytes, g_ddr_map_size);
        LOGHWFAIL("stage=DDR_RANGE tensor=%s layer=%d phase=%s path=zdma_ddr_to_ip shape=K%lld_N%lld_M%lld tile=%u rows=%d col_beats=%d act_bytes=%zu weight_bytes=%zu result_bytes=%zu ddr_size=0x%zx required=0x%zx",
                  tensor_name ? tensor_name : "?",
                  layer_id,
                  decode_or_prefill(m),
                  (long long)k, (long long)n, (long long)m,
                  tile_id,
                  rows,
                  col_beats,
                  act_bytes,
                  weight_bytes,
                  result_bytes,
                  g_ddr_map_size,
                  (size_t)DDR_REQUIRED_BYTES);
        return false;
    }

    vpu_clear_window(RESULT_BASE, align_up_size(result_bytes, 16U));
    if (g_use_zdma_path)
    {
        ddr_clear_window(RESULT_BASE, align_up_size(result_bytes, 16U));
    }

    if (g_use_zdma_path)
    {
        const long long act0 = now_us();
        // RTL input transfer: the activation bytes in DDR staging are copied
        // into ACT_BASE, where AXI4_Mapping.v exposes them to the VPU datapath.
        if (!dma_write_ip_bytes(ACT_BASE, act_bytes, "ACT"))
        {
            LOGHWFAIL("stage=DMA_ACT tensor=%s layer=%d phase=%s shape=K%lld_N%lld_M%lld tile=%u rows=%d col_beats=%d bytes=%zu src_phys=0x%llx dst_phys=0x%llx dma_status=0x%08x dma_isr=0x%08x vpu_status=0x%08x progress=0x%08x",
                      tensor_name ? tensor_name : "?",
                      layer_id,
                      decode_or_prefill(m),
                      (long long)k, (long long)n, (long long)m,
                      tile_id,
                      rows,
                      col_beats,
                      act_bytes,
                      (unsigned long long)(DDR_BASE_PHYS + ACT_BASE),
                      (unsigned long long)(LMM_BASE_PHYS + ACT_BASE),
                      g_dma ? g_dma->ZDMA_CH_STATUS : 0U,
                      g_dma ? g_dma->ZDMA_CH_ISR : 0U,
                      vpu_rd32(REG_STATUS),
                      vpu_rd32(REG_PROGRESS));
            return false;
        }
        const long long act1 = now_us();

        const long long weight0 = now_us();
        // RTL input transfer: the packed Q8_0 weight bytes are copied into
        // WEIGHT_BASE using the same row-major beat layout decoded by RTL.
        if (!dma_write_ip_bytes(WEIGHT_BASE, weight_bytes, "WEIGHT"))
        {
            LOGHWFAIL("stage=DMA_WEIGHT tensor=%s layer=%d phase=%s shape=K%lld_N%lld_M%lld tile=%u rows=%d col_beats=%d bytes=%zu src_phys=0x%llx dst_phys=0x%llx dma_status=0x%08x dma_isr=0x%08x vpu_status=0x%08x progress=0x%08x",
                      tensor_name ? tensor_name : "?",
                      layer_id,
                      decode_or_prefill(m),
                      (long long)k, (long long)n, (long long)m,
                      tile_id,
                      rows,
                      col_beats,
                      weight_bytes,
                      (unsigned long long)(DDR_BASE_PHYS + WEIGHT_BASE),
                      (unsigned long long)(LMM_BASE_PHYS + WEIGHT_BASE),
                      g_dma ? g_dma->ZDMA_CH_STATUS : 0U,
                      g_dma ? g_dma->ZDMA_CH_ISR : 0U,
                      vpu_rd32(REG_STATUS),
                      vpu_rd32(REG_PROGRESS));
            return false;
        }
        const long long weight1 = now_us();

        if (totals)
        {
            totals->dma_act_us += act1 - act0;
            totals->dma_weight_us += weight1 - weight0;
            totals->activation_bytes += act_bytes;
            totals->weight_bytes += weight_bytes;
        }
    }

    mmio_fence();
    const long long ip0 = now_us();
    // RTL execution trigger: after ACT_BASE and WEIGHT_BASE are valid,
    // CTRL_START asks the VPU to consume both windows and write RESULT_BASE.
    vpu_wr32(REG_CTRL, CTRL_START);
    mmio_fence();

    uint32_t vpu_status = 0;
    if (!wait_vpu_done(&vpu_status))
    {
        LOGE("VPU failed tensor=%s layer=%d shape=K%lld_N%lld_M%lld tile=%u status=0x%08x progress=0x%08x",
             tensor_name ? tensor_name : "?",
             layer_id,
             (long long)k,
             (long long)n,
             (long long)m,
             tile_id,
             vpu_status,
             vpu_rd32(REG_PROGRESS));
        LOGHWFAIL("stage=VPU_WAIT tensor=%s layer=%d phase=%s path=%s shape=K%lld_N%lld_M%lld tile=%u rows=%d col_beats=%d mode=0x%x status=0x%08x progress=0x%08x ctrl=0x%08x",
                  tensor_name ? tensor_name : "?",
                  layer_id,
                  decode_or_prefill(m),
                  g_use_zdma_path ? "zdma_ddr_to_ip" : "direct_vpu_mmio",
                  (long long)k, (long long)n, (long long)m,
                  tile_id,
                  rows,
                  col_beats,
                  mode,
                  vpu_status,
                  vpu_rd32(REG_PROGRESS),
                  vpu_rd32(REG_CTRL));
        return false;
    }
    const long long ip1 = now_us();

    if (totals)
    {
        totals->ip_compute_us += ip1 - ip0;
        totals->vpu_runs++;
    }

    if (g_use_zdma_path)
    {
        const long long result0 = now_us();
        // RTL output transfer: RESULT_BASE contains raw INT32 partial sums
        // produced by hardware, and ZDMA copies them back to DDR for the host.
        if (!dma_read_ip_bytes(RESULT_BASE, result_bytes, "RESULT"))
        {
            LOGHWFAIL("stage=DMA_RESULT tensor=%s layer=%d phase=%s shape=K%lld_N%lld_M%lld tile=%u rows=%d col_beats=%d bytes=%zu src_phys=0x%llx dst_phys=0x%llx dma_status=0x%08x dma_isr=0x%08x vpu_status=0x%08x progress=0x%08x",
                      tensor_name ? tensor_name : "?",
                      layer_id,
                      decode_or_prefill(m),
                      (long long)k, (long long)n, (long long)m,
                      tile_id,
                      rows,
                      col_beats,
                      result_bytes,
                      (unsigned long long)(LMM_BASE_PHYS + RESULT_BASE),
                      (unsigned long long)(DDR_BASE_PHYS + RESULT_BASE),
                      g_dma ? g_dma->ZDMA_CH_STATUS : 0U,
                      g_dma ? g_dma->ZDMA_CH_ISR : 0U,
                      vpu_rd32(REG_STATUS),
                      vpu_rd32(REG_PROGRESS));
            return false;
        }
        const long long result1 = now_us();
        if (totals)
        {
            totals->dma_result_us += result1 - result0;
            totals->result_bytes += result_bytes;
        }
    }

    LOGIP("tensor=%s layer=%d shape=K%lldxN%lldxM%lld tile=%u rows=%d col_beats=%d mode=0x%x ip_ms=%.3f status=0x%08x progress=0x%08x",
          tensor_name ? tensor_name : "?",
          layer_id,
          (long long)k,
          (long long)n,
          (long long)m,
          tile_id,
          rows,
          col_beats,
          mode,
          (double)(ip1 - ip0) / 1000.0,
          vpu_status,
          vpu_rd32(REG_PROGRESS));
    return true;
}

/**
 * Run a minimal one-row direct dot-product self-test through the VPU datapath.
 */
static bool fpga_dma_basic_self_test(void)
{
    int8_t ones[VPU_QK8_0];
    for (int i = 0; i < VPU_QK8_0; ++i)
    {
        ones[i] = 1;
    }
    clear_stage_window(ACT_BASE, VPU_BLOCK_BEATS * 16U);
    clear_stage_window(WEIGHT_BASE, VPU_BLOCK_BEATS * 16U);
    clear_stage_window(RESULT_BASE, 16U);
    for (int beat = 0; beat < VPU_BLOCK_BEATS; ++beat)
    {
        write_i8x16_to_stage(act_word_offset(beat), ones + beat * VPU_NUM_LANES);
        write_i8x16_to_stage(weight_word_offset(0, beat, VPU_BLOCK_BEATS), ones + beat * VPU_NUM_LANES);
    }

    fpga_stage_totals_t totals = {};
    if (!run_vpu_window_transfer(1, VPU_BLOCK_BEATS, 0,
                                 VPU_QK8_0,
                                 VPU_QK8_0,
                                 16U,
                                 "selftest.basic", -1, 32, 1, 1, 0, &totals))
    {
        return false;
    }

    int32_t lanes[4] = {};
    read_result_i32x4_from_stage(0, lanes);
    LOGI("basic %s self-test result=%d expected=32", g_use_zdma_path ? "ZDMA" : "direct-VPU", lanes[0]);
    return lanes[0] == 32;
}

/**
 * Run a packed Q8 self-test that verifies multiple partial results are returned correctly.
 */
static bool fpga_dma_packed_self_test(void)
{
    int8_t act0[VPU_QK8_0];
    int8_t act1[VPU_QK8_0];
    int8_t w_row0_block0[VPU_QK8_0];
    int8_t w_row0_block1[VPU_QK8_0];
    int8_t w_row1_block0[VPU_QK8_0];
    int8_t w_row1_block1[VPU_QK8_0];
    for (int i = 0; i < VPU_QK8_0; ++i)
    {
        act0[i] = 1;
        act1[i] = 2;
        w_row0_block0[i] = 1;
        w_row0_block1[i] = 1;
        w_row1_block0[i] = -1;
        w_row1_block1[i] = 3;
    }

    const int rows = 2;
    const int group_blocks = 2;
    const int group_beats = group_blocks * VPU_BLOCK_BEATS;
    const uint32_t row0_block0_off = weight_word_offset(0, 0, group_beats);
    const uint32_t row0_block1_off = weight_word_offset(0, VPU_BLOCK_BEATS, group_beats);
    const uint32_t row1_block0_off = weight_word_offset(1, 0, group_beats);
    const uint32_t row1_block1_off = weight_word_offset(1, VPU_BLOCK_BEATS, group_beats);
    const size_t weight_span_bytes = weight_span_bytes_for_rows(rows, group_beats);

    clear_stage_window(ACT_BASE, (size_t)group_beats * 16U);
    clear_stage_window(WEIGHT_BASE, weight_span_bytes);
    clear_stage_window(RESULT_BASE, 16U);

    for (int beat = 0; beat < VPU_BLOCK_BEATS; ++beat)
    {
        write_i8x16_to_stage(act_word_offset(beat), act0 + beat * VPU_NUM_LANES);
        write_i8x16_to_stage(act_word_offset(VPU_BLOCK_BEATS + beat), act1 + beat * VPU_NUM_LANES);
        write_i8x16_to_stage(weight_word_offset(0, beat, group_beats), w_row0_block0 + beat * VPU_NUM_LANES);
        write_i8x16_to_stage(weight_word_offset(0, VPU_BLOCK_BEATS + beat, group_beats), w_row0_block1 + beat * VPU_NUM_LANES);
        write_i8x16_to_stage(weight_word_offset(1, beat, group_beats), w_row1_block0 + beat * VPU_NUM_LANES);
        write_i8x16_to_stage(weight_word_offset(1, VPU_BLOCK_BEATS + beat, group_beats), w_row1_block1 + beat * VPU_NUM_LANES);
    }

    fpga_stage_totals_t totals = {};
    if (!run_vpu_window_transfer(rows, group_beats, VPU_MODE_PACKED_Q8,
                                 4U * 16U,
                                 weight_span_bytes,
                                 16U,
                                 "selftest.packed", -1, 64, 2, 1, 1, &totals))
    {
        return false;
    }

    int32_t lanes[4] = {};
    read_result_i32x4_from_stage(0, lanes);
    LOGI("packed %s self-test results=[%d,%d,%d,%d] expected=[32,64,-32,192]",
         g_use_zdma_path ? "ZDMA" : "direct-VPU",
         lanes[0], lanes[1], lanes[2], lanes[3]);
    const bool pass = lanes[0] == 32 && lanes[1] == 64 && lanes[2] == -32 && lanes[3] == 192;
    if (!pass)
    {
        LOGSELF("g_vpu_max_beats=%d group_beats=%d", g_vpu_max_beats, group_beats);
        LOGSELF("row0_block0_offsets=0x%08x..0x%08x row0_block1_offsets=0x%08x..0x%08x",
                row0_block0_off, row0_block0_off + 16U, row0_block1_off, row0_block1_off + 16U);
        LOGSELF("row1_block0_offsets=0x%08x..0x%08x row1_block1_offsets=0x%08x..0x%08x",
                row1_block0_off, row1_block0_off + 16U, row1_block1_off, row1_block1_off + 16U);
        log_vpu_u32_words("weight_base_first64", WEIGHT_BASE, 64U);
        log_vpu_u32_words("weight_row1_first64", weight_word_offset(1, 0, group_beats), 64U);
        LOGSELF("packed_result=[%d,%d,%d,%d]", lanes[0], lanes[1], lanes[2], lanes[3]);
    }
    return pass;
}

/**
 * Validate that ggml tensors match the supported FPGA contract.
 * The required contract is Q8_0 weights times F32 activation into F32 output, with K divisible by 32 and no batched higher dimensions.
 */
static bool fpga_validate_tensors(
    const struct ggml_tensor *src0,
    const struct ggml_tensor *src1,
    const struct ggml_tensor *dst,
    const char **reason)
{
    if (!src0 || !src1 || !dst)
    {
        *reason = "unsupported DMA-to-IP tiling case: null tensor";
        return false;
    }
    if (src0->type != GGML_TYPE_Q8_0 || src1->type != GGML_TYPE_F32 || dst->type != GGML_TYPE_F32)
    {
        *reason = "unsupported DMA-to-IP tiling case: requires Q8_0 x F32 -> F32";
        return false;
    }

    const int64_t k = src0->ne[0];
    const int64_t n = src0->ne[1];
    const int64_t m = src1->ne[1];
    if (k <= 0 || n <= 0 || m <= 0)
    {
        *reason = "unsupported DMA-to-IP tiling case: empty tensor";
        return false;
    }
    if (k != src1->ne[0] || n != dst->ne[0] || m != dst->ne[1])
    {
        *reason = "unsupported DMA-to-IP tiling case: shape mismatch";
        return false;
    }
    if (k % VPU_QK8_0 != 0)
    {
        *reason = "unsupported DMA-to-IP tiling case: K is not divisible by 32";
        return false;
    }
    if (src0->nb[0] != (int64_t)sizeof(block_q8_0_t))
    {
        *reason = "unsupported DMA-to-IP tiling case: Q8_0 block stride mismatch";
        return false;
    }
    if (src0->nb[1] < (k / VPU_QK8_0) * src0->nb[0])
    {
        *reason = "unsupported DMA-to-IP tiling case: Q8_0 row stride too small";
        return false;
    }
    if (src0->ne[2] != 1 || src0->ne[3] != 1 ||
        src1->ne[2] != 1 || src1->ne[3] != 1 ||
        dst->ne[2] != 1 || dst->ne[3] != 1)
    {
        *reason = "unsupported DMA-to-IP tiling case: batched tensor dimensions";
        return false;
    }
    if (src1->nb[0] != (int64_t)sizeof(float) || dst->nb[0] != (int64_t)sizeof(float))
    {
        *reason = "unsupported DMA-to-IP tiling case: non-F32 row stride";
        return false;
    }
    if (!g_packed_q8_supported)
    {
        *reason = "unsupported DMA-to-IP tiling case: packed Q8 capability unavailable";
        return false;
    }
    return true;
}

/**
 * Choose how many Q8_0 blocks can be grouped in one VPU tile.
 * The result respects beat capacity, result packing capacity, runtime caps, and remaining K blocks.
 */
static int packed_q8_group_blocks_for_rows(int rows, int remaining_blocks)
{
    const int beat_limited_blocks = std::max(1, g_vpu_max_beats / VPU_BLOCK_BEATS);
    const int result_limited_blocks =
        std::max(1, (g_packed_q8_result_words * VPU_RESULT_PACK_LANES) / std::max(1, rows));
    int blocks = std::min(g_packed_q8_max_blocks, beat_limited_blocks);
    blocks = std::min(blocks, result_limited_blocks);
    blocks = std::min(blocks, remaining_blocks);
    return std::max(1, blocks);
}

/**
 * Run a self-test that spans more Q8 blocks than one group can hold.
 * This verifies host tiling and result accumulation across multiple groups.
 */
static bool fpga_dma_multi_group_self_test(void)
{
    const int rows = 2;
    const int total_blocks = std::max(36, g_packed_q8_max_blocks + 1);
    int32_t accum[2] = {};

    int processed_blocks = 0;
    uint16_t tile_id = 2;
    while (processed_blocks < total_blocks)
    {
        const int group_blocks =
            packed_q8_group_blocks_for_rows(rows, total_blocks - processed_blocks);
        const int group_beats = group_blocks * VPU_BLOCK_BEATS;
        const size_t weight_span_bytes = weight_span_bytes_for_rows(rows, group_beats);

        int8_t act[VPU_QK8_0];
        int8_t w_row0[VPU_QK8_0];
        int8_t w_row1[VPU_QK8_0];
        for (int i = 0; i < VPU_QK8_0; ++i)
        {
            act[i] = 1;
            w_row0[i] = 1;
            w_row1[i] = -1;
        }

        clear_stage_window(ACT_BASE, (size_t)group_beats * 16U);
        clear_stage_window(WEIGHT_BASE, weight_span_bytes);
        clear_stage_window(RESULT_BASE, 16U * (size_t)g_packed_q8_result_words);

        for (int gb = 0; gb < group_blocks; ++gb)
        {
            for (int beat = 0; beat < VPU_BLOCK_BEATS; ++beat)
            {
                const uint32_t act_word =
                    (uint32_t)gb * (uint32_t)VPU_BLOCK_BEATS + (uint32_t)beat;
                write_i8x16_to_stage(act_word_offset((int)act_word), act + beat * VPU_NUM_LANES);

                const uint32_t row0_word =
                    (uint32_t)gb * (uint32_t)VPU_BLOCK_BEATS + (uint32_t)beat;
                const uint32_t row1_word =
                    (uint32_t)weight_row_stride_beats(group_beats) + row0_word;
                write_i8x16_to_stage(WEIGHT_BASE + row0_word * 16U, w_row0 + beat * VPU_NUM_LANES);
                write_i8x16_to_stage(WEIGHT_BASE + row1_word * 16U, w_row1 + beat * VPU_NUM_LANES);
            }
        }

        const uint32_t result_values = (uint32_t)rows * (uint32_t)group_blocks;
        const uint32_t result_words =
            (result_values + (uint32_t)VPU_RESULT_PACK_LANES - 1U) /
            (uint32_t)VPU_RESULT_PACK_LANES;

        fpga_stage_totals_t totals = {};
        if (!run_vpu_window_transfer(rows, group_beats, VPU_MODE_PACKED_Q8,
                                     (size_t)group_beats * 16U,
                                     weight_span_bytes,
                                     (size_t)result_words * 16U,
                                     "selftest.multi_group", -1,
                                     (int64_t)total_blocks * VPU_QK8_0,
                                     rows, 1, tile_id++, &totals))
        {
            return false;
        }

        int32_t lanes[VPU_RESULT_PACK_LANES] = {};
        for (uint32_t word = 0; word < result_words; ++word)
        {
            read_result_i32x4_from_stage(word, lanes);
            for (int lane = 0; lane < VPU_RESULT_PACK_LANES; ++lane)
            {
                const uint32_t idx = word * (uint32_t)VPU_RESULT_PACK_LANES + (uint32_t)lane;
                if (idx < result_values)
                {
                    const int row = (int)(idx / (uint32_t)group_blocks);
                    accum[row] += lanes[lane];
                }
            }
        }

        processed_blocks += group_blocks;
    }

    const int32_t expected0 = 32 * total_blocks;
    const int32_t expected1 = -32 * total_blocks;
    LOGI("multi-group %s self-test results=[%d,%d] expected=[%d,%d] blocks=%d max_group_blocks=%d",
         g_use_zdma_path ? "ZDMA" : "direct-VPU",
         accum[0], accum[1], expected0, expected1, total_blocks, g_packed_q8_max_blocks);
    return accum[0] == expected0 && accum[1] == expected1;
}

/**
 * Run one row-tile and K-group tile on the VPU.
 * The function writes weight and activation beats to RTL-visible windows, launches hardware, reads INT32 partials, and returns scales for host accumulation.
 * src0 is the Q8_0 weight tensor. act_group is the already-quantized activation block group for one input column. row0 and rows define the output-row tile. k_block0 and group_blocks define the Q8_0 block range along K. partial receives raw INT32 results from RTL. weight_scales receives the FP16 Q8_0 scales decoded on the host. totals, tile_id, tensor_name, layer_id, k, n, and m are used for timing, diagnostics, and failure context.
 */
static bool fpga_dma_run_q8_group(
    const struct ggml_tensor *src0,
    const block_q8_0_t *act_group,
    int64_t row0,
    int rows,
    int64_t k_block0,
    int group_blocks,
    std::vector<int32_t> &partial,
    std::vector<float> &weight_scales,
    fpga_stage_totals_t *totals,
    uint16_t tile_id,
    const char *tensor_name,
    int layer_id,
    int64_t k,
    int64_t n,
    int64_t m)
{
    if (rows <= 0 || rows > g_vpu_max_rows || group_blocks <= 0)
    {
        LOGE("unsupported direct-VPU tiling case: rows=%d max_rows=%d group_blocks=%d",
             rows, g_vpu_max_rows, group_blocks);
        return false;
    }

    const int group_beats = group_blocks * VPU_BLOCK_BEATS;
    if (group_beats > g_vpu_max_beats)
    {
        LOGE("unsupported direct-VPU tiling case: group_beats=%d max_beats=%d",
             group_beats, g_vpu_max_beats);
        return false;
    }

    const uint32_t result_values = (uint32_t)rows * (uint32_t)group_blocks;
    const uint32_t result_words = (result_values + (uint32_t)VPU_RESULT_PACK_LANES - 1U) /
                                  (uint32_t)VPU_RESULT_PACK_LANES;
    if (result_words > (uint32_t)g_packed_q8_result_words)
    {
        LOGE("unsupported direct-VPU tiling case: result_words=%u cap=%d", result_words, g_packed_q8_result_words);
        return false;
    }

    const size_t act_bytes = (size_t)group_beats * 16U;
    const size_t weight_span_bytes = weight_span_bytes_for_rows(rows, group_beats);
    const size_t result_bytes = (size_t)result_words * 16U;
    if (!range_fits(ACT_BASE, act_bytes, ACT_BASE, ACT_END) ||
        !range_fits(WEIGHT_BASE, weight_span_bytes, WEIGHT_BASE, WEIGHT_END) ||
        !range_fits(RESULT_BASE, result_bytes, RESULT_BASE, RESULT_END))
    {
        LOGE("unsupported direct-VPU tiling case: window overflow act=%zu weight_span=%zu result=%zu",
             act_bytes, weight_span_bytes, result_bytes);
        return false;
    }

    const long long prep0 = now_us();
    vpu_clear_window(RESULT_BASE, align_up_size(result_bytes, 16U));
    weight_scales.resize((size_t)rows * (size_t)group_blocks);
    for (int row = 0; row < rows; ++row)
    {
        for (int gb = 0; gb < group_blocks; ++gb)
        {
            const block_q8_0_t *wb = weight_block(src0, row0 + row, k_block0 + gb);
            float weight_scale = fp16_to_fp32(wb->d);
            if (!std::isfinite(weight_scale))
            {
                g_nonfinite_weight_scale_count++;
                if (totals)
                {
                    totals->nonfinite_weight_scales++;
                }
                if (g_nonfinite_weight_scale_log_count < kNonFiniteWeightScaleLogLimit)
                {
                    log_nonfinite_weight_scale(
                        src0,
                        wb,
                        tensor_name,
                        layer_id,
                        row0 + row,
                        row,
                        k_block0 + gb,
                        gb,
                        weight_scale);
                    g_nonfinite_weight_scale_log_count++;
                    if (g_nonfinite_weight_scale_log_count == kNonFiniteWeightScaleLogLimit)
                    {
                        LOGW("non-finite Q8_0 weight scale log limit reached; further bad scales will be counted in summary only");
                    }
                }
                if (!kSanitizeNonFiniteWeightScales)
                {
                    return false;
                }
                weight_scale = 0.0f;
                g_sanitized_weight_scale_count++;
                if (totals)
                {
                    totals->sanitized_weight_scales++;
                }
            }
            weight_scales[(size_t)row * (size_t)group_blocks + (size_t)gb] = weight_scale;
        }
    }
    if (totals)
    {
        totals->prep_us += now_us() - prep0;
    }

    const long long transfer_in0 = now_us();
    for (int row = 0; row < rows; ++row)
    {
        for (int gb = 0; gb < group_blocks; ++gb)
        {
            const block_q8_0_t *wb = weight_block(src0, row0 + row, k_block0 + gb);
            for (int beat = 0; beat < VPU_BLOCK_BEATS; ++beat)
            {
                const uint32_t word_index = (uint32_t)row * (uint32_t)weight_row_stride_beats(group_beats) +
                                            (uint32_t)gb * (uint32_t)VPU_BLOCK_BEATS +
                                            (uint32_t)beat;
                // RTL input payload: wb->qs is the quantized Q8_0 weight data
                // consumed from WEIGHT_BASE by the hardware VPU.
                write_i8x16_to_stage(WEIGHT_BASE + word_index * 16U, wb->qs + beat * VPU_NUM_LANES);
            }
        }
    }

    for (int gb = 0; gb < group_blocks; ++gb)
    {
        const block_q8_0_t &act = act_group[gb];
        for (int beat = 0; beat < VPU_BLOCK_BEATS; ++beat)
        {
            const uint32_t word_index = (uint32_t)gb * (uint32_t)VPU_BLOCK_BEATS + (uint32_t)beat;
            // RTL input payload: act.qs is the quantized activation data
            // consumed from ACT_BASE by the hardware VPU.
            write_i8x16_to_stage(ACT_BASE + word_index * 16U, act.qs + beat * VPU_NUM_LANES);
        }
    }
    if (totals)
    {
        const long long transfer_in_us = now_us() - transfer_in0;
        if (g_use_zdma_path)
        {
            totals->prep_us += transfer_in_us;
        }
        else
        {
            totals->dma_act_us += transfer_in_us;
            totals->activation_bytes += act_bytes;
            totals->weight_bytes += weight_span_bytes;
        }
    }

    if (!run_vpu_window_transfer(rows, group_beats, VPU_MODE_PACKED_Q8,
                                 act_bytes, weight_span_bytes, result_bytes,
                                 tensor_name, layer_id, k, n, m, tile_id, totals))
    {
        return false;
    }

    const long long transfer_out0 = now_us();
    partial.resize((size_t)result_values);
    int32_t lanes[VPU_RESULT_PACK_LANES] = {};
    for (uint32_t word = 0; word < result_words; ++word)
    {
        read_result_i32x4_from_stage(word, lanes);
        for (int lane = 0; lane < VPU_RESULT_PACK_LANES; ++lane)
        {
            const uint32_t idx = word * (uint32_t)VPU_RESULT_PACK_LANES + (uint32_t)lane;
            if (idx < result_values)
            {
                partial[(size_t)idx] = lanes[lane];
            }
        }
    }
    if (totals)
    {
        const long long result_read_us = now_us() - transfer_out0;
        if (g_use_zdma_path)
        {
            totals->host_accum_us += result_read_us;
        }
        else
        {
            totals->dma_result_us += result_read_us;
            totals->result_bytes += result_bytes;
        }
    }
    return true;
}

/**
 * Estimate the number of hardware launches needed for one matmul tensor.
 * The estimate follows the same row tiling and Q8 group tiling used by the execution path.
 */
static long long estimate_vpu_runs(int64_t k, int64_t n, int64_t m)
{
    const int64_t nb = k / VPU_QK8_0;
    long long runs_per_m = 0;
    for (int64_t row0 = 0; row0 < n; row0 += g_vpu_max_rows)
    {
        const int rows = (int)std::min<int64_t>(g_vpu_max_rows, n - row0);
        for (int64_t ib0 = 0; ib0 < nb;)
        {
            const int group_blocks = packed_q8_group_blocks_for_rows(rows, (int)(nb - ib0));
            runs_per_m++;
            ib0 += group_blocks;
        }
    }
    return runs_per_m * m;
}

/**
 * Execute a supported Q8_0 x F32 matmul through the FPGA VPU.
 * The function quantizes activations, tiles rows and K blocks, launches VPU groups, scales INT32 partials, accumulates F32 output, and writes dst.
 * src0 is the Q8_0 weight tensor, src1 is the F32 activation tensor, and dst is the ggml output tensor. totals receives timing and byte counters for the whole tensor operation. tensor_name and layer_id identify the model layer in logs and audit messages.
 */
static bool fpga_hw_q8_0_matmul_dma_to_ip(
    const struct ggml_tensor *src0,
    const struct ggml_tensor *src1,
    const struct ggml_tensor *dst,
    fpga_stage_totals_t *totals,
    const char *tensor_name,
    int layer_id)
{
    const int64_t k = src0->ne[0];
    const int64_t n = src0->ne[1];
    const int64_t m = src1->ne[1];
    const int64_t nb = k / VPU_QK8_0;

    std::vector<block_q8_0_t> &act_blocks_all = g_scratch.act_blocks_all;
    std::vector<float> &act_scales = g_scratch.act_scales;
    std::vector<float> &weight_scales = g_scratch.weight_scales;
    std::vector<int32_t> &partial = g_scratch.partial;
    std::vector<float> &accum = g_scratch.accum;

    const long long quant0 = now_us();
    ensure_quantized_activation_matrix(src1, m, k, act_blocks_all, act_scales,
                                       totals, tensor_name, layer_id);
    if (totals)
    {
        totals->prep_us += now_us() - quant0;
    }

    uint16_t tile_id = 0;
    for (int64_t row0 = 0; row0 < n; row0 += g_vpu_max_rows)
    {
        const int rows = (int)std::min<int64_t>(g_vpu_max_rows, n - row0);
        accum.assign((size_t)(m * rows), 0.0f);

        for (int64_t ib0 = 0; ib0 < nb;)
        {
            const int remaining_blocks = (int)(nb - ib0);
            const int group_blocks = packed_q8_group_blocks_for_rows(rows, remaining_blocks);
            const int group_beats = group_blocks * VPU_BLOCK_BEATS;

            LOGTILE("tensor=%s layer=%d row0=%lld rows=%d k_block0=%lld group_blocks=%d group_beats=%d tile_id=%u partial_accum=1 transfer=%s",
                    tensor_name ? tensor_name : "?",
                    layer_id,
                    (long long)row0,
                    rows,
                    (long long)ib0,
                    group_blocks,
                    group_beats,
                    tile_id,
                    g_use_zdma_path ? "zdma_ddr_to_ip" : "direct_vpu_mmio");

            for (int64_t col = 0; col < m; ++col)
            {
                const block_q8_0_t *act_group =
                    &act_blocks_all[(size_t)(col * nb + ib0)];
                if (!fpga_dma_run_q8_group(src0, act_group, row0, rows, ib0, group_blocks,
                                           partial, weight_scales, totals, tile_id++,
                                           tensor_name, layer_id, k, n, m))
                {
                    return false;
                }

                const long long accum0 = now_us();
                float *accum_col = &accum[(size_t)(col * rows)];
                for (int row = 0; row < rows; ++row)
                {
                    for (int gb = 0; gb < group_blocks; ++gb)
                    {
                        const int64_t ib = ib0 + gb;
                        const int32_t raw = partial[(size_t)row * (size_t)group_blocks + (size_t)gb];
                        const float act_scale = act_scales[(size_t)(col * nb + ib)];
                        const float weight_scale =
                            weight_scales[(size_t)row * (size_t)group_blocks + (size_t)gb];
                        const float scale_product = act_scale * weight_scale;
                        const float accum_before = accum_col[(size_t)row];
                        const float accum_after = accum_before + (float)raw * scale_product;
                        if (!std::isfinite(accum_after))
                        {
                            char raw_buf[160];
                            const int raw_count = std::min<int>((int)partial.size(), 8);
                            format_i32_samples(partial.data(), raw_count, raw_buf, sizeof(raw_buf));
                            if (!std::isfinite(weight_scale))
                            {
                                log_nonfinite_weight_scale(
                                    src0,
                                    weight_block(src0, row0 + row, ib),
                                    tensor_name,
                                    layer_id,
                                    row0 + row,
                                    row,
                                    ib,
                                    gb,
                                    weight_scale);
                            }
                            fpga_log_line(true, "NONFINITE", true,
                                          "tensor=%s layer=%d phase=%s row=%lld col=%lld local_row=%d k_block=%lld group_block=%d value=%.6g",
                                          tensor_name ? tensor_name : "?",
                                          layer_id,
                                          decode_or_prefill(m),
                                          (long long)(row0 + row),
                                          (long long)col,
                                          row,
                                          (long long)ib,
                                          gb,
                                          accum_after);
                            log_src1_stats_for_col(src1, col, k);
                            if (!std::isfinite(act_scale))
                            {
                                const block_q8_0_t *bad_act =
                                    &act_blocks_all[(size_t)(col * nb + ib)];
                                log_nonfinite_activation_scale(
                                    src1,
                                    col,
                                    ib,
                                    k,
                                    bad_act,
                                    tensor_name,
                                    layer_id,
                                    m);
                            }
                            fpga_log_line(true, "NONFINITE_SCALE", true,
                                          "row=%lld block=%lld act_scale=%.9g weight_scale=%.9g scale_product=%.9g act_scale_finite=%d weight_scale_finite=%d",
                                          (long long)(row0 + row),
                                          (long long)ib,
                                          act_scale,
                                          weight_scale,
                                          scale_product,
                                          std::isfinite(act_scale) ? 1 : 0,
                                          std::isfinite(weight_scale) ? 1 : 0);
                            fpga_log_line(true, "NONFINITE_RAW", true,
                                          "raw_partial=%d raw_first8=%s group_blocks=%d rows=%d result_values=%zu",
                                          raw,
                                          raw_buf,
                                          group_blocks,
                                          rows,
                                          partial.size());
                            fpga_log_line(true, "NONFINITE_ACCUM", true,
                                          "accum_before=%.9g accum_after=%.9g contribution=%.9g",
                                          accum_before,
                                          accum_after,
                                          (float)raw * scale_product);
                            return false;
                        }
                        accum_col[(size_t)row] = accum_after;
                    }
                }
                if (totals)
                {
                    totals->host_accum_us += now_us() - accum0;
                }
            }
            ib0 += group_blocks;
        }

        const long long store0 = now_us();
        for (int64_t col = 0; col < m; ++col)
        {
            const float *accum_col = &accum[(size_t)(col * rows)];
            for (int row = 0; row < rows; ++row)
            {
                store_dst_value(dst, row0 + row, col, accum_col[(size_t)row]);
            }
        }
        if (totals)
        {
            totals->host_accum_us += now_us() - store0;
        }
    }
    return true;
}

/**
 * Initialize the FPGA driver before any tensor is offloaded.
 * The function maps hardware windows, reads RTL capabilities, runs direct and ZDMA self-tests, selects the active data path, and registers cleanup.
 */
int fpga_init(void)
{
    if (vpu_is_mapped())
    {
        return 0;
    }

    const char *path = getenv("FPGA_PATH");
    if (path && strcmp(path, "dma") != 0 && strcmp(path, "auto") != 0 && strcmp(path, "mmio") != 0)
    {
        fpga_fatal("FPGA_PATH=%s is not allowed in direct-VPU correctness build; set FPGA_PATH=dma/mmio/auto or leave it unset", path);
    }
    if (env_flag_enabled("FPGA_DISABLE"))
    {
        fpga_fatal("FPGA_DISABLE is set, but this build must not silently fall back to CPU");
    }

    g_dma_timing_enabled = kLogDmaDetail;
    g_ip_timing_enabled = kLogTileDetail;
    g_stage_summary_enabled = !env_flag_disabled("FPGA_STAGE_LOG");
    g_status_stderr = env_flag_enabled("FPGA_STATUS_STDERR");
    g_trace_data_enabled = env_flag_enabled("FPGA_TRACE_DATA");
    g_debug_compare_enabled = env_flag_enabled("FPGA_DEBUG_COMPARE");
    g_result_audit_enabled = env_flag_enabled("FPGA_RESULT_AUDIT");
    g_layout_audit_enabled = env_flag_enabled("FPGA_LAYOUT_AUDIT");
    g_log_flush_every = 256;
    g_profile_every = env_int_value("FPGA_PROFILE_EVERY", FPGA_DEFAULT_PROFILE_EVERY, 0, 1000000);
    g_ip_status_every = kLogPollStatus ? FPGA_DEFAULT_STATUS_EVERY : 0;
    g_debug_compare_limit = g_debug_compare_enabled
        ? env_int_value("FPGA_DEBUG_COMPARE_LIMIT", FPGA_DEFAULT_DEBUG_COMPARE_LIMIT, 1, 1000000)
        : 0;
    g_dma_timeout_us = env_int64_value("FPGA_DMA_TIMEOUT_US", FPGA_DEFAULT_DMA_TIMEOUT_US, 1000, LLONG_MAX);
    g_ip_timeout_us = env_int64_value("FPGA_IP_TIMEOUT_US", FPGA_DEFAULT_IP_TIMEOUT_US, 1000, LLONG_MAX);
    g_large_matrix_min_macs = env_int64_value(
        "FPGA_LARGE_MATRIX_MIN_MACS", FPGA_DEFAULT_LARGE_MATRIX_MIN_MACS, 0, LLONG_MAX);
    g_fpga_clock_mhz = env_double_value("FPGA_CLOCK_MHZ", 0.0, 0.0, 10000.0);
    g_abort_on_cpu_fallback = !env_flag_disabled("FPGA_ABORT_ON_CPU_FALLBACK");

    if (!map_vpu_only())
    {
        fpga_fatal("direct VPU FPGA init failed; refusing CPU fallback");
    }

    g_fpga_start_us = now_us();
    g_cleanup_done = false;
    g_scratch.activation_cache_valid = false;
    if (!g_atexit_registered)
    {
        atexit(fpga_cleanup);
        g_atexit_registered = true;
    }

    const uint32_t limits = vpu_rd32(REG_LIMITS);
    const uint32_t caps = vpu_rd32(REG_CAPS);
    g_vpu_max_rows = VPU_DEFAULT_ROWS;
    g_vpu_max_beats = VPU_DEFAULT_BEATS;
    g_vpu_max_cols = VPU_DEFAULT_COLS;
    g_packed_q8_supported = 0;
    g_packed_q8_max_blocks = 1;
    g_packed_q8_result_words = VPU_DEFAULT_RESULT_WORDS;
    g_compact_weight_layout = 0;

    const int limit_rows = (int)(limits & 0xFFFFU);
    const int limit_beats = (int)((limits >> 16) & 0xFFFFU);
    if (limit_rows > 0 && limit_rows <= VPU_DEFAULT_ROWS)
    {
        g_vpu_max_rows = limit_rows;
    }
    if (limit_beats > 0 && limit_beats <= VPU_DEFAULT_BEATS)
    {
        g_vpu_max_beats = limit_beats;
        g_vpu_max_cols = g_vpu_max_beats * VPU_NUM_LANES;
    }

    const bool caps_valid = caps != 0U && caps != 0xFFFFFFFFU;
    if (caps_valid && ((caps & 0x2U) != 0U))
    {
        g_compact_weight_layout = 1;
    }

    if (caps_valid && ((caps & 0x1U) != 0U))
    {
        const int cap_blocks = (int)((caps >> 8) & 0xFFU);
        const int cap_result_words = (int)((caps >> 16) & 0xFFFFU);
        if (cap_blocks > 0 && cap_result_words > 0)
        {
            g_packed_q8_supported = 1;
            g_packed_q8_max_blocks = std::min(cap_blocks, g_vpu_max_beats / VPU_BLOCK_BEATS);
            g_packed_q8_result_words = cap_result_words;
        }
    }

    if (!g_packed_q8_supported && !caps_valid)
    {
        g_packed_q8_supported = 1;
        g_packed_q8_max_blocks = std::min(VPU_PACKED_Q8_MAX_BLOCKS, g_vpu_max_beats / VPU_BLOCK_BEATS);
        g_packed_q8_result_words =
            (g_vpu_max_rows * g_packed_q8_max_blocks + VPU_RESULT_PACK_LANES - 1) /
            VPU_RESULT_PACK_LANES;
        LOGI("REG_CAPS is not implemented by this bitstream raw_caps=0x%08x; using legacy packed_q8 defaults and relying on self-tests",
             caps);
    }

    LOGI("host trace version: %s", FPGA_HOST_TRACE_VERSION);
    LOGI("runtime path request: FPGA_PATH=%s baseline=direct_vpu_mmio prefer_zdma=%d force_direct_audit=%d",
         path ? path : "auto(default)", kPreferZdmaPath ? 1 : 0, kForceDirectVpuPathForAudit ? 1 : 0);
    LOGI("bases my_ip=0x%llx reg=0x%llx lmm=0x%llx dma=0x%llx ddr=0x%llx",
         (unsigned long long)MY_IP_BASE_ADDRESS,
         (unsigned long long)REG_BASE_PHYS,
         (unsigned long long)LMM_BASE_PHYS,
         (unsigned long long)DMA_BASE_PHYS,
         (unsigned long long)DDR_BASE_PHYS);
    LOGI("mapping vpu=%s virt=0x%llx size=0x%zx",
         g_vpu_map_source.c_str(), fpga_ptr_addr(g_vpu), g_vpu_map_size);
    LOGI("VPU windows act=0x%08x weight=0x%08x result=0x%08x data_movement=direct_mmio_baseline",
         ACT_BASE, WEIGHT_BASE, RESULT_BASE);
    LOGI("VPU limits rows=%d col_beats=%d cols=%d raw_limits=0x%08x caps=0x%08x packed_q8=%d compact_weight=%d max_group_blocks=%d result_words=%d",
         g_vpu_max_rows, g_vpu_max_beats, g_vpu_max_cols, limits, caps,
         g_packed_q8_supported, g_compact_weight_layout,
         g_packed_q8_max_blocks, g_packed_q8_result_words);
    if (g_vpu_max_beats >= 128)
    {
        LOGI("large on-chip staging detected: MAX_COL_BEATS=%d; compact_weight_layout=%d",
             g_vpu_max_beats, g_compact_weight_layout);
    }
    LOGI("fallback policy: FPGA_ABORT_ON_CPU_FALLBACK=%d default_no_cpu_matmul_fallback=1",
         g_abort_on_cpu_fallback ? 1 : 0);
    LOGI("tensor allowlist: blk.*.{attn_q,attn_k,attn_v,attn_output,ffn_gate,ffn_up,ffn_down}.weight; logits/output and N>%lld use CPU baseline",
         (long long)FPGA_MAX_SAFE_OFFLOAD_N);
    LOGI("debug safe mode force_all_cpu=%d only_ffn=%d only_attention_projection=%d prefill_cpu=%d decode_cpu=%d debug_compare=%d result_audit=%d abort_on_nonfinite=%d",
         kForceAllMatmulCpu ? 1 : 0,
         kFpgaOnlyFFN ? 1 : 0,
         kFpgaOnlyAttentionProjection ? 1 : 0,
         kDisableFpgaForPrefill ? 1 : 0,
         kDisableFpgaForDecode ? 1 : 0,
         g_debug_compare_enabled ? 1 : 0,
         g_result_audit_enabled ? 1 : 0,
         kAbortOnNonFiniteResult ? 1 : 0);
    LOGI("runtime logging stage_log=%d result_audit=%d layout_audit=%d debug_compare=%d debug_compare_limit=%d status_stderr=%d trace_data=%d",
         g_stage_summary_enabled ? 1 : 0,
         g_result_audit_enabled ? 1 : 0,
         g_layout_audit_enabled ? 1 : 0,
         g_debug_compare_enabled ? 1 : 0,
         g_debug_compare_limit,
         g_status_stderr ? 1 : 0,
         g_trace_data_enabled ? 1 : 0);

    if (!g_packed_q8_supported)
    {
        fpga_fatal("packed_q8 capability unavailable in REG_CAPS=0x%08x; refusing CPU fallback", caps);
    }
    g_use_zdma_path = false;
    if (!fpga_dma_basic_self_test())
    {
        fpga_fatal("basic direct-VPU self-test failed; refusing CPU fallback");
    }
    if (!fpga_dma_packed_self_test())
    {
        fpga_fatal("packed Q8 direct-VPU self-test failed; refusing CPU fallback");
    }
    if (!fpga_dma_multi_group_self_test())
    {
        fpga_fatal("multi-group Q8 direct-VPU self-test failed; refusing CPU fallback");
    }
    LOGI("direct_vpu_mmio self-tests passed");

    const bool force_direct = kForceDirectVpuPathForAudit || (path && strcmp(path, "mmio") == 0);
    if (kPreferZdmaPath && !force_direct)
    {
        if (map_zdma_ddr_checked() && fpga_dma_init())
        {
            g_ddr_msync_unsupported = false;
            g_use_zdma_path = true;
            const bool zdma_ok =
                fpga_dma_basic_self_test() &&
                fpga_dma_packed_self_test() &&
                fpga_dma_multi_group_self_test();
            if (zdma_ok)
            {
                g_zdma_selftest_passed = true;
                LOGI("ZDMA self-tests passed; selected path=zdma_ddr_to_ip");
            }
            else
            {
                g_use_zdma_path = false;
                g_zdma_selftest_passed = false;
                LOGE("ZDMA self-test failed; falling back to direct_vpu_mmio for model execution");
            }
        }
        else
        {
            g_use_zdma_path = false;
            g_zdma_selftest_passed = false;
            LOGI("ZDMA path unavailable or runtime checks failed; selected path=direct_vpu_mmio");
        }
    }
    else
    {
        g_use_zdma_path = false;
        g_zdma_selftest_passed = false;
        LOGI("ZDMA path not requested; selected path=direct_vpu_mmio");
    }
    LOGI("active data path=%s zdma_selftest=%s",
         g_use_zdma_path ? "zdma_ddr_to_ip" : "direct_vpu_mmio",
         g_zdma_selftest_passed ? "PASS" : "N/A");

    return 0;
}

/**
 * Release mapped hardware resources and print final FPGA execution summaries.
 * The function unmaps DDR/VPU/DMA, closes /dev/mem, and reports counters and timing buckets.
 */
void fpga_cleanup(void)
{
    pthread_mutex_lock(&g_mutex);
    if (g_cleanup_done)
    {
        pthread_mutex_unlock(&g_mutex);
        return;
    }
    g_cleanup_done = true;

    if (g_ddr_map_base && g_ddr_map_base != MAP_FAILED)
    {
        munmap(g_ddr_map_base, g_ddr_map_size);
    }
    g_ddr_map_base = nullptr;
    g_ddr = nullptr;

    if (g_vpu_map_base && g_vpu_map_base != MAP_FAILED)
    {
        munmap(g_vpu_map_base, g_vpu_map_size);
    }
    g_vpu_map_base = nullptr;
    g_vpu = nullptr;

    if (g_dma_map_base && g_dma_map_base != MAP_FAILED)
    {
        munmap(g_dma_map_base, g_dma_map_size);
    }
    g_dma_map_base = nullptr;
    g_dma = nullptr;

    if (g_mem_fd >= 0)
    {
        close(g_mem_fd);
        g_mem_fd = -1;
    }

    const long long elapsed_us = g_fpga_start_us > 0 ? now_us() - g_fpga_start_us : 0;
    fpga_log_line(true, "SUMMARY", true,
                  "calls=%lld fpga_handled=%lld cpu_fallback=%lld skipped_token_embd=%lld skipped_large_n=%lld skipped_not_allowlisted=%lld rejects=%lld prefill_calls=%lld decode_calls=%lld prefill_cpu_fallback=%lld decode_cpu_fallback=%lld mismatches=%lld prefill_mismatches=%lld decode_mismatches=%lld nonfinite_results=%lld nonfinite_weight_scales=%lld sanitized_weight_scales=%lld nonfinite_activation_scales=%lld activation_scale_overflows=%lld vpu_runs=%lld path=%s elapsed_s=%.3f activation_cache_hits=%lld misses=%lld",
                  g_fpga_count + g_cpu_fallback_count,
                  g_fpga_count,
                  g_cpu_fallback_count,
                  g_fpga_skipped_token_embd_count,
                  g_fpga_skipped_large_n_count,
                  g_fpga_skipped_not_allowlisted_count,
                  g_reject_count,
                  g_prefill_calls,
                  g_decode_calls,
                  g_prefill_cpu_fallback,
                  g_decode_cpu_fallback,
                  g_prefill_mismatch_count + g_decode_mismatch_count,
                  g_prefill_mismatch_count,
                  g_decode_mismatch_count,
                  g_nonfinite_result_count,
                  g_nonfinite_weight_scale_count,
                  g_sanitized_weight_scale_count,
                  g_nonfinite_activation_scale_count,
                  g_activation_scale_overflow_count,
                  g_fpga_vpu_runs,
                  g_use_zdma_path ? "zdma_ddr_to_ip" : "direct_vpu_mmio",
                  elapsed_us > 0 ? (double)elapsed_us / 1000000.0 : 0.0,
                  g_activation_cache_hits,
                  g_activation_cache_misses);
    fpga_log_line(true, "SUMMARY_TIME", true,
                  "prep_ms=%.3f transfer_in_ms=%.3f ip_compute_ms=%.3f transfer_out_ms=%.3f host_accum_ms=%.3f total_ms=%.3f prefill_total_ms=%.3f decode_total_ms=%.3f",
                  (double)g_total_prep_us / 1000.0,
                  (double)g_total_transfer_in_us / 1000.0,
                  (double)g_total_ip_compute_us / 1000.0,
                  (double)g_total_transfer_out_us / 1000.0,
                  (double)g_total_host_accum_us / 1000.0,
                  (double)g_total_stage_us / 1000.0,
                  (double)g_prefill_total_us / 1000.0,
                  (double)g_decode_total_us / 1000.0);
    for (int i = 0; i < 10; ++i)
    {
        if (g_top_slowest[i].total_ms <= 0.0)
        {
            break;
        }
        fpga_log_line(true, "SUMMARY_TOP", true,
                      "rank=%d tensor=%s layer=%d phase=%s total_ms=%.3f prep_ms=%.3f transfer_in_ms=%.3f ip_compute_ms=%.3f transfer_out_ms=%.3f host_accum_ms=%.3f vpu_runs=%lld",
                      i + 1,
                      g_top_slowest[i].tensor,
                      g_top_slowest[i].layer,
                      g_top_slowest[i].phase,
                      g_top_slowest[i].total_ms,
                      g_top_slowest[i].prep_ms,
                      g_top_slowest[i].transfer_in_ms,
                      g_top_slowest[i].ip_compute_ms,
                      g_top_slowest[i].transfer_out_ms,
                      g_top_slowest[i].host_accum_ms,
                      g_top_slowest[i].vpu_runs);
    }
    fflush(fpga_log_fp());
    pthread_mutex_unlock(&g_mutex);
}

/**
 * Legacy low-level matmul API kept only for link compatibility.
 * The current driver does not use this path because it lacks ggml tensor metadata, allowlist checks, strides, context, and Q8_0 layout validation.
 * A, B_d, B_qs, and C are the old raw-pointer activation, scale, quantized-weight, and output buffers. M, K, and N describe the matrix shape. ith is the worker-thread index. All parameters are ignored because the supported implementation enters through fpga_try_matmul_extended.
 */
extern "C" int fpga_run_matmul(
    const float *A,
    const uint16_t *B_d,
    const int8_t *B_qs,
    float *C,
    int M,
    int K,
    int N,
    int ith)
{
    (void)A;
    (void)B_d;
    (void)B_qs;
    (void)C;
    (void)M;
    (void)K;
    (void)N;
    (void)ith;
    LOGE("legacy low-level fpga_run_matmul is disabled; direct VPU path requires ggml tensor hook");
    return 0;
}

/**
 * Update host-side layer, sequence position, and attention-context metadata.
 * These values affect logging, token-boundary timing, and safe cache invalidation on the FPGA path.
 */
void fpga_set_context(int layer_id, int seq_pos, int is_attn)
{
    g_current_layer_id = layer_id;
    g_current_seq_pos = seq_pos;
    g_is_attention_op = is_attn;
}

/**
 * Thin ggml-facing wrapper that forwards a tensor matmul request to fpga_try_matmul_extended.
 * src0 is the weight tensor, src1 is the activation tensor, dst is the destination tensor, and ith is the ggml worker-thread index.
 */
extern "C" int fpga_try_matmul(
    const struct ggml_tensor *src0,
    const struct ggml_tensor *src1,
    const struct ggml_tensor *dst,
    int ith)
{
    return fpga_try_matmul_extended(src0, src1, dst, ith, 0, g_current_seq_pos, 0);
}

/**
 * Detect sequence-position changes and log token-level timing.
 */
static void log_token_boundary_if_needed(int seq_pos)
{
    const long long now = now_us();
    if (g_last_token_seq == INT_MIN)
    {
        g_last_token_seq = seq_pos;
        g_last_token_us = now;
        g_token_matmuls = 0;
        return;
    }
    if (seq_pos != g_last_token_seq)
    {
        const double token_ms = (double)(now - g_last_token_us) / 1000.0;
        LOGTOKEN("seq=%d prev_seq=%d matmuls=%lld token_ms=%.3f est_tokens_s=%.3f",
                 seq_pos,
                 g_last_token_seq,
                 g_token_matmuls,
                 token_ms,
                 token_ms > 0.0 ? 1000.0 / token_ms : 0.0);
        g_last_token_seq = seq_pos;
        g_last_token_us = now;
        g_token_matmuls = 0;
    }
}

/**
 * High-level FPGA matmul hook called from ggml.
 * The function filters tensors, validates layouts, handles thread ownership, launches the VPU path, audits output, updates counters, and returns whether CPU matmul should be skipped.
 * src0 is the model weight tensor, src1 is the activation tensor, dst is the destination tensor, ith is the ggml worker-thread index, layer_id is the caller-provided layer hint, seq_pos is the current token position, and is_attention identifies attention-context calls for logging.
 */
extern "C" int fpga_try_matmul_extended(
    const struct ggml_tensor *src0,
    const struct ggml_tensor *src1,
    const struct ggml_tensor *dst,
    int ith,
    int layer_id,
    int seq_pos,
    int is_attention)
{
    const char *tensor_name = tensor_name_or_unknown(src0);
    const int effective_layer_id = infer_layer_id_from_name(tensor_name, layer_id);
    const int64_t early_k = src0 ? src0->ne[0] : 0;
    const int64_t early_n = src0 ? src0->ne[1] : 0;
    const int64_t early_m = src1 ? src1->ne[1] : 0;

    const char *skip_reason = nullptr;
    fpga_skip_kind_t skip_kind = FPGA_SKIP_NONE;
    if (!fpga_tensor_allowed(tensor_name, early_n, &skip_reason, &skip_kind))
    {
        if (ith == 0)
        {
            pthread_mutex_lock(&g_mutex);
            record_cpu_fallback(early_m);
            log_fpga_tensor_skip_once(
                tensor_name,
                early_k,
                early_n,
                early_m,
                skip_reason,
                skip_kind);
            pthread_mutex_unlock(&g_mutex);
        }
        return 0;
    }
    const fpga_tensor_category_t early_category = fpga_tensor_category(tensor_name);
    const char *safe_mode_reason = nullptr;
    if (!fpga_debug_safe_mode_allows(early_category, early_m, &safe_mode_reason))
    {
        if (ith == 0)
        {
            pthread_mutex_lock(&g_mutex);
            record_cpu_fallback(early_m);
            if (!g_logged_skip_safe_mode)
            {
                LOGI("skip tensor=%s shape=K%lld_N%lld_M%lld reason=%s action=cpu_baseline",
                     tensor_name,
                     (long long)early_k,
                     (long long)early_n,
                     (long long)early_m,
                     safe_mode_reason ? safe_mode_reason : "debug_safe_mode");
                g_logged_skip_safe_mode = true;
            }
            pthread_mutex_unlock(&g_mutex);
        }
        return 0;
    }

    if (is_attention)
    {
        if (ith == 0)
        {
            pthread_mutex_lock(&g_mutex);
            record_cpu_fallback(early_m);
            pthread_mutex_unlock(&g_mutex);
        }
        return 0;
    }

    const char *reason = nullptr;
    if (!fpga_validate_tensors(src0, src1, dst, &reason))
    {
        if (ith == 0)
        {
            const int64_t k = src0 ? src0->ne[0] : 0;
            const int64_t n = src0 ? src0->ne[1] : 0;
            const int64_t m = src1 ? src1->ne[1] : 0;
            pthread_mutex_lock(&g_mutex);
            g_reject_count++;
            record_cpu_fallback(m);
            LOGE("matmul rejected tensor=%s layer=%d shape=K%lld_N%lld_M%lld reason=%s action=%s",
                 tensor_name,
                 effective_layer_id,
                 (long long)k,
                 (long long)n,
                 (long long)m,
                 reason ? reason : "unknown",
                 g_abort_on_cpu_fallback ? "abort_no_cpu_fallback" : "return_to_cpu");
            pthread_mutex_unlock(&g_mutex);
            if (g_abort_on_cpu_fallback)
            {
                fpga_fatal("CPU fallback matmul blocked tensor=%s layer=%d reason=%s",
                           tensor_name, effective_layer_id, reason ? reason : "unknown");
            }
        }
        return 0;
    }

    if (!vpu_is_mapped())
    {
        if (ith == 0)
        {
            LOGE("FPGA direct VPU window is not initialized for tensor=%s", tensor_name);
            if (g_abort_on_cpu_fallback)
            {
                fpga_fatal("FPGA direct VPU window is not initialized; refusing CPU fallback");
            }
        }
        return 0;
    }

    if (ith != 0)
    {
        return 1;
    }

    pthread_mutex_lock(&g_mutex);
    log_token_boundary_if_needed(seq_pos);
    g_fpga_allowed_count++;

    const int64_t k = src0->ne[0];
    const int64_t n = src0->ne[1];
    const int64_t m = src1->ne[1];
    const int64_t q8_blocks = k / VPU_QK8_0;
    const long long macs = matrix_mac_count(k, n, m);
    const long long row_tiles = (n + g_vpu_max_rows - 1) / g_vpu_max_rows;
    const int first_tile_rows = (int)std::min<int64_t>(n, g_vpu_max_rows);
    const int max_group_blocks = packed_q8_group_blocks_for_rows(first_tile_rows, (int)q8_blocks);
    const long long estimated_runs = estimate_vpu_runs(k, n, m);
    fpga_stage_totals_t totals = {};

    long long bad_weight_scales = 0;
    if (!fpga_weight_scales_are_finite_cached(
            src0,
            k,
            n,
            tensor_name,
            effective_layer_id,
            &bad_weight_scales))
    {
        LOGW("tensor=%s layer=%d phase=%s shape=K%lld_N%lld_M%lld reason=nonfinite_q8_weight_scale bad_weight_scales=%lld action=fpga_sanitize_weight_scale",
             tensor_name,
             effective_layer_id,
             decode_or_prefill(m),
             (long long)k,
             (long long)n,
             (long long)m,
             bad_weight_scales);
    }

    const long long t0 = now_us();
    log_layout_audit(src0, src1, dst, tensor_name, effective_layer_id);
    LOGTILE("tensor=%s layer=%d seq=%d phase=%s shape=K%lld_N%lld_M%lld path=%s row_tiles=%lld group_tiles_per_rowtile~=%lld q8_blocks=%lld max_group_blocks=%d vpu_runs=%lld",
            tensor_name,
            effective_layer_id,
            seq_pos,
            decode_or_prefill(m),
            (long long)k,
            (long long)n,
            (long long)m,
            g_use_zdma_path ? "zdma_ddr_to_ip" : "direct_vpu_mmio",
            row_tiles,
            (q8_blocks + max_group_blocks - 1) / max_group_blocks,
            (long long)q8_blocks,
            max_group_blocks,
            estimated_runs);

    const bool hw_ok = fpga_hw_q8_0_matmul_dma_to_ip(src0, src1, dst, &totals, tensor_name, effective_layer_id);
    const long long t1 = now_us();
    if (!hw_ok)
    {
        pthread_mutex_unlock(&g_mutex);
        fpga_fatal("FPGA matmul failed tensor=%s layer=%d phase=%s shape=K%lld_N%lld_M%lld path=%s; see preceding [FPGA][NONFINITE_*] or [FPGA][HW_FAIL] logs; refusing CPU fallback",
                   tensor_name, effective_layer_id, decode_or_prefill(m),
                   (long long)k, (long long)n, (long long)m,
                   g_use_zdma_path ? "zdma_ddr_to_ip" : "direct_vpu_mmio");
    }
    const fpga_compare_status_t compare_status =
        debug_compare_fpga_dst(src0, dst, k, n, m, tensor_name, effective_layer_id);
    const bool compare_ok =
        compare_status == FPGA_COMPARE_PASS || compare_status == FPGA_COMPARE_SKIPPED;
    const bool compare_substituted = compare_status == FPGA_COMPARE_SUBSTITUTED;
    const bool compare_mismatch_kept = compare_status == FPGA_COMPARE_MISMATCH_KEPT;
    if (compare_substituted)
    {
        LOGW("debug compare substituted tensor=%s layer=%d phase=%s; continuing with CPU reference dst",
             tensor_name, effective_layer_id, decode_or_prefill(m));
    }
    if (compare_mismatch_kept)
    {
        pthread_mutex_unlock(&g_mutex);
        fpga_fatal("FPGA debug compare mismatch tensor=%s layer=%d phase=%s and CPU reference is non-finite; refusing to let model consume unverifiable dst",
                   tensor_name, effective_layer_id, decode_or_prefill(m));
    }
    const bool result_audit_ok =
        log_result_audit(g_fpga_count + 1, dst, k, n, m, tensor_name, effective_layer_id);
    if (!result_audit_ok && kAbortOnNonFiniteResult)
    {
        pthread_mutex_unlock(&g_mutex);
        fpga_fatal("FPGA result audit failed tensor=%s layer=%d phase=%s; refusing to let model consume bad dst",
                   tensor_name, effective_layer_id, decode_or_prefill(m));
    }
    const bool weight_scale_ok = totals.nonfinite_weight_scales == 0;
    const bool activation_scale_ok = totals.nonfinite_activation_scales == 0;
    if (!weight_scale_ok)
    {
        LOGW("FPGA stage sanitized non-finite weight scales tensor=%s layer=%d phase=%s nonfinite_weight_scales=%lld sanitized_weight_scales=%lld; continuing with backup-v6 behavior",
             tensor_name,
             effective_layer_id,
             decode_or_prefill(m),
             totals.nonfinite_weight_scales,
             totals.sanitized_weight_scales);
    }
    if (!activation_scale_ok)
    {
        LOGE("FPGA stage observed non-finite activation scales tensor=%s layer=%d phase=%s nonfinite_activation_scales=%lld; continuing so caller can inspect stage correctness",
             tensor_name,
             effective_layer_id,
             decode_or_prefill(m),
             totals.nonfinite_activation_scales);
    }

    g_fpga_count++;
    g_token_matmuls++;
    g_fpga_vpu_runs += totals.vpu_runs;
    const double total_ms = (double)(t1 - t0) / 1000.0;
    const double prep_ms = (double)totals.prep_us / 1000.0;
    const double transfer_in_ms = (double)(totals.dma_act_us + totals.dma_weight_us) / 1000.0;
    const double ip_ms = (double)totals.ip_compute_us / 1000.0;
    const double transfer_out_ms = (double)totals.dma_result_us / 1000.0;
    const double host_accum_ms = (double)totals.host_accum_us / 1000.0;

    const long long transfer_in_us = totals.dma_act_us + totals.dma_weight_us;
    const long long transfer_out_us = totals.dma_result_us;
    const long long total_stage_us = t1 - t0;
    g_total_prep_us += totals.prep_us;
    g_total_transfer_in_us += transfer_in_us;
    g_total_ip_compute_us += totals.ip_compute_us;
    g_total_transfer_out_us += transfer_out_us;
    g_total_host_accum_us += totals.host_accum_us;
    g_total_stage_us += total_stage_us;
    if (m == 1)
    {
        g_decode_calls++;
        g_decode_total_us += total_stage_us;
        if (!compare_ok || !result_audit_ok || !weight_scale_ok || !activation_scale_ok)
        {
            g_decode_mismatch_count++;
        }
    }
    else
    {
        g_prefill_calls++;
        g_prefill_total_us += total_stage_us;
        if (!compare_ok || !result_audit_ok || !weight_scale_ok || !activation_scale_ok)
        {
            g_prefill_mismatch_count++;
        }
    }

    const char *dominant = "prep";
    double dominant_ms = prep_ms;
    if (transfer_in_ms > dominant_ms)
    {
        dominant = "transfer_in";
        dominant_ms = transfer_in_ms;
    }
    if (ip_ms > dominant_ms)
    {
        dominant = "ip_compute";
        dominant_ms = ip_ms;
    }
    if (transfer_out_ms > dominant_ms)
    {
        dominant = "transfer_out";
        dominant_ms = transfer_out_ms;
    }
    if (host_accum_ms > dominant_ms)
    {
        dominant = "host_accum";
        dominant_ms = host_accum_ms;
    }

    const size_t effective_bytes =
        totals.activation_bytes + totals.weight_bytes + totals.result_bytes;
    const double gmac_s = total_ms > 0.0 ? (double)macs / (total_ms * 1000000.0) : 0.0;
    const long long group_tiles =
        (q8_blocks + max_group_blocks - 1) / std::max(1, max_group_blocks);
    const char *phase = decode_or_prefill(m);

    record_top_stage(
        tensor_name,
        effective_layer_id,
        phase,
        totals.vpu_runs,
        total_ms,
        prep_ms,
        transfer_in_ms,
        ip_ms,
        transfer_out_ms,
        host_accum_ms);

    const char *stage_status =
        compare_substituted ? "COMPARE_SUBSTITUTED" :
        (!result_audit_ok ? "RESULT_AUDIT_FAIL" :
        (!activation_scale_ok ? "ACT_SCALE_NONFINITE" : (weight_scale_ok ? "OK" : "WEIGHT_SCALE_SANITIZED")));
    const bool compare_required_ok =
        !g_debug_compare_enabled || compare_ok || compare_substituted;
    const char *correctness =
        compare_substituted ? "SUBSTITUTED" :
        ((compare_required_ok && result_audit_ok && weight_scale_ok && activation_scale_ok) ? "PASS" : "FAIL");

    LOGSTAGE("tensor=%s layer=%d phase=%s shape=K%lld_N%lld_M%lld path=%s row_tiles=%lld group_tiles=%lld vpu_runs=%lld prep_ms=%.3f transfer_in_ms=%.3f ip_compute_ms=%.3f transfer_out_ms=%.3f host_accum_ms=%.3f total_ms=%.3f dominant=%s effective_GMAC/s=%.3f status=%s correctness=%s nonfinite_weight_scales=%lld sanitized_weight_scales=%lld nonfinite_activation_scales=%lld activation_scale_overflows=%lld bytes=%zu",
             tensor_name,
             effective_layer_id,
             phase,
             (long long)k,
             (long long)n,
             (long long)m,
             g_use_zdma_path ? "zdma_ddr_to_ip" : "direct_vpu_mmio",
             row_tiles,
             group_tiles,
             totals.vpu_runs,
             prep_ms,
             transfer_in_ms,
             ip_ms,
             transfer_out_ms,
             host_accum_ms,
             total_ms,
             dominant,
             gmac_s,
             stage_status,
             correctness,
             totals.nonfinite_weight_scales,
             totals.sanitized_weight_scales,
             totals.nonfinite_activation_scales,
             totals.activation_scale_overflows,
             effective_bytes);
    if (g_status_stderr && (g_fpga_count == 1 || (g_profile_every > 0 && (g_fpga_count % g_profile_every) == 0)))
    {
        fprintf(stderr,
                "[FPGA][STAGE] tensor=%s layer=%d K=%lld N=%lld M=%lld total_ms=%.3f dma_in_ms=%.3f ip_ms=%.3f dma_out_ms=%.3f\n",
                tensor_name,
                effective_layer_id,
                (long long)k,
                (long long)n,
                (long long)m,
                total_ms,
                transfer_in_ms,
                ip_ms,
                transfer_out_ms);
        fflush(stderr);
    }

    if (kLogTileDetail && macs >= g_large_matrix_min_macs)
    {
        LOGTILE("large tensor=%s layer=%d macs=%lld row_tiles=%lld q8_blocks=%lld vpu_runs=%lld no_cpu_fallback=1",
                tensor_name,
                effective_layer_id,
                macs,
                row_tiles,
                (long long)q8_blocks,
                totals.vpu_runs);
    }

    (void)dominant_ms;
    (void)g_current_layer_id;
    (void)g_is_attention_op;
    pthread_mutex_unlock(&g_mutex);
    return 1;
}

/**
 * Reset host-side FPGA context bookkeeping after a model context reset.
 * This clears the current sequence position and invalidates cached quantized activation blocks; it does not erase the runtime LLM KV cache itself.
 */
extern "C" void fpga_reset_kv_cache(void)
{
    g_current_seq_pos = 0;
    g_scratch.activation_cache_valid = false;
}
