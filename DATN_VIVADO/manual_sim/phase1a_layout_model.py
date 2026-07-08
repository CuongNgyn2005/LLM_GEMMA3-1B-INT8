#!/usr/bin/env python3

from math import ceil

NUM_LANES = 16
QK8_0 = 32
BLOCK_BEATS = QK8_0 // NUM_LANES
RESULT_PACK_LANES = 4

MAX_ROWS = 256
MAX_COL_BEATS = 128
MAX_GROUP_Q8_BLOCKS = 64
RESULT_WORD_DEPTH = ceil((MAX_ROWS * MAX_GROUP_Q8_BLOCKS) / RESULT_PACK_LANES)

CAP_PACKED_Q8 = 1 << 0
CAP_COMPACT_WEIGHT_LAYOUT = 1 << 1


def compact_weight_index(row: int, beat: int, active_col_beats: int) -> int:
    return row * active_col_beats + beat


def legacy_weight_index(row: int, beat: int) -> int:
    return row * MAX_COL_BEATS + beat


def weight_span_bytes(rows: int, active_col_beats: int, compact: bool) -> int:
    if compact:
        return rows * active_col_beats * 16
    return ((rows - 1) * MAX_COL_BEATS + active_col_beats) * 16


def group_tiles_for_k(k: int) -> int:
    q8_blocks = k // QK8_0
    return ceil(q8_blocks / MAX_GROUP_Q8_BLOCKS)


def check(name: str, condition: bool) -> None:
    if not condition:
        raise AssertionError(name)
    print(f"[PASS] {name}")


def main() -> None:
    caps = (
        CAP_PACKED_Q8
        | CAP_COMPACT_WEIGHT_LAYOUT
        | (MAX_GROUP_Q8_BLOCKS << 8)
        | (RESULT_WORD_DEPTH << 16)
    )

    check("MAX_COL_BEATS is 128", MAX_COL_BEATS == 128)
    check("MAX_GROUP_Q8_BLOCKS is 64", MAX_GROUP_Q8_BLOCKS == 64)
    check("RESULT_WORD_DEPTH is 4096", RESULT_WORD_DEPTH == 4096)
    check("REG_CAPS packed bit is set", (caps & CAP_PACKED_Q8) != 0)
    check("REG_CAPS compact layout bit is set", (caps & CAP_COMPACT_WEIGHT_LAYOUT) != 0)
    check("REG_CAPS max group field is 64", ((caps >> 8) & 0xFF) == 64)
    check("REG_CAPS result depth field is 4096", ((caps >> 16) & 0xFFFF) == 4096)

    check("K=1024 maps to one group tile", group_tiles_for_k(1024) == 1)
    check("K=1152 maps to one group tile", group_tiles_for_k(1152) == 1)
    check("K=6912 maps to four group tiles", group_tiles_for_k(6912) == 4)

    active_col_beats = 4
    check(
        "compact row 1 base uses active stride",
        compact_weight_index(1, 0, active_col_beats) == active_col_beats,
    )
    check(
        "legacy row 1 base would be max stride",
        legacy_weight_index(1, 0) == MAX_COL_BEATS,
    )
    check(
        "compact and legacy addresses differ when active_col_beats < MAX_COL_BEATS",
        compact_weight_index(1, 0, active_col_beats) != legacy_weight_index(1, 0),
    )
    check(
        "compact weight span removes row padding",
        weight_span_bytes(3, active_col_beats, compact=True) == 3 * active_col_beats * 16,
    )
    check(
        "legacy weight span keeps row padding",
        weight_span_bytes(3, active_col_beats, compact=False)
        == ((3 - 1) * MAX_COL_BEATS + active_col_beats) * 16,
    )

    print("[PASS] Phase 1A layout model checks completed")


if __name__ == "__main__":
    main()
