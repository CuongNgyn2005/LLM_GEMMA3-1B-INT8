from pathlib import Path

files = [Path('RTL/SPU_VPU_Stream8.v'), Path('DATN_VIVADO/project_2/src/SPU_VPU_Stream8.v')]
if files[0].read_bytes() != files[1].read_bytes():
    raise SystemExit('mirror mismatch before patch')

repls = [
('A two-entry input FIFO decouples', 'A four-entry input FIFO decouples'),
('The FIFO is intentionally shallow for the first\n * hardware experiment: it can absorb the next x8 bundle while the current\n * bundle is being consumed without changing the external stream ABI.', "Its depth matches the VPU raw burst scheduler's\n * maximum four-block issue burst while preserving the external stream ABI."),
('// Two-entry x8 bundle FIFO.', '// Four-entry x8 bundle FIFO.'),
('reg [1:0] fifo_count_r;', 'reg [2:0] fifo_count_r;'),
('reg fifo_wr_ptr_r;', 'reg [1:0] fifo_wr_ptr_r;'),
('reg fifo_rd_ptr_r;', 'reg [1:0] fifo_rd_ptr_r;'),
("wire fifo_empty = (fifo_count_r == 2'd0);", "wire fifo_empty = (fifo_count_r == 3'd0);"),
("wire fifo_full = (fifo_count_r == 2'd2);", "wire fifo_full = (fifo_count_r == 3'd4);"),
('// P2 uses the new two-entry FIFO.', '// P2 uses the four-entry FIFO.'),
("fifo_count_r <= 2'd0; fifo_wr_ptr_r <= 1'b0; fifo_rd_ptr_r <= 1'b0;", "fifo_count_r <= 3'd0; fifo_wr_ptr_r <= 2'd0; fifo_rd_ptr_r <= 2'd0;"),
('for (fi = 0; fi < 2; fi = fi + 1) begin', 'for (fi = 0; fi < 4; fi = fi + 1) begin'),
('fifo_wr_ptr_r <= ~fifo_wr_ptr_r;', "fifo_wr_ptr_r <= fifo_wr_ptr_r + 2'd1;"),
("2'b10: fifo_count_r <= fifo_count_r + 2'd1;", "2'b10: fifo_count_r <= fifo_count_r + 3'd1;"),
("2'b01: fifo_count_r <= fifo_count_r - 2'd1;", "2'b01: fifo_count_r <= fifo_count_r - 3'd1;"),
('fifo_rd_ptr_r <= ~fifo_rd_ptr_r;', "fifo_rd_ptr_r <= fifo_rd_ptr_r + 2'd1;"),
]

old_hwm = """                if (!fifo_pop && (fifo_count_r == 2'd1))
                    stream_fifo_high_water <= 32'd2;
                else if (stream_fifo_high_water == 32'd0)
                    stream_fifo_high_water <= 32'd1;
"""
new_hwm = """                if (!fifo_pop &&
                    (stream_fifo_high_water < {29'd0,(fifo_count_r + 3'd1)}))
                    stream_fifo_high_water <= {29'd0,(fifo_count_r + 3'd1)};
"""

for path in files:
    s = path.read_text()
    for old, new in repls:
        n = s.count(old)
        if n != 1:
            raise SystemExit(f'{path}: expected one match for {old!r}, got {n}')
        s = s.replace(old, new, 1)

    # Current Stream8 has exactly twelve FIFO memories with [0:1] depth.
    # Change all of those to [0:3] and fail if the declaration shape drifts.
    if s.count('[0:1];') != 12:
        raise SystemExit(f'{path}: expected twelve FIFO [0:1] declarations, got {s.count("[0:1];")}')
    s = s.replace('[0:1];', '[0:3];')

    if s.count(old_hwm) != 1:
        raise SystemExit(f'{path}: high-water block mismatch')
    s = s.replace(old_hwm, new_hwm, 1)
    path.write_text(s)
    print('patched', path)

if files[0].read_bytes() != files[1].read_bytes():
    raise SystemExit('mirror mismatch after patch')
