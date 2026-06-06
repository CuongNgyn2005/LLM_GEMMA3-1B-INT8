#include <cerrno>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <fcntl.h>
#include <sched.h>
#include <sys/mman.h>
#include <unistd.h>

static constexpr uint64_t VPU_BASE_PHYS   = 0x00000000A0000000ULL;
static constexpr size_t   VPU_MMAP_SIZE   = 0x00300000;

static constexpr uint32_t REG_CTRL        = 0x00000000;
static constexpr uint32_t REG_STATUS      = 0x00000010;
static constexpr uint32_t REG_ROWS        = 0x00000020;
static constexpr uint32_t REG_COLS        = 0x00000030;
static constexpr uint32_t REG_COL_BEATS   = 0x00000040;
static constexpr uint32_t REG_SCALE       = 0x00000050;
static constexpr uint32_t REG_MODE        = 0x00000060;
static constexpr uint32_t REG_LIMITS      = 0x00000070;
static constexpr uint32_t REG_PROGRESS    = 0x00000080;

static constexpr uint32_t CTRL_START      = 0x00000001;
static constexpr uint32_t CTRL_CLEAR_DONE = 0x00000002;
static constexpr uint32_t STATUS_DONE     = 0x00000001;
static constexpr uint32_t STATUS_BUSY     = 0x00000002;
static constexpr uint32_t STATUS_ERROR    = 0x00000004;

static constexpr uint32_t ACT_BASE        = 0x00010000;
static constexpr uint32_t WEIGHT_BASE     = 0x00100000;
static constexpr uint32_t RESULT_BASE     = 0x00200000;

static constexpr int      NUM_LANES       = 16;
static constexpr int      QK8_0           = 32;
static constexpr int      BLOCK_BEATS     = QK8_0 / NUM_LANES;
static constexpr uint32_t FP16_ONE        = 0x00003C00;
static constexpr int      POLL_LIMIT      = 1000000;

static volatile uint8_t * g_vpu = nullptr;

static void * mapped_vpu_ptr() {
    return const_cast<uint8_t *>(g_vpu);
}

static uint32_t pack_i8x4(const int8_t * p) {
    return ((uint32_t) (uint8_t) p[0]) |
           ((uint32_t) (uint8_t) p[1] << 8) |
           ((uint32_t) (uint8_t) p[2] << 16) |
           ((uint32_t) (uint8_t) p[3] << 24);
}

static uint32_t rd32(uint32_t off) {
    return *(volatile uint32_t *) (g_vpu + off);
}

static void wr32(uint32_t off, uint32_t val) {
    *(volatile uint32_t *) (g_vpu + off) = val;
    __sync_synchronize();
}

static void write_i8x16(uint32_t off, const int8_t * lanes) {
    wr32(off + 0,  pack_i8x4(lanes + 0));
    wr32(off + 4,  pack_i8x4(lanes + 4));
    wr32(off + 8,  pack_i8x4(lanes + 8));
    wr32(off + 12, pack_i8x4(lanes + 12));
}

static int wait_done(uint32_t * final_status) {
    for (int poll = 0; poll < POLL_LIMIT; ++poll) {
        const uint32_t status = rd32(REG_STATUS);
        *final_status = status;
        if (status & STATUS_ERROR) {
            return -1;
        }
        if (status & STATUS_DONE) {
            return 0;
        }
        if ((poll & 0x3ff) == 0) {
            sched_yield();
        }
    }
    return -2;
}

int main() {
    int fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (fd < 0) {
        std::fprintf(stderr, "open /dev/mem failed: errno=%d (%s)\n", errno, std::strerror(errno));
        return 1;
    }

    void * map = mmap(nullptr, VPU_MMAP_SIZE, PROT_READ | PROT_WRITE, MAP_SHARED, fd, VPU_BASE_PHYS);
    if (map == MAP_FAILED) {
        std::fprintf(stderr, "mmap 0x%llx size=0x%zx failed: errno=%d (%s)\n",
                     (unsigned long long) VPU_BASE_PHYS, VPU_MMAP_SIZE, errno, std::strerror(errno));
        close(fd);
        return 1;
    }
    g_vpu = (volatile uint8_t *) map;

    const uint32_t limits = rd32(REG_LIMITS);
    const uint32_t status0 = rd32(REG_STATUS);
    std::printf("VPU base=0x%llx mmap_size=0x%zx\n",
                (unsigned long long) VPU_BASE_PHYS, VPU_MMAP_SIZE);
    std::printf("REG_LIMITS=0x%08x rows=%u col_beats=%u initial_status=0x%08x\n",
                limits, limits & 0xffffU, (limits >> 16) & 0xffffU, status0);

    int8_t ones[QK8_0];
    for (int i = 0; i < QK8_0; ++i) {
        ones[i] = 1;
    }

    wr32(REG_CTRL, CTRL_CLEAR_DONE);
    wr32(REG_ROWS, 1);
    wr32(REG_COLS, QK8_0);
    wr32(REG_COL_BEATS, BLOCK_BEATS);
    wr32(REG_SCALE, FP16_ONE);
    wr32(REG_MODE, 0);

    for (int beat = 0; beat < BLOCK_BEATS; ++beat) {
        write_i8x16(ACT_BASE + (uint32_t) beat * 16U, ones + beat * NUM_LANES);
        write_i8x16(WEIGHT_BASE + (uint32_t) beat * 16U, ones + beat * NUM_LANES);
    }

    wr32(REG_CTRL, CTRL_START);

    uint32_t status = 0;
    const int wait_rc = wait_done(&status);
    const uint32_t progress = rd32(REG_PROGRESS);
    const int32_t result = (wait_rc == 0) ? (int32_t) rd32(RESULT_BASE) : 0;

    std::printf("wait_rc=%d status=0x%08x progress=0x%08x result=%d expected=32\n",
                wait_rc, status, progress, result);

    wr32(REG_CTRL, CTRL_CLEAR_DONE);

    munmap(mapped_vpu_ptr(), VPU_MMAP_SIZE);
    close(fd);

    if (wait_rc != 0 || result != 32) {
        std::fprintf(stderr, "FAILED: PS-PL MMIO path did not return the expected VPU result.\n");
        return 2;
    }

    std::printf("PASS: VPU register map and basic ACT/WEIGHT/RESULT path are reachable.\n");
    return 0;
}
