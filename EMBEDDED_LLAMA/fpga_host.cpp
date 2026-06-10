#include "fpga_host.h"
#include "ggml.h"

#include <algorithm>
#include <cerrno>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <fcntl.h>
#include <pthread.h>
#include <sched.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>
#include <vector>

#define FPGA_LOG_FILE_DEFAULT  "log_files/fpga_debug.log"
#define FPGA_LOG_FILE_FALLBACK "/tmp/fpga_debug.log"
#define FPGA_HOST_TRACE_VERSION "2026-06-09-zcu104-inline-trace-v2"

#define FPGA_LOG_LEVEL_INFO   1
#define FPGA_LOG_LEVEL_MATMUL 1
#define FPGA_LOG_LEVEL_REG    0
#define FPGA_LOG_LEVEL_TIMING 1
#define FPGA_LOG_LEVEL_DATA   1

static FILE * fpga_log_fp(void) {
    static FILE * fp = nullptr;
    if (!fp) {
        const char * requested_path = getenv("FPGA_LOG_FILE");
        if (!requested_path || requested_path[0] == '\0') {
            requested_path = FPGA_LOG_FILE_DEFAULT;
            mkdir("log_files", 0775);
        }

        const char * active_path = requested_path;
        fp = fopen(active_path, "a");
        if (!fp && strcmp(requested_path, FPGA_LOG_FILE_FALLBACK) != 0) {
            active_path = FPGA_LOG_FILE_FALLBACK;
            fp = fopen(active_path, "a");
        }
        if (!fp) {
            active_path = "stderr";
            fp = stderr;
        }

        const time_t now = time(nullptr);
        fprintf(fp, "\n============================================================\n");
        fprintf(fp, "[FPGA] Log started at %ld\n", (long) now);
        fprintf(fp, "[FPGA] Log file: %s\n", active_path);
        fprintf(fp, "============================================================\n");
        fflush(fp);
    }
    return fp;
}

#define FPGA_LOG(level_flag, tag, fmt, ...)                                      \
    do {                                                                         \
        if (level_flag) {                                                        \
            FILE * _fp = fpga_log_fp();                                          \
            fprintf(_fp, "[FPGA][%-6s] " fmt "\n", tag, ##__VA_ARGS__);        \
            fflush(_fp);                                                         \
        }                                                                        \
    } while (0)

#define LOGI(fmt, ...) FPGA_LOG(FPGA_LOG_LEVEL_INFO,   "INFO",   fmt, ##__VA_ARGS__)
#define LOGM(fmt, ...) FPGA_LOG(FPGA_LOG_LEVEL_MATMUL, "MATMUL", fmt, ##__VA_ARGS__)
#define LOGR(fmt, ...) FPGA_LOG(FPGA_LOG_LEVEL_REG,    "REG",    fmt, ##__VA_ARGS__)
#define LOGT(fmt, ...) FPGA_LOG(FPGA_LOG_LEVEL_TIMING, "TIMING", fmt, ##__VA_ARGS__)
#define LOGD(fmt, ...) FPGA_LOG(FPGA_LOG_LEVEL_DATA,   "DATA",   fmt, ##__VA_ARGS__)
#define LOGE(fmt, ...) FPGA_LOG(1,                     "ERROR",  fmt, ##__VA_ARGS__)

// Address map from DATN_RTL/RTL/AXI4_Mapping.v and Vivado design_1.bd.
static constexpr uint64_t VPU_BASE_PHYS      = 0x00000000A0000000ULL;
static constexpr uint64_t VPU_RANGE_PHYS     = 0x0000000010000000ULL; // 256 MiB, address editor range
static constexpr uint64_t DDR_RESERVED_BEGIN = 0x0000000070000000ULL;
static constexpr uint64_t DDR_RESERVED_END   = 0x000000007FFFFFFFULL;

static constexpr size_t   VPU_MMAP_SIZE      = 0x00300000; // covers all active VPU windows

static constexpr uint32_t REG_CTRL           = 0x00000000;
static constexpr uint32_t REG_STATUS         = 0x00000010;
static constexpr uint32_t REG_ROWS           = 0x00000020;
static constexpr uint32_t REG_COLS           = 0x00000030;
static constexpr uint32_t REG_COL_BEATS      = 0x00000040;
static constexpr uint32_t REG_SCALE          = 0x00000050;
static constexpr uint32_t REG_MODE           = 0x00000060;
static constexpr uint32_t REG_LIMITS         = 0x00000070;
static constexpr uint32_t REG_PROGRESS       = 0x00000080;

static constexpr uint32_t CTRL_START         = 0x00000001;
static constexpr uint32_t CTRL_CLEAR_DONE    = 0x00000002;
static constexpr uint32_t STATUS_DONE        = 0x00000001;
static constexpr uint32_t STATUS_BUSY        = 0x00000002;
static constexpr uint32_t STATUS_ERROR       = 0x00000004;

static constexpr uint32_t ACT_BASE           = 0x00010000;
static constexpr uint32_t ACT_END            = 0x00020000;
static constexpr uint32_t WEIGHT_BASE        = 0x00100000;
static constexpr uint32_t WEIGHT_END         = 0x00200000;
static constexpr uint32_t RESULT_BASE        = 0x00200000;
static constexpr uint32_t RESULT_END         = 0x00210000;

static constexpr int      VPU_NUM_LANES      = 16;
static constexpr int      VPU_QK8_0          = 32;
static constexpr int      VPU_BLOCK_BEATS    = VPU_QK8_0 / VPU_NUM_LANES;
static constexpr int      VPU_DEFAULT_ROWS   = 128;
static constexpr int      VPU_DEFAULT_BEATS  = 256;
static constexpr int      VPU_DEFAULT_COLS   = VPU_DEFAULT_BEATS * VPU_NUM_LANES;
static constexpr uint32_t VPU_FP16_ONE       = 0x00003C00;
static constexpr int      VPU_POLL_LIMIT     = 1000000;
static constexpr int      TRACE_DEFAULT_CALLS = 8;
static constexpr int      TRACE_ROWS          = 4;

typedef struct {
    uint16_t d;
    int8_t   qs[VPU_QK8_0];
} block_q8_0_t;

static_assert(sizeof(block_q8_0_t) == sizeof(uint16_t) + VPU_QK8_0, "unexpected q8_0 block layout");

static int                 g_mem_fd        = -1;
static volatile uint8_t *  g_vpu           = nullptr;
static pthread_mutex_t     g_mutex         = PTHREAD_MUTEX_INITIALIZER;
static long long           g_fpga_count    = 0;
static long long           g_cpu_count     = 0;
static long long           g_trace_blocks  = 0;
static long long           g_trace_outputs = 0;
static int                 g_vpu_max_rows  = VPU_DEFAULT_ROWS;
static int                 g_vpu_max_beats = VPU_DEFAULT_BEATS;
static int                 g_vpu_max_cols  = VPU_DEFAULT_COLS;
static int                 g_address_map_logged = 0;

static int g_current_layer_id = 0;
int        g_current_seq_pos  = 0;
static int g_is_attention_op  = 0;

static bool env_flag_enabled(const char * name) {
    const char * value = getenv(name);
    if (!value || value[0] == '\0') {
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

static bool env_flag_disabled(const char * name) {
    const char * value = getenv(name);
    if (!value || value[0] == '\0') {
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

static int env_int_value(const char * name, int fallback, int min_value, int max_value) {
    const char * value = getenv(name);
    if (!value || value[0] == '\0') {
        return fallback;
    }

    char * end = nullptr;
    errno = 0;
    const long parsed = strtol(value, &end, 10);
    if (errno != 0 || end == value) {
        return fallback;
    }

    if (parsed < min_value) {
        return min_value;
    }
    if (parsed > max_value) {
        return max_value;
    }
    return (int) parsed;
}

static int trace_call_limit(void) {
    return env_int_value("FPGA_TRACE_CALLS", TRACE_DEFAULT_CALLS, 0, 1000000);
}

static bool trace_data_enabled(void) {
    return !env_flag_disabled("FPGA_TRACE_DATA") && trace_call_limit() > 0;
}

static inline void * mapped_vpu_ptr(void) {
    return const_cast<uint8_t *>(g_vpu);
}

static inline bool vpu_is_mapped(void) {
    return g_vpu && mapped_vpu_ptr() != MAP_FAILED;
}

static inline uint64_t local_to_phys(uint32_t off) {
    return VPU_BASE_PHYS + (uint64_t) off;
}

static bool local_range_fits(uint32_t off, uint32_t bytes, uint32_t begin, uint32_t end) {
    return bytes > 0 && off >= begin && off < end && bytes <= (end - off);
}

static bool mmap_range_fits(uint32_t off, uint32_t bytes) {
    return bytes > 0 && (uint64_t) off + (uint64_t) bytes <= (uint64_t) VPU_MMAP_SIZE;
}

static void log_window(const char * name, uint32_t begin, uint32_t end, const char * access) {
    const uint64_t phys_begin = local_to_phys(begin);
    const uint64_t phys_end = local_to_phys(end - 1U);
    LOGI("map %-8s %-2s local=0x%08x-0x%08x phys=0x%llx-0x%llx bytes=0x%x mmap_ok=%d",
         name,
         access,
         begin,
         end - 1U,
         (unsigned long long) phys_begin,
         (unsigned long long) phys_end,
         end - begin,
         mmap_range_fits(begin, end - begin) ? 1 : 0);
}

static void log_address_map_once(void) {
    if (g_address_map_logged) {
        return;
    }
    g_address_map_logged = 1;

    LOGI("address safety: IP segment phys=0x%llx-0x%llx host_mmap=0x%llx-0x%llx",
         (unsigned long long) VPU_BASE_PHYS,
         (unsigned long long) (VPU_BASE_PHYS + VPU_RANGE_PHYS - 1ULL),
         (unsigned long long) VPU_BASE_PHYS,
         (unsigned long long) (VPU_BASE_PHYS + VPU_MMAP_SIZE - 1ULL));
    LOGI("address safety: DDR reserved 0x%llx-0x%llx is not mmap'ed or written by this host path",
         (unsigned long long) DDR_RESERVED_BEGIN,
         (unsigned long long) DDR_RESERVED_END);
    LOGI("register map: CTRL=0x%llx STATUS=0x%llx ROWS=0x%llx COLS=0x%llx COL_BEATS=0x%llx SCALE=0x%llx MODE=0x%llx LIMITS=0x%llx PROGRESS=0x%llx",
         (unsigned long long) local_to_phys(REG_CTRL),
         (unsigned long long) local_to_phys(REG_STATUS),
         (unsigned long long) local_to_phys(REG_ROWS),
         (unsigned long long) local_to_phys(REG_COLS),
         (unsigned long long) local_to_phys(REG_COL_BEATS),
         (unsigned long long) local_to_phys(REG_SCALE),
         (unsigned long long) local_to_phys(REG_MODE),
         (unsigned long long) local_to_phys(REG_LIMITS),
         (unsigned long long) local_to_phys(REG_PROGRESS));
    log_window("ACT_IN", ACT_BASE, ACT_END, "W");
    log_window("WEIGHT", WEIGHT_BASE, WEIGHT_END, "W");
    log_window("RESULT", RESULT_BASE, RESULT_END, "R");
}

static void log_i8x16_lanes(
        const char * label,
        long long trace_id,
        uint32_t local_off,
        int row,
        int beat,
        const int8_t * lanes) {
    LOGD("%s trace=%lld local=0x%08x phys=0x%llx row=%d beat=%d lanes=[%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d]",
         label,
         trace_id,
         local_off,
         (unsigned long long) local_to_phys(local_off),
         row,
         beat,
         (int) lanes[0],  (int) lanes[1],  (int) lanes[2],  (int) lanes[3],
         (int) lanes[4],  (int) lanes[5],  (int) lanes[6],  (int) lanes[7],
         (int) lanes[8],  (int) lanes[9],  (int) lanes[10], (int) lanes[11],
         (int) lanes[12], (int) lanes[13], (int) lanes[14], (int) lanes[15]);
}

static inline uint32_t pack_u8x4(const int8_t * p) {
    return ((uint32_t) (uint8_t) p[0]) |
           ((uint32_t) (uint8_t) p[1] << 8) |
           ((uint32_t) (uint8_t) p[2] << 16) |
           ((uint32_t) (uint8_t) p[3] << 24);
}

static inline uint32_t rd32(uint32_t off) {
    return *(volatile uint32_t *) (g_vpu + off);
}

static inline void wr32(uint32_t off, uint32_t val) {
    *(volatile uint32_t *) (g_vpu + off) = val;
    __sync_synchronize();
    LOGR("wr32 off=0x%08x val=0x%08x", off, val);
}

static inline void write_i8x16(uint32_t off, const int8_t * lanes) {
    wr32(off + 0,  pack_u8x4(lanes + 0));
    wr32(off + 4,  pack_u8x4(lanes + 4));
    wr32(off + 8,  pack_u8x4(lanes + 8));
    wr32(off + 12, pack_u8x4(lanes + 12));
}

static inline float fp16_to_fp32(uint16_t h) {
    const uint32_t s = (uint32_t) ((h >> 15) & 1U);
    const uint32_t e = (uint32_t) ((h >> 10) & 0x1FU);
    const uint32_t m = (uint32_t) (h & 0x03FFU);
    uint32_t b;

    if (e == 0U) {
        if (m == 0U) {
            b = s << 31;
        } else {
            uint32_t mant = m;
            uint32_t exp = 113U;
            while ((mant & 0x0400U) == 0U) {
                mant <<= 1;
                exp--;
            }
            mant &= 0x03FFU;
            b = (s << 31) | (exp << 23) | (mant << 13);
        }
    } else if (e == 31U) {
        b = (s << 31) | 0x7F800000U | (m << 13);
    } else {
        b = (s << 31) | ((e + 112U) << 23) | (m << 13);
    }

    union {
        uint32_t i;
        float    f;
    } u;
    u.i = b;
    return u.f;
}

static inline uint16_t fp32_to_fp16(float f) {
    union {
        float    f;
        uint32_t i;
    } u;
    u.f = f;

    const uint32_t sign = (u.i >> 16) & 0x8000U;
    int32_t exp = (int32_t) ((u.i >> 23) & 0xFFU) - 127 + 15;
    uint32_t mant = u.i & 0x007FFFFFU;

    if (exp <= 0) {
        if (exp < -10) {
            return (uint16_t) sign;
        }
        mant = (mant | 0x00800000U) >> (1 - exp);
        return (uint16_t) (sign | ((mant + 0x00001000U) >> 13));
    }

    if (exp >= 31) {
        return (uint16_t) (sign | 0x7C00U);
    }

    return (uint16_t) (sign | ((uint32_t) exp << 10) | ((mant + 0x00001000U) >> 13));
}

static void quantize_q8_0_block(const float * x, ptrdiff_t stride_bytes, block_q8_0_t * y) {
    float amax = 0.0f;
    for (int i = 0; i < VPU_QK8_0; ++i) {
        const float v = *(const float *) ((const char *) x + (ptrdiff_t) i * stride_bytes);
        amax = std::max(amax, std::fabs(v));
    }

    const float d_raw = amax / 127.0f;
    const float id = d_raw != 0.0f ? 1.0f / d_raw : 0.0f;
    y->d = fp32_to_fp16(d_raw);

    for (int i = 0; i < VPU_QK8_0; ++i) {
        const float v = *(const float *) ((const char *) x + (ptrdiff_t) i * stride_bytes);
        const int q = (int) std::round(v * id);
        y->qs[i] = (int8_t) std::max(-128, std::min(127, q));
    }
}

static void quantize_activation_vector(
        const struct ggml_tensor * src1,
        int64_t m,
        int64_t k,
        std::vector<block_q8_0_t> & act_blocks) {
    const int64_t nb = k / VPU_QK8_0;
    act_blocks.resize((size_t) nb);

    const char * base = (const char *) src1->data + m * src1->nb[1];
    for (int64_t ib = 0; ib < nb; ++ib) {
        const float * block_base = (const float *) (base + ib * VPU_QK8_0 * src1->nb[0]);
        quantize_q8_0_block(block_base, src1->nb[0], &act_blocks[(size_t) ib]);
    }
}

static const block_q8_0_t * weight_block(
        const struct ggml_tensor * src0,
        int64_t row,
        int64_t block) {
    const char * row_base = (const char *) src0->data + row * src0->nb[1];
    return (const block_q8_0_t *) row_base + block;
}

static void store_dst_value(
        const struct ggml_tensor * dst,
        int64_t row,
        int64_t col,
        float value) {
    char * base = (char *) dst->data;
    *(float *) (base + row * dst->nb[0] + col * dst->nb[1]) = value;
}

static void log_dst_sample(const struct ggml_tensor * dst, int layer_id, int seq_pos) {
    if (!trace_data_enabled()) {
        return;
    }
    if (g_trace_outputs >= trace_call_limit()) {
        return;
    }

    const long long trace_id = g_trace_outputs++;
    const int64_t rows = std::min<int64_t>(dst->ne[0], TRACE_ROWS);
    const int64_t cols = std::min<int64_t>(dst->ne[1], 1);

    LOGD("dst sample trace=%lld layer=%d seq=%d ne=[%lld,%lld,%lld,%lld] nb=[%lld,%lld,%lld,%lld]",
         trace_id,
         layer_id,
         seq_pos,
         (long long) dst->ne[0],
         (long long) dst->ne[1],
         (long long) dst->ne[2],
         (long long) dst->ne[3],
         (long long) dst->nb[0],
         (long long) dst->nb[1],
         (long long) dst->nb[2],
         (long long) dst->nb[3]);

    for (int64_t col = 0; col < cols; ++col) {
        for (int64_t row = 0; row < rows; ++row) {
            const char * base = (const char *) dst->data;
            const float value = *(const float *) (base + row * dst->nb[0] + col * dst->nb[1]);
            LOGD("dst sample trace=%lld row=%lld col=%lld value=%g",
                 trace_id,
                 (long long) row,
                 (long long) col,
                 (double) value);
        }
    }
}

static bool fpga_validate_tensors(
        const struct ggml_tensor * src0,
        const struct ggml_tensor * src1,
        const struct ggml_tensor * dst,
        const char ** reason) {
    if (!src0 || !src1 || !dst) {
        *reason = "null tensor";
        return false;
    }
    if (src0->type != GGML_TYPE_Q8_0 || src1->type != GGML_TYPE_F32 || dst->type != GGML_TYPE_F32) {
        *reason = "requires Q8_0 x F32 -> F32";
        return false;
    }

    const int64_t k = src0->ne[0];
    const int64_t n = src0->ne[1];
    const int64_t m = src1->ne[1];

    if (k <= 0 || n <= 0 || m <= 0) {
        *reason = "empty tensor";
        return false;
    }
    if (k != src1->ne[0] || n != dst->ne[0] || m != dst->ne[1]) {
        *reason = "shape mismatch";
        return false;
    }
    if (k % VPU_QK8_0 != 0) {
        *reason = "K is not divisible by 32";
        return false;
    }
    if (k > g_vpu_max_cols) {
        *reason = "K exceeds VPU local column capacity";
        return false;
    }
    if (src0->ne[2] != 1 || src0->ne[3] != 1 ||
        src1->ne[2] != 1 || src1->ne[3] != 1 ||
        dst->ne[2]  != 1 || dst->ne[3]  != 1) {
        *reason = "batched tensors are not handled by this host path";
        return false;
    }
    if (src1->nb[0] != (int64_t) sizeof(float) || dst->nb[0] != (int64_t) sizeof(float)) {
        *reason = "non-F32 row stride";
        return false;
    }

    return true;
}

static int wait_done(uint32_t * final_status) {
    for (int poll = 0; poll < VPU_POLL_LIMIT; ++poll) {
        const uint32_t status = rd32(REG_STATUS);
        if (final_status) {
            *final_status = status;
        }

        if (status & STATUS_ERROR) {
            return -1;
        }
        if (status & STATUS_DONE) {
            return 0;
        }

        if ((poll & 0x3FF) == 0) {
            sched_yield();
        }
    }

    return -2;
}

static bool fpga_smoke_test(void) {
    int8_t ones[VPU_QK8_0];
    for (int i = 0; i < VPU_QK8_0; ++i) {
        ones[i] = 1;
    }

    wr32(REG_CTRL, CTRL_CLEAR_DONE);
    wr32(REG_ROWS, 1);
    wr32(REG_COLS, VPU_QK8_0);
    wr32(REG_COL_BEATS, VPU_BLOCK_BEATS);
    wr32(REG_SCALE, VPU_FP16_ONE);
    wr32(REG_MODE, 0);

    for (int beat = 0; beat < VPU_BLOCK_BEATS; ++beat) {
        write_i8x16(ACT_BASE + (uint32_t) beat * 16U, ones + beat * VPU_NUM_LANES);
        write_i8x16(WEIGHT_BASE + (uint32_t) beat * 16U, ones + beat * VPU_NUM_LANES);
    }

    __sync_synchronize();
    wr32(REG_CTRL, CTRL_START);

    uint32_t status = 0;
    const int wait_rc = wait_done(&status);
    const int32_t result = (wait_rc == 0) ? (int32_t) rd32(RESULT_BASE) : 0;
    const uint32_t progress = rd32(REG_PROGRESS);

    LOGI("self-test 1x32 result=%d expected=32 wait_rc=%d status=0x%08x progress=0x%08x",
         result, wait_rc, status, progress);

    wr32(REG_CTRL, CTRL_CLEAR_DONE);
    return wait_rc == 0 && result == 32;
}

static bool fpga_run_q8_block(
        const block_q8_0_t & act,
        const struct ggml_tensor * src0,
        int64_t row0,
        int rows,
        int64_t k_block,
        std::vector<int32_t> & partial) {
    partial.assign((size_t) rows, 0);

    if (rows <= 0 || rows > g_vpu_max_rows) {
        LOGE("address guard rejected rows=%d max_rows=%d", rows, g_vpu_max_rows);
        return false;
    }

    const uint32_t act_bytes = (uint32_t) VPU_BLOCK_BEATS * 16U;
    const uint32_t result_bytes = (uint32_t) rows * 16U;
    const uint32_t weight_last_index =
        (uint32_t) (rows - 1) * (uint32_t) g_vpu_max_beats + (uint32_t) (VPU_BLOCK_BEATS - 1);
    const uint32_t weight_bytes_to_last =
        weight_last_index * 16U + 16U;

    if (!local_range_fits(ACT_BASE, act_bytes, ACT_BASE, ACT_END) ||
        !local_range_fits(WEIGHT_BASE, weight_bytes_to_last, WEIGHT_BASE, WEIGHT_END) ||
        !local_range_fits(RESULT_BASE, result_bytes, RESULT_BASE, RESULT_END) ||
        !mmap_range_fits(ACT_BASE, act_bytes) ||
        !mmap_range_fits(WEIGHT_BASE, weight_bytes_to_last) ||
        !mmap_range_fits(RESULT_BASE, result_bytes)) {
        LOGE("address guard rejected transfer: rows=%d row0=%lld k_block=%lld act_bytes=0x%x weight_bytes=0x%x result_bytes=0x%x",
             rows,
             (long long) row0,
             (long long) k_block,
             act_bytes,
             weight_bytes_to_last,
             result_bytes);
        return false;
    }

    const bool trace_this = trace_data_enabled() && g_trace_blocks < trace_call_limit();
    const long long trace_id = trace_this ? g_trace_blocks++ : -1;

    if (trace_this) {
        LOGD("block trace=%lld row0=%lld rows=%d k_block=%lld act_scale_fp16=0x%04x act_phys=0x%llx weight_phys=0x%llx-0x%llx result_phys=0x%llx-0x%llx",
             trace_id,
             (long long) row0,
             rows,
             (long long) k_block,
             (unsigned) act.d,
             (unsigned long long) local_to_phys(ACT_BASE),
             (unsigned long long) local_to_phys(WEIGHT_BASE),
             (unsigned long long) local_to_phys(WEIGHT_BASE + weight_bytes_to_last - 1U),
             (unsigned long long) local_to_phys(RESULT_BASE),
             (unsigned long long) local_to_phys(RESULT_BASE + result_bytes - 1U));
    }

    wr32(REG_CTRL, CTRL_CLEAR_DONE);
    wr32(REG_ROWS, (uint32_t) rows);
    wr32(REG_COLS, VPU_QK8_0);
    wr32(REG_COL_BEATS, VPU_BLOCK_BEATS);
    wr32(REG_SCALE, VPU_FP16_ONE);
    wr32(REG_MODE, 0);

    for (int beat = 0; beat < VPU_BLOCK_BEATS; ++beat) {
        const uint32_t act_off = ACT_BASE + (uint32_t) beat * 16U;
        const int8_t * lanes = act.qs + beat * VPU_NUM_LANES;
        write_i8x16(act_off, lanes);
        if (trace_this) {
            log_i8x16_lanes("ACT_WRITE", trace_id, act_off, 0, beat, lanes);
        }
    }

    for (int row = 0; row < rows; ++row) {
        const block_q8_0_t * wb = weight_block(src0, row0 + row, k_block);
        for (int beat = 0; beat < VPU_BLOCK_BEATS; ++beat) {
            const uint32_t index = (uint32_t) row * (uint32_t) g_vpu_max_beats + (uint32_t) beat;
            const uint32_t weight_off = WEIGHT_BASE + index * 16U;
            const int8_t * lanes = wb->qs + beat * VPU_NUM_LANES;
            write_i8x16(weight_off, lanes);
            if (trace_this && row < TRACE_ROWS) {
                if (beat == 0) {
                    LOGD("weight scale trace=%lld row=%lld local_row=%d k_block=%lld scale_fp16=0x%04x scale_f32=%g",
                         trace_id,
                         (long long) (row0 + row),
                         row,
                         (long long) k_block,
                         (unsigned) wb->d,
                         (double) fp16_to_fp32(wb->d));
                }
                log_i8x16_lanes("WEIGHT_WRITE", trace_id, weight_off, row, beat, lanes);
            }
        }
    }

    __sync_synchronize();
    wr32(REG_CTRL, CTRL_START);

    uint32_t status = 0;
    const int wait_rc = wait_done(&status);
    if (wait_rc != 0) {
        const uint32_t progress = rd32(REG_PROGRESS);
        LOGE("VPU block failed wait_rc=%d status=0x%08x progress=0x%08x row0=%lld rows=%d k_block=%lld",
             wait_rc, status, progress, (long long) row0, rows, (long long) k_block);
        return false;
    }

    for (int row = 0; row < rows; ++row) {
        const uint32_t result_off = RESULT_BASE + (uint32_t) row * 16U;
        partial[(size_t) row] = (int32_t) rd32(result_off);
        if (trace_this && row < TRACE_ROWS) {
            LOGD("RESULT_READ trace=%lld local=0x%08x phys=0x%llx row=%d raw_i32=%d",
                 trace_id,
                 result_off,
                 (unsigned long long) local_to_phys(result_off),
                 row,
                 partial[(size_t) row]);
        }
    }

    return true;
}

static void cpu_reference_q8_0_matmul(
        const struct ggml_tensor * src0,
        const struct ggml_tensor * src1,
        const struct ggml_tensor * dst) {
    const int64_t k = src0->ne[0];
    const int64_t n = src0->ne[1];
    const int64_t m = src1->ne[1];
    const int64_t nb = k / VPU_QK8_0;

    std::vector<block_q8_0_t> act_blocks;
    for (int64_t col = 0; col < m; ++col) {
        quantize_activation_vector(src1, col, k, act_blocks);

        for (int64_t row = 0; row < n; ++row) {
            float acc = 0.0f;
            for (int64_t ib = 0; ib < nb; ++ib) {
                const block_q8_0_t * wb = weight_block(src0, row, ib);
                int32_t sumi = 0;
                for (int j = 0; j < VPU_QK8_0; ++j) {
                    sumi += (int32_t) act_blocks[(size_t) ib].qs[j] * (int32_t) wb->qs[j];
                }
                acc += (float) sumi *
                       fp16_to_fp32(act_blocks[(size_t) ib].d) *
                       fp16_to_fp32(wb->d);
            }
            store_dst_value(dst, row, col, acc);
        }
    }
}

static bool fpga_hw_q8_0_matmul(
        const struct ggml_tensor * src0,
        const struct ggml_tensor * src1,
        const struct ggml_tensor * dst) {
    const int64_t k = src0->ne[0];
    const int64_t n = src0->ne[1];
    const int64_t m = src1->ne[1];
    const int64_t nb = k / VPU_QK8_0;

    std::vector<block_q8_0_t> act_blocks;
    std::vector<int32_t> partial;
    std::vector<float> accum;

    for (int64_t col = 0; col < m; ++col) {
        quantize_activation_vector(src1, col, k, act_blocks);

        for (int64_t row0 = 0; row0 < n; row0 += g_vpu_max_rows) {
            const int rows = (int) std::min<int64_t>(g_vpu_max_rows, n - row0);
            accum.assign((size_t) rows, 0.0f);

            for (int64_t ib = 0; ib < nb; ++ib) {
                if (!fpga_run_q8_block(act_blocks[(size_t) ib], src0, row0, rows, ib, partial)) {
                    return false;
                }

                const float act_scale = fp16_to_fp32(act_blocks[(size_t) ib].d);
                for (int row = 0; row < rows; ++row) {
                    const block_q8_0_t * wb = weight_block(src0, row0 + row, ib);
                    accum[(size_t) row] += (float) partial[(size_t) row] * act_scale * fp16_to_fp32(wb->d);
                }
            }

            for (int row = 0; row < rows; ++row) {
                store_dst_value(dst, row0 + row, col, accum[(size_t) row]);
            }
        }
    }

    return true;
}

int fpga_init(void) {
    if (env_flag_enabled("FPGA_DISABLE")) {
        LOGI("FPGA_DISABLE is set; using CPU fallback");
        return -1;
    }

    if (vpu_is_mapped()) {
        return 0;
    }

    g_mem_fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (g_mem_fd < 0) {
        LOGE("open /dev/mem failed errno=%d (%s)", errno, strerror(errno));
        return -1;
    }

    void * map = mmap(nullptr, VPU_MMAP_SIZE, PROT_READ | PROT_WRITE, MAP_SHARED, g_mem_fd, VPU_BASE_PHYS);
    if (map == MAP_FAILED) {
        LOGE("mmap VPU base 0x%llx size=0x%zx failed errno=%d (%s)",
             (unsigned long long) VPU_BASE_PHYS, VPU_MMAP_SIZE, errno, strerror(errno));
        close(g_mem_fd);
        g_mem_fd = -1;
        return -1;
    }

    g_vpu = (volatile uint8_t *) map;

    uint32_t limits = 0;
    limits = rd32(REG_LIMITS);
    const int limit_rows  = (int) (limits & 0xFFFFU);
    const int limit_beats = (int) ((limits >> 16) & 0xFFFFU);
    if (limit_rows > 0 && limit_rows <= VPU_DEFAULT_ROWS) {
        g_vpu_max_rows = limit_rows;
    } else if (limit_rows > VPU_DEFAULT_ROWS) {
        LOGE("Ignoring unexpected VPU row limit %d; host clamps to RTL default %d", limit_rows, VPU_DEFAULT_ROWS);
    }
    if (limit_beats > 0 && limit_beats <= VPU_DEFAULT_BEATS) {
        g_vpu_max_beats = limit_beats;
        g_vpu_max_cols = g_vpu_max_beats * VPU_NUM_LANES;
    } else if (limit_beats > VPU_DEFAULT_BEATS) {
        LOGE("Ignoring unexpected VPU col-beat limit %d; host clamps to RTL default %d", limit_beats, VPU_DEFAULT_BEATS);
    }

    LOGI("VPU mapped: base=0x%llx range=0x%llx mmap_size=0x%zx",
         (unsigned long long) VPU_BASE_PHYS,
         (unsigned long long) VPU_RANGE_PHYS,
         VPU_MMAP_SIZE);
    LOGI("host trace version: %s", FPGA_HOST_TRACE_VERSION);
    LOGI("DDR reserved by project request: 0x%llx-0x%llx",
         (unsigned long long) DDR_RESERVED_BEGIN,
         (unsigned long long) DDR_RESERVED_END);
    LOGI("VPU limits: rows=%d col_beats=%d cols=%d raw_limits=0x%08x",
         g_vpu_max_rows, g_vpu_max_beats, g_vpu_max_cols, limits);
    LOGI("No ZDMA programming is used: current bitstream exposes an AXI4-Full slave with local BRAM windows");
    LOGI("trace controls: FPGA_TRACE_DATA=0 disables data dump; FPGA_TRACE_CALLS=N changes default first %d traced blocks",
         TRACE_DEFAULT_CALLS);
    log_address_map_once();

    if (limits == 0U || limits == 0xFFFFFFFFU) {
        LOGE("REG_LIMITS read is suspicious (0x%08x); check bitstream load, AXI base address, and PS-PL interconnect",
             limits);
    }

    if (env_flag_enabled("FPGA_SELF_TEST") && !fpga_smoke_test()) {
        LOGE("FPGA_SELF_TEST failed; refusing to enable FPGA acceleration for this process");
        munmap(mapped_vpu_ptr(), VPU_MMAP_SIZE);
        g_vpu = nullptr;
        close(g_mem_fd);
        g_mem_fd = -1;
        return -1;
    }

    return 0;
}

void fpga_cleanup(void) {
    pthread_mutex_lock(&g_mutex);

    if (vpu_is_mapped()) {
        munmap(mapped_vpu_ptr(), VPU_MMAP_SIZE);
    }
    g_vpu = nullptr;

    if (g_mem_fd >= 0) {
        close(g_mem_fd);
        g_mem_fd = -1;
    }

    LOGI("cleanup complete fpga_calls=%lld software_fallbacks=%lld", g_fpga_count, g_cpu_count);
    pthread_mutex_unlock(&g_mutex);
}

extern "C" int fpga_run_matmul(
        const float *    A,
        const uint16_t * B_d,
        const int8_t *   B_qs,
        float *          C,
        int M,
        int K,
        int N,
        int ith) {
    (void) A;
    (void) B_d;
    (void) B_qs;
    (void) C;
    (void) M;
    (void) K;
    (void) N;
    (void) ith;

    LOGE("legacy fpga_run_matmul(A,B_d,B_qs,C,...) is disabled for this bitstream; use ggml tensor hook");
    return 0;
}

void fpga_set_context(int layer_id, int seq_pos, int is_attn) {
    g_current_layer_id = layer_id;
    g_current_seq_pos  = seq_pos;
    g_is_attention_op  = is_attn;
}

extern "C" int fpga_try_matmul(
        const struct ggml_tensor * src0,
        const struct ggml_tensor * src1,
        const struct ggml_tensor * dst,
        int ith) {
    return fpga_try_matmul_extended(src0, src1, dst, ith, 0, 0, 0);
}

extern "C" int fpga_try_matmul_extended(
        const struct ggml_tensor * src0,
        const struct ggml_tensor * src1,
        const struct ggml_tensor * dst,
        int ith,
        int layer_id,
        int seq_pos,
        int is_attention) {
    if (is_attention) {
        static int logged_attention_fallback = 0;
        if (!logged_attention_fallback) {
            LOGI("attention path requested but current SoC/VPU bitstream exposes only INT8 GEMV; using CPU fallback");
            logged_attention_fallback = 1;
        }
        return 0;
    }

    const char * reason = nullptr;
    if (!fpga_validate_tensors(src0, src1, dst, &reason)) {
        g_cpu_count++;
        static int logged_rejects = 0;
        if (logged_rejects < 16) {
            LOGI("reject matmul: %s", reason ? reason : "unknown");
            logged_rejects++;
        }
        return 0;
    }

    if (!vpu_is_mapped()) {
        LOGE("reject matmul: fpga_init has not mapped the VPU");
        return 0;
    }

    if (ith != 0) {
        return 1;
    }

    pthread_mutex_lock(&g_mutex);

    LOGM("run layer=%d seq=%d K=%lld N=%lld M=%lld rows_limit=%d beats_limit=%d",
         layer_id,
         seq_pos,
         (long long) src0->ne[0],
         (long long) src0->ne[1],
         (long long) src1->ne[1],
         g_vpu_max_rows,
         g_vpu_max_beats);

    const bool hw_ok = fpga_hw_q8_0_matmul(src0, src1, dst);
    if (hw_ok) {
        g_fpga_count++;
        LOGM("done via FPGA total_fpga_calls=%lld", g_fpga_count);
        log_dst_sample(dst, layer_id, seq_pos);
    } else {
        g_cpu_count++;
        LOGE("FPGA runtime failed; computing this accepted matmul with local q8_0 software fallback");
        cpu_reference_q8_0_matmul(src0, src1, dst);
    }

    (void) g_current_layer_id;
    (void) g_is_attention_op;
    pthread_mutex_unlock(&g_mutex);
    return 1;
}

extern "C" void fpga_reset_kv_cache(void) {
    g_current_seq_pos = 0;
}
