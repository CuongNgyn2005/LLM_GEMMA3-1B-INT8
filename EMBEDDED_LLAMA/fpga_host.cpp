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
#include <sys/time.h>
#include <unistd.h>
#include <vector>

#define FPGA_LOG_FILE "/tmp/fpga_debug.log"
#define FPGA_HOST_TRACE_VERSION "2026-06-11-zcu104-packed-q8-v5"

#define FPGA_LOG_LEVEL_INFO   1
#define FPGA_LOG_LEVEL_MATMUL 1
#define FPGA_LOG_LEVEL_REG    0
#define FPGA_LOG_LEVEL_TIMING 1
#define FPGA_LOG_LEVEL_DATA   1

static FILE * fpga_log_fp(void) {
    static FILE * fp = nullptr;
    if (!fp) {
        fp = fopen(FPGA_LOG_FILE, "a");
        if (!fp) {
            fp = stderr;
        }

        const time_t now = time(nullptr);
        fprintf(fp, "\n============================================================\n");
        fprintf(fp, "[FPGA] Log started at %ld\n", (long) now);
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
static constexpr uint32_t REG_CAPS           = 0x00000090;

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
static constexpr int      VPU_RESULT_PACK_LANES = 4;
static constexpr uint32_t VPU_MODE_PACKED_Q8 = 0x00000001;
static constexpr int      VPU_DEFAULT_ROWS   = 256;
static constexpr int      VPU_DEFAULT_BEATS  = 256;
static constexpr int      VPU_DEFAULT_COLS   = VPU_DEFAULT_BEATS * VPU_NUM_LANES;
static constexpr uint32_t VPU_FP16_ONE       = 0x00003C00;
static constexpr int      VPU_POLL_LIMIT     = 1000000;
static constexpr int      TRACE_DEFAULT_CALLS = 8;
static constexpr int      TRACE_ROWS          = 4;
static constexpr int      FPGA_DEFAULT_MIN_N  = 0;
static constexpr int      FPGA_DEFAULT_MAX_N  = 65536;
static constexpr int      FPGA_DEFAULT_DECODE_MAX_N = 4096;

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
static long long           g_fpga_vpu_runs = 0;
static long long           g_fpga_start_us = 0;
static long long           g_trace_blocks  = 0;
static long long           g_trace_outputs = 0;
static int                 g_vpu_max_rows  = VPU_DEFAULT_ROWS;
static int                 g_vpu_max_beats = VPU_DEFAULT_BEATS;
static int                 g_vpu_max_cols  = VPU_DEFAULT_COLS;
static int                 g_address_map_logged = 0;
static int                 g_use_write64   = 1;
static int                 g_cfg_rows      = -1;
static int                 g_cfg_cols      = -1;
static int                 g_cfg_col_beats = -1;
static int                 g_cfg_mode      = -1;
static int                 g_cfg_scale     = -1;
static int                 g_offload_min_n = FPGA_DEFAULT_MIN_N;
static int                 g_offload_max_n = FPGA_DEFAULT_MAX_N;
static int                 g_offload_decode_max_n = FPGA_DEFAULT_DECODE_MAX_N;
static int                 g_packed_q8_supported = 0;
static int                 g_packed_q8_max_blocks = 1;
static int                 g_packed_q8_result_words = VPU_DEFAULT_ROWS;

static int g_current_layer_id = 0;
int        g_current_seq_pos  = 0;
static int g_is_attention_op  = 0;

typedef struct {
    std::vector<block_q8_0_t> act_blocks;
    std::vector<block_q8_0_t> act_blocks_all;
    std::vector<float>        act_scales;
    std::vector<float>        weight_scales;
    std::vector<int32_t>      partial;
    std::vector<float>        accum;
} fpga_scratch_t;

static fpga_scratch_t g_scratch;

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
    return env_flag_enabled("FPGA_TRACE_DATA") && trace_call_limit() > 0;
}

static int infer_layer_id_from_name(const char * name, int fallback) {
    if (!name || name[0] == '\0') {
        return fallback;
    }

    int layer = -1;
    if (sscanf(name, "blk.%d.", &layer) == 1 ||
        sscanf(name, "layers.%d.", &layer) == 1 ||
        sscanf(name, "model.layers.%d.", &layer) == 1) {
        return layer;
    }

    return fallback;
}

static const char * tensor_name_or_unknown(const struct ggml_tensor * tensor) {
    return (tensor && tensor->name[0] != '\0') ? tensor->name : "?";
}

static long long now_us(void) {
    struct timeval tv;
    gettimeofday(&tv, nullptr);
    return (long long) tv.tv_sec * 1000000LL + (long long) tv.tv_usec;
}

static void invalidate_vpu_config(void) {
    g_cfg_rows = -1;
    g_cfg_cols = -1;
    g_cfg_col_beats = -1;
    g_cfg_mode = -1;
    g_cfg_scale = -1;
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
    LOGI("register map: CTRL=0x%llx STATUS=0x%llx ROWS=0x%llx COLS=0x%llx COL_BEATS=0x%llx SCALE=0x%llx MODE=0x%llx LIMITS=0x%llx PROGRESS=0x%llx CAPS=0x%llx",
         (unsigned long long) local_to_phys(REG_CTRL),
         (unsigned long long) local_to_phys(REG_STATUS),
         (unsigned long long) local_to_phys(REG_ROWS),
         (unsigned long long) local_to_phys(REG_COLS),
         (unsigned long long) local_to_phys(REG_COL_BEATS),
         (unsigned long long) local_to_phys(REG_SCALE),
         (unsigned long long) local_to_phys(REG_MODE),
         (unsigned long long) local_to_phys(REG_LIMITS),
         (unsigned long long) local_to_phys(REG_PROGRESS),
         (unsigned long long) local_to_phys(REG_CAPS));
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
    uint32_t value;
    memcpy(&value, p, sizeof(value));
    return value;
}

static inline uint64_t pack_u8x8(const int8_t * p) {
    uint64_t value;
    memcpy(&value, p, sizeof(value));
    return value;
}

static inline void mmio_fence(void) {
    __sync_synchronize();
}

static inline uint32_t rd32(uint32_t off) {
    return *(volatile uint32_t *) (g_vpu + off);
}

static inline uint64_t rd64(uint32_t off) {
    return *(volatile uint64_t *) (g_vpu + off);
}

static inline void wr32(uint32_t off, uint32_t val) {
    *(volatile uint32_t *) (g_vpu + off) = val;
    LOGR("wr32 off=0x%08x val=0x%08x", off, val);
}

static inline void wr64(uint32_t off, uint64_t val) {
    *(volatile uint64_t *) (g_vpu + off) = val;
    LOGR("wr64 off=0x%08x val=0x%llx", off, (unsigned long long) val);
}

static inline void write_i8x16(uint32_t off, const int8_t * lanes) {
    if (g_use_write64) {
        wr64(off + 0, pack_u8x8(lanes + 0));
        wr64(off + 8, pack_u8x8(lanes + 8));
    } else {
        wr32(off + 0,  pack_u8x4(lanes + 0));
        wr32(off + 4,  pack_u8x4(lanes + 4));
        wr32(off + 8,  pack_u8x4(lanes + 8));
        wr32(off + 12, pack_u8x4(lanes + 12));
    }
}

static void configure_vpu(int rows, int col_beats, uint32_t mode) {
    const int cols = col_beats * VPU_NUM_LANES;
    if (g_cfg_rows != rows) {
        wr32(REG_ROWS, (uint32_t) rows);
        g_cfg_rows = rows;
    }
    if (g_cfg_cols != cols) {
        wr32(REG_COLS, (uint32_t) cols);
        g_cfg_cols = cols;
    }
    if (g_cfg_col_beats != col_beats) {
        wr32(REG_COL_BEATS, (uint32_t) col_beats);
        g_cfg_col_beats = col_beats;
    }
    if (g_cfg_scale != (int) VPU_FP16_ONE) {
        wr32(REG_SCALE, VPU_FP16_ONE);
        g_cfg_scale = (int) VPU_FP16_ONE;
    }
    if (g_cfg_mode != (int) mode) {
        wr32(REG_MODE, mode);
        g_cfg_mode = (int) mode;
    }
}

static void configure_vpu_for_q8_block(int rows) {
    configure_vpu(rows, VPU_BLOCK_BEATS, 0);
}

static void start_vpu(void) {
    mmio_fence();
    wr32(REG_CTRL, CTRL_START);
    mmio_fence();
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

static void quantize_activation_vector_to(
        const struct ggml_tensor * src1,
        int64_t m,
        int64_t k,
        block_q8_0_t * out) {
    const int64_t nb = k / VPU_QK8_0;
    const char * base = (const char *) src1->data + m * src1->nb[1];
    for (int64_t ib = 0; ib < nb; ++ib) {
        const float * block_base = (const float *) (base + ib * VPU_QK8_0 * src1->nb[0]);
        quantize_q8_0_block(block_base, src1->nb[0], &out[(size_t) ib]);
    }
}

static void quantize_activation_vector(
        const struct ggml_tensor * src1,
        int64_t m,
        int64_t k,
        std::vector<block_q8_0_t> & act_blocks) {
    const int64_t nb = k / VPU_QK8_0;
    act_blocks.resize((size_t) nb);
    quantize_activation_vector_to(src1, m, k, act_blocks.data());
}

static void quantize_activation_matrix(
        const struct ggml_tensor * src1,
        int64_t m,
        int64_t k,
        std::vector<block_q8_0_t> & act_blocks_all,
        std::vector<float> & act_scales) {
    const int64_t nb = k / VPU_QK8_0;
    act_blocks_all.resize((size_t) (m * nb));
    act_scales.resize((size_t) (m * nb));

    for (int64_t col = 0; col < m; ++col) {
        block_q8_0_t * col_blocks = &act_blocks_all[(size_t) (col * nb)];
        quantize_activation_vector_to(src1, col, k, col_blocks);
        for (int64_t ib = 0; ib < nb; ++ib) {
            act_scales[(size_t) (col * nb + ib)] = fp16_to_fp32(col_blocks[(size_t) ib].d);
        }
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
    if (n < g_offload_min_n) {
        *reason = "N below FPGA offload policy";
        return false;
    }
    if (g_offload_max_n > 0 && n > g_offload_max_n) {
        *reason = "N above FPGA offload policy";
        return false;
    }
    if (m == 1 && g_offload_decode_max_n > 0 && n > g_offload_decode_max_n) {
        *reason = "N above decode offload policy";
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

static long long estimate_vpu_runs(const struct ggml_tensor * src0, const struct ggml_tensor * src1) {
    const int64_t k = src0->ne[0];
    const int64_t n = src0->ne[1];
    const int64_t m = src1->ne[1];
    const int64_t nb = k / VPU_QK8_0;
    const int64_t row_chunks = (n + g_vpu_max_rows - 1) / g_vpu_max_rows;
    if (!g_packed_q8_supported) {
        return (long long) (m * row_chunks * nb);
    }

    long long runs = 0;
    for (int64_t row0 = 0; row0 < n; row0 += g_vpu_max_rows) {
        const int rows = (int) std::min<int64_t>(g_vpu_max_rows, n - row0);
        const int result_limited_blocks =
            std::max(1, (g_packed_q8_result_words * VPU_RESULT_PACK_LANES) / std::max(1, rows));
        const int max_group_blocks = std::max(1, std::min(g_packed_q8_max_blocks, result_limited_blocks));
        runs += (nb + max_group_blocks - 1) / max_group_blocks;
    }
    return (long long) m * runs;
}

static int packed_q8_group_blocks_for_rows(int rows, int remaining_blocks) {
    if (!g_packed_q8_supported) {
        return 1;
    }
    const int beat_limited_blocks = std::max(1, g_vpu_max_beats / VPU_BLOCK_BEATS);
    const int result_limited_blocks =
        std::max(1, (g_packed_q8_result_words * VPU_RESULT_PACK_LANES) / std::max(1, rows));
    int blocks = std::min(g_packed_q8_max_blocks, beat_limited_blocks);
    blocks = std::min(blocks, result_limited_blocks);
    blocks = std::min(blocks, remaining_blocks);
    return std::max(1, blocks);
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
    configure_vpu_for_q8_block(1);

    for (int beat = 0; beat < VPU_BLOCK_BEATS; ++beat) {
        write_i8x16(ACT_BASE + (uint32_t) beat * 16U, ones + beat * VPU_NUM_LANES);
        write_i8x16(WEIGHT_BASE + (uint32_t) beat * 16U, ones + beat * VPU_NUM_LANES);
    }

    start_vpu();

    uint32_t status = 0;
    const int wait_rc = wait_done(&status);
    const int32_t result = (wait_rc == 0) ? (int32_t) rd32(RESULT_BASE) : 0;
    const uint32_t progress = rd32(REG_PROGRESS);

    LOGI("self-test 1x32 result=%d expected=32 wait_rc=%d status=0x%08x progress=0x%08x",
         result, wait_rc, status, progress);

    wr32(REG_CTRL, CTRL_CLEAR_DONE);
    return wait_rc == 0 && result == 32;
}

static bool fpga_program_weight_block(
        const struct ggml_tensor * src0,
        int64_t row0,
        int rows,
        int64_t k_block,
        float * weight_scales,
        bool trace_this,
        long long trace_id) {
    if (rows <= 0 || rows > g_vpu_max_rows) {
        LOGE("address guard rejected rows=%d max_rows=%d", rows, g_vpu_max_rows);
        return false;
    }

    const uint32_t weight_last_index =
        (uint32_t) (rows - 1) * (uint32_t) g_vpu_max_beats + (uint32_t) (VPU_BLOCK_BEATS - 1);
    const uint32_t weight_bytes_to_last =
        weight_last_index * 16U + 16U;

    if (!local_range_fits(WEIGHT_BASE, weight_bytes_to_last, WEIGHT_BASE, WEIGHT_END) ||
        !mmap_range_fits(WEIGHT_BASE, weight_bytes_to_last)) {
        LOGE("address guard rejected weight transfer: rows=%d row0=%lld k_block=%lld weight_bytes=0x%x",
             rows,
             (long long) row0,
             (long long) k_block,
             weight_bytes_to_last);
        return false;
    }

    for (int row = 0; row < rows; ++row) {
        const block_q8_0_t * wb = weight_block(src0, row0 + row, k_block);
        if (weight_scales) {
            weight_scales[(size_t) row] = fp16_to_fp32(wb->d);
        }
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

    return true;
}

static bool fpga_run_loaded_q8_block(
        const block_q8_0_t & act,
        int64_t row0,
        int rows,
        int64_t k_block,
        std::vector<int32_t> & partial,
        bool trace_this,
        long long trace_id) {
    if (rows <= 0 || rows > g_vpu_max_rows) {
        LOGE("address guard rejected run rows=%d max_rows=%d", rows, g_vpu_max_rows);
        return false;
    }

    partial.resize((size_t) rows);

    const uint32_t act_bytes = (uint32_t) VPU_BLOCK_BEATS * 16U;
    const uint32_t result_bytes = (uint32_t) rows * 16U;

    if (!local_range_fits(ACT_BASE, act_bytes, ACT_BASE, ACT_END) ||
        !local_range_fits(RESULT_BASE, result_bytes, RESULT_BASE, RESULT_END) ||
        !mmap_range_fits(ACT_BASE, act_bytes) ||
        !mmap_range_fits(RESULT_BASE, result_bytes)) {
        LOGE("address guard rejected run transfer: rows=%d row0=%lld k_block=%lld act_bytes=0x%x result_bytes=0x%x",
             rows,
             (long long) row0,
             (long long) k_block,
             act_bytes,
             result_bytes);
        return false;
    }

    wr32(REG_CTRL, CTRL_CLEAR_DONE);
    configure_vpu_for_q8_block(rows);

    for (int beat = 0; beat < VPU_BLOCK_BEATS; ++beat) {
        const uint32_t act_off = ACT_BASE + (uint32_t) beat * 16U;
        const int8_t * lanes = act.qs + beat * VPU_NUM_LANES;
        write_i8x16(act_off, lanes);
        if (trace_this) {
            log_i8x16_lanes("ACT_WRITE", trace_id, act_off, 0, beat, lanes);
        }
    }

    start_vpu();

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

static bool fpga_run_q8_block(
        const block_q8_0_t & act,
        const struct ggml_tensor * src0,
        int64_t row0,
        int rows,
        int64_t k_block,
        std::vector<int32_t> & partial,
        std::vector<float> & weight_scales) {
    const bool trace_this = trace_data_enabled() && g_trace_blocks < trace_call_limit();
    const long long trace_id = trace_this ? g_trace_blocks++ : -1;

    if (trace_this) {
        const uint32_t result_bytes = (uint32_t) rows * 16U;
        const uint32_t weight_last_index =
            (uint32_t) (rows - 1) * (uint32_t) g_vpu_max_beats + (uint32_t) (VPU_BLOCK_BEATS - 1);
        const uint32_t weight_bytes_to_last =
            weight_last_index * 16U + 16U;
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

    weight_scales.resize((size_t) rows);

    return fpga_program_weight_block(src0, row0, rows, k_block, weight_scales.data(), trace_this, trace_id) &&
           fpga_run_loaded_q8_block(act, row0, rows, k_block, partial, trace_this, trace_id);
}

static bool fpga_program_weight_group(
        const struct ggml_tensor * src0,
        int64_t row0,
        int rows,
        int64_t k_block0,
        int group_blocks,
        std::vector<float> & weight_scales) {
    if (rows <= 0 || rows > g_vpu_max_rows || group_blocks <= 0) {
        LOGE("group weight guard rejected rows=%d max_rows=%d group_blocks=%d",
             rows, g_vpu_max_rows, group_blocks);
        return false;
    }

    const int group_beats = group_blocks * VPU_BLOCK_BEATS;
    if (group_beats > g_vpu_max_beats) {
        LOGE("group weight guard rejected group_beats=%d max_beats=%d", group_beats, g_vpu_max_beats);
        return false;
    }

    const uint32_t weight_last_index =
        (uint32_t) (rows - 1) * (uint32_t) g_vpu_max_beats + (uint32_t) (group_beats - 1);
    const uint32_t weight_bytes_to_last = weight_last_index * 16U + 16U;

    if (!local_range_fits(WEIGHT_BASE, weight_bytes_to_last, WEIGHT_BASE, WEIGHT_END) ||
        !mmap_range_fits(WEIGHT_BASE, weight_bytes_to_last)) {
        LOGE("group weight guard rejected transfer: rows=%d row0=%lld k_block0=%lld group_blocks=%d weight_bytes=0x%x",
             rows,
             (long long) row0,
             (long long) k_block0,
             group_blocks,
             weight_bytes_to_last);
        return false;
    }

    weight_scales.resize((size_t) rows * (size_t) group_blocks);

    for (int row = 0; row < rows; ++row) {
        for (int gb = 0; gb < group_blocks; ++gb) {
            const block_q8_0_t * wb = weight_block(src0, row0 + row, k_block0 + gb);
            weight_scales[(size_t) row * (size_t) group_blocks + (size_t) gb] =
                fp16_to_fp32(wb->d);
            for (int beat = 0; beat < VPU_BLOCK_BEATS; ++beat) {
                const int group_beat = gb * VPU_BLOCK_BEATS + beat;
                const uint32_t index = (uint32_t) row * (uint32_t) g_vpu_max_beats + (uint32_t) group_beat;
                const uint32_t weight_off = WEIGHT_BASE + index * 16U;
                const int8_t * lanes = wb->qs + beat * VPU_NUM_LANES;
                write_i8x16(weight_off, lanes);
            }
        }
    }

    return true;
}

static void read_result_i32x4(uint32_t result_word, int32_t out[4]) {
    const uint32_t off = RESULT_BASE + result_word * 16U;
    if (g_use_write64) {
        const uint64_t lo = rd64(off + 0U);
        const uint64_t hi = rd64(off + 8U);
        out[0] = (int32_t) (uint32_t) (lo & 0xffffffffULL);
        out[1] = (int32_t) (uint32_t) (lo >> 32);
        out[2] = (int32_t) (uint32_t) (hi & 0xffffffffULL);
        out[3] = (int32_t) (uint32_t) (hi >> 32);
    } else {
        out[0] = (int32_t) rd32(off + 0U);
        out[1] = (int32_t) rd32(off + 4U);
        out[2] = (int32_t) rd32(off + 8U);
        out[3] = (int32_t) rd32(off + 12U);
    }
}

static bool fpga_run_loaded_q8_group(
        const block_q8_0_t * act_blocks,
        int64_t row0,
        int rows,
        int64_t k_block0,
        int group_blocks,
        std::vector<int32_t> & partial) {
    if (rows <= 0 || rows > g_vpu_max_rows || group_blocks <= 0) {
        LOGE("group run guard rejected rows=%d max_rows=%d group_blocks=%d",
             rows, g_vpu_max_rows, group_blocks);
        return false;
    }

    const int group_beats = group_blocks * VPU_BLOCK_BEATS;
    const uint32_t act_bytes = (uint32_t) group_beats * 16U;
    const uint32_t result_values = (uint32_t) rows * (uint32_t) group_blocks;
    const uint32_t result_words = (result_values + (uint32_t) VPU_RESULT_PACK_LANES - 1U) /
                                  (uint32_t) VPU_RESULT_PACK_LANES;
    const uint32_t result_bytes = result_words * 16U;

    if (group_beats > g_vpu_max_beats ||
        result_words > (uint32_t) g_packed_q8_result_words ||
        !local_range_fits(ACT_BASE, act_bytes, ACT_BASE, ACT_END) ||
        !local_range_fits(RESULT_BASE, result_bytes, RESULT_BASE, RESULT_END) ||
        !mmap_range_fits(ACT_BASE, act_bytes) ||
        !mmap_range_fits(RESULT_BASE, result_bytes)) {
        LOGE("group run guard rejected transfer: rows=%d row0=%lld k_block0=%lld group_blocks=%d act_bytes=0x%x result_bytes=0x%x result_words=%u cap_words=%d",
             rows,
             (long long) row0,
             (long long) k_block0,
             group_blocks,
             act_bytes,
             result_bytes,
             result_words,
             g_packed_q8_result_words);
        return false;
    }

    partial.resize((size_t) result_values);

    wr32(REG_CTRL, CTRL_CLEAR_DONE);
    configure_vpu(rows, group_beats, VPU_MODE_PACKED_Q8);

    for (int gb = 0; gb < group_blocks; ++gb) {
        const block_q8_0_t & act = act_blocks[gb];
        for (int beat = 0; beat < VPU_BLOCK_BEATS; ++beat) {
            const int group_beat = gb * VPU_BLOCK_BEATS + beat;
            const uint32_t act_off = ACT_BASE + (uint32_t) group_beat * 16U;
            const int8_t * lanes = act.qs + beat * VPU_NUM_LANES;
            write_i8x16(act_off, lanes);
        }
    }

    start_vpu();

    uint32_t status = 0;
    const int wait_rc = wait_done(&status);
    if (wait_rc != 0) {
        const uint32_t progress = rd32(REG_PROGRESS);
        LOGE("VPU group failed wait_rc=%d status=0x%08x progress=0x%08x row0=%lld rows=%d k_block0=%lld group_blocks=%d",
             wait_rc,
             status,
             progress,
             (long long) row0,
             rows,
             (long long) k_block0,
             group_blocks);
        return false;
    }

    for (uint32_t word = 0; word < result_words; ++word) {
        int32_t lanes[4];
        read_result_i32x4(word, lanes);
        for (int lane = 0; lane < VPU_RESULT_PACK_LANES; ++lane) {
            const uint32_t value_index = word * (uint32_t) VPU_RESULT_PACK_LANES + (uint32_t) lane;
            if (value_index < result_values) {
                partial[(size_t) value_index] = lanes[lane];
            }
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

static bool fpga_hw_q8_0_matmul_batched(
        const struct ggml_tensor * src0,
        const struct ggml_tensor * src1,
        const struct ggml_tensor * dst) {
    const int64_t k = src0->ne[0];
    const int64_t n = src0->ne[1];
    const int64_t m = src1->ne[1];
    const int64_t nb = k / VPU_QK8_0;

    std::vector<block_q8_0_t> & act_blocks_all = g_scratch.act_blocks_all;
    std::vector<float> & act_scales = g_scratch.act_scales;
    std::vector<float> & weight_scales = g_scratch.weight_scales;
    std::vector<int32_t> & partial = g_scratch.partial;
    std::vector<float> & accum = g_scratch.accum;

    quantize_activation_matrix(src1, m, k, act_blocks_all, act_scales);

    for (int64_t row0 = 0; row0 < n; row0 += g_vpu_max_rows) {
        const int rows = (int) std::min<int64_t>(g_vpu_max_rows, n - row0);
        accum.assign((size_t) (m * rows), 0.0f);

        for (int64_t ib = 0; ib < nb; ++ib) {
            weight_scales.resize((size_t) rows);
            if (!fpga_program_weight_block(src0, row0, rows, ib, weight_scales.data(), false, -1)) {
                return false;
            }

            for (int64_t col = 0; col < m; ++col) {
                const block_q8_0_t & act = act_blocks_all[(size_t) (col * nb + ib)];
                if (!fpga_run_loaded_q8_block(act, row0, rows, ib, partial, false, -1)) {
                    return false;
                }

                const float act_scale = act_scales[(size_t) (col * nb + ib)];
                float * accum_col = &accum[(size_t) (col * rows)];
                for (int row = 0; row < rows; ++row) {
                    accum_col[(size_t) row] +=
                        (float) partial[(size_t) row] * act_scale * weight_scales[(size_t) row];
                }
            }
        }

        for (int64_t col = 0; col < m; ++col) {
            const float * accum_col = &accum[(size_t) (col * rows)];
            for (int row = 0; row < rows; ++row) {
                store_dst_value(dst, row0 + row, col, accum_col[(size_t) row]);
            }
        }
    }

    return true;
}

static bool fpga_hw_q8_0_matmul_grouped(
        const struct ggml_tensor * src0,
        const struct ggml_tensor * src1,
        const struct ggml_tensor * dst) {
    const int64_t k = src0->ne[0];
    const int64_t n = src0->ne[1];
    const int64_t m = src1->ne[1];
    const int64_t nb = k / VPU_QK8_0;

    std::vector<block_q8_0_t> & act_blocks_all = g_scratch.act_blocks_all;
    std::vector<float> & act_scales = g_scratch.act_scales;
    std::vector<float> & weight_scales = g_scratch.weight_scales;
    std::vector<int32_t> & partial = g_scratch.partial;
    std::vector<float> & accum = g_scratch.accum;

    quantize_activation_matrix(src1, m, k, act_blocks_all, act_scales);

    for (int64_t row0 = 0; row0 < n; row0 += g_vpu_max_rows) {
        const int rows = (int) std::min<int64_t>(g_vpu_max_rows, n - row0);
        accum.assign((size_t) (m * rows), 0.0f);

        for (int64_t ib0 = 0; ib0 < nb;) {
            const int remaining_blocks = (int) (nb - ib0);
            const int group_blocks = packed_q8_group_blocks_for_rows(rows, remaining_blocks);

            if (!fpga_program_weight_group(src0, row0, rows, ib0, group_blocks, weight_scales)) {
                return false;
            }

            for (int64_t col = 0; col < m; ++col) {
                const block_q8_0_t * act_group =
                    &act_blocks_all[(size_t) (col * nb + ib0)];

                if (!fpga_run_loaded_q8_group(act_group, row0, rows, ib0, group_blocks, partial)) {
                    return false;
                }

                float * accum_col = &accum[(size_t) (col * rows)];
                for (int row = 0; row < rows; ++row) {
                    for (int gb = 0; gb < group_blocks; ++gb) {
                        const int64_t ib = ib0 + gb;
                        const int32_t raw = partial[(size_t) row * (size_t) group_blocks + (size_t) gb];
                        accum_col[(size_t) row] +=
                            (float) raw *
                            act_scales[(size_t) (col * nb + ib)] *
                            weight_scales[(size_t) row * (size_t) group_blocks + (size_t) gb];
                    }
                }
            }

            ib0 += group_blocks;
        }

        for (int64_t col = 0; col < m; ++col) {
            const float * accum_col = &accum[(size_t) (col * rows)];
            for (int row = 0; row < rows; ++row) {
                store_dst_value(dst, row0 + row, col, accum_col[(size_t) row]);
            }
        }
    }

    return true;
}

static bool fpga_hw_q8_0_matmul(
        const struct ggml_tensor * src0,
        const struct ggml_tensor * src1,
        const struct ggml_tensor * dst) {
    const int64_t k = src0->ne[0];
    const int64_t n = src0->ne[1];
    const int64_t m = src1->ne[1];
    const int64_t nb = k / VPU_QK8_0;

    if (g_packed_q8_supported) {
        return fpga_hw_q8_0_matmul_grouped(src0, src1, dst);
    }

    if (m > 1) {
        return fpga_hw_q8_0_matmul_batched(src0, src1, dst);
    }

    std::vector<block_q8_0_t> & act_blocks = g_scratch.act_blocks;
    std::vector<float> & act_scales = g_scratch.act_scales;
    std::vector<float> & weight_scales = g_scratch.weight_scales;
    std::vector<int32_t> & partial = g_scratch.partial;
    std::vector<float> & accum = g_scratch.accum;

    for (int64_t col = 0; col < m; ++col) {
        quantize_activation_vector(src1, col, k, act_blocks);
        act_scales.resize((size_t) nb);
        for (int64_t ib = 0; ib < nb; ++ib) {
            act_scales[(size_t) ib] = fp16_to_fp32(act_blocks[(size_t) ib].d);
        }

        for (int64_t row0 = 0; row0 < n; row0 += g_vpu_max_rows) {
            const int rows = (int) std::min<int64_t>(g_vpu_max_rows, n - row0);
            accum.assign((size_t) rows, 0.0f);

            for (int64_t ib = 0; ib < nb; ++ib) {
                if (!fpga_run_q8_block(act_blocks[(size_t) ib], src0, row0, rows, ib, partial, weight_scales)) {
                    return false;
                }

                const float act_scale = act_scales[(size_t) ib];
                for (int row = 0; row < rows; ++row) {
                    accum[(size_t) row] +=
                        (float) partial[(size_t) row] * act_scale * weight_scales[(size_t) row];
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
    g_use_write64 = !env_flag_disabled("FPGA_WRITE64");
    g_offload_min_n = env_int_value("FPGA_MIN_N", FPGA_DEFAULT_MIN_N, 0, 1073741824);
    g_offload_max_n = env_int_value("FPGA_MAX_N", FPGA_DEFAULT_MAX_N, 0, 1073741824);
    g_offload_decode_max_n = env_int_value("FPGA_DECODE_MAX_N", FPGA_DEFAULT_DECODE_MAX_N, 0, 1073741824);
    invalidate_vpu_config();
    g_fpga_start_us = now_us();

    uint32_t limits = 0;
    limits = rd32(REG_LIMITS);
    const uint32_t caps = rd32(REG_CAPS);
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

    g_packed_q8_supported = 0;
    g_packed_q8_max_blocks = 1;
    g_packed_q8_result_words = VPU_DEFAULT_ROWS;
    if ((caps != 0U) && (caps != 0xFFFFFFFFU) && ((caps & 0x1U) != 0U) &&
        !env_flag_disabled("FPGA_PACKED_Q8")) {
        const int cap_blocks = (int) ((caps >> 8) & 0xFFU);
        const int cap_result_words = (int) ((caps >> 16) & 0xFFFFU);
        if (cap_blocks > 0 && cap_result_words > 0) {
            g_packed_q8_supported = 1;
            g_packed_q8_max_blocks = std::min(cap_blocks, g_vpu_max_beats / VPU_BLOCK_BEATS);
            g_packed_q8_result_words = cap_result_words;
        }
    }
    if (!getenv("FPGA_DECODE_MAX_N") && g_packed_q8_supported) {
        g_offload_decode_max_n = 0;
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
    LOGI("VPU caps: raw_caps=0x%08x packed_q8=%d max_group_blocks=%d result_words=%d (set FPGA_PACKED_Q8=0 to force legacy mode)",
         caps,
         g_packed_q8_supported,
         g_packed_q8_max_blocks,
         g_packed_q8_result_words);
    LOGI("No ZDMA programming is used: current bitstream exposes an AXI4-Full slave with local BRAM windows");
    LOGI("MMIO data write mode: %s (set FPGA_WRITE64=0 to force 32-bit writes)",
         g_use_write64 ? "64-bit" : "32-bit");
    LOGI("offload policy: min_N=%d max_N=%d decode_max_N=%d (auto 0 when packed_q8 is available; set FPGA_DECODE_MAX_N explicitly to override)",
         g_offload_min_n, g_offload_max_n, g_offload_decode_max_n);
    LOGI("trace controls: set FPGA_TRACE_DATA=1 to dump first data blocks; FPGA_TRACE_CALLS=N changes default first %d traced blocks",
         TRACE_DEFAULT_CALLS);
    log_address_map_once();

    if (limits == 0U || limits == 0xFFFFFFFFU) {
        LOGE("REG_LIMITS read is suspicious (0x%08x); check bitstream load, AXI base address, and PS-PL interconnect",
             limits);
    }

    const bool require_self_test = env_flag_enabled("FPGA_SELF_TEST");
    bool self_test_ok = true;
    if (g_use_write64 || require_self_test) {
        self_test_ok = fpga_smoke_test();
        if (!self_test_ok && g_use_write64) {
            LOGE("64-bit MMIO self-test failed; retrying with 32-bit data writes");
            g_use_write64 = 0;
            invalidate_vpu_config();
            self_test_ok = fpga_smoke_test();
            if (self_test_ok) {
                LOGI("MMIO data write mode changed to 32-bit after self-test fallback");
            }
        }
        if (!self_test_ok && require_self_test) {
            LOGE("FPGA_SELF_TEST failed; refusing to enable FPGA acceleration for this process");
            munmap(mapped_vpu_ptr(), VPU_MMAP_SIZE);
            g_vpu = nullptr;
            close(g_mem_fd);
            g_mem_fd = -1;
            return -1;
        }
        if (!self_test_ok) {
            LOGE("FPGA self-test failed; continuing because FPGA_SELF_TEST is not set");
        }
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

    const long long elapsed_us = g_fpga_start_us > 0 ? now_us() - g_fpga_start_us : 0;
    const double elapsed_s = elapsed_us > 0 ? (double) elapsed_us / 1000000.0 : 0.0;
    const double run_rate = elapsed_s > 0.0 ? (double) g_fpga_vpu_runs / elapsed_s : 0.0;
    LOGI("cleanup complete fpga_calls=%lld vpu_runs=%lld software_fallbacks=%lld elapsed_s=%.3f avg_vpu_runs_per_s=%.1f",
         g_fpga_count, g_fpga_vpu_runs, g_cpu_count, elapsed_s, run_rate);
    invalidate_vpu_config();
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
    const int effective_layer_id = infer_layer_id_from_name(tensor_name_or_unknown(src0), layer_id);

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
            LOGI("reject matmul: %s tensor=%s K=%lld N=%lld M=%lld layer=%d",
                 reason ? reason : "unknown",
                 tensor_name_or_unknown(src0),
                 src0 ? (long long) src0->ne[0] : 0LL,
                 src0 ? (long long) src0->ne[1] : 0LL,
                 src1 ? (long long) src1->ne[1] : 0LL,
                 effective_layer_id);
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

    const long long vpu_runs = estimate_vpu_runs(src0, src1);
    const long long t0_us = now_us();

    LOGM("run layer=%d seq=%d tensor=%s K=%lld N=%lld M=%lld rows_limit=%d beats_limit=%d packed_q8=%d vpu_runs=%lld",
         effective_layer_id,
         seq_pos,
         tensor_name_or_unknown(src0),
         (long long) src0->ne[0],
         (long long) src0->ne[1],
         (long long) src1->ne[1],
         g_vpu_max_rows,
         g_vpu_max_beats,
         g_packed_q8_supported,
         vpu_runs);

    const bool hw_ok = fpga_hw_q8_0_matmul(src0, src1, dst);
    const long long t1_us = now_us();
    const double elapsed_ms = (double) (t1_us - t0_us) / 1000.0;
    const double run_rate = elapsed_ms > 0.0 ? ((double) vpu_runs * 1000.0) / elapsed_ms : 0.0;
    if (hw_ok) {
        g_fpga_count++;
        g_fpga_vpu_runs += vpu_runs;
        LOGM("done via FPGA total_fpga_calls=%lld vpu_runs=%lld elapsed_ms=%.3f vpu_runs_per_s=%.1f total_vpu_runs=%lld",
             g_fpga_count,
             vpu_runs,
             elapsed_ms,
             run_rate,
             g_fpga_vpu_runs);
        log_dst_sample(dst, effective_layer_id, seq_pos);
    } else {
        g_cpu_count++;
        LOGE("FPGA runtime failed after %.3f ms; computing this accepted matmul with local q8_0 software fallback",
             elapsed_ms);
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
