# Review high-fanout weight RAM - 2026-06-15

## Pham vi

- RTL duoc sua: `RTL/Matrix_Vector_Multiplication.v`.
- Khong thay doi top-level interface, AXI/MMIO register map, hay format packed Q8.
- Cac project Vivado chinh khong bi sua; script, log, report va checkpoint chi nam trong `DATN_VIVADO/manual_sim`.

## Nguyen nhan

Voi `MAX_ROWS=256` va `MAX_COL_BEATS=256`, moi weight bank 32-bit co do sau 65536 word va duoc Vivado anh xa thanh 64 RAMB36. Cac register address cu dieu khien truc tiep toan bo RAM vat ly cua bank:

- `weight_wr_addr_bank_reg[*]` -> `ADDRBWRADDR`, fanout 64.
- `weight_compute_addr_bank_reg[*]` -> `ADDRARDADDR`, fanout 64-65.

Report board ban dau co cac path 0 logic level, nhung route delay khoang 4.43-4.59 ns. Vi vay nguyen nhan chinh la khoang cach dat RAM va high fanout, khong phai logic to hop.

## Thay doi RTL

1. Chia moi weight bank thanh cac depth shard toi da 16K word. Cau hinh 256 beat tao 4 shard cho moi bank, tong 16 leaf RAM.
2. Dang ky rieng address, enable, write data va byte strobe tai tung leaf.
3. Them write pipeline hai tang: AXI/MMIO -> `wr_pipe_*` -> leaf register -> RAM. Throughput van mot beat moi clock.
4. Them read request-seed stage truoc leaf address. Activation address, weight local address, shard select, `valid`, `last` va `group_last` duoc delay dong bo.
5. Shard select tiep tuc di cung pipeline `d/q/x` de mux dung output RAM.
6. Khong dung `dont_touch`; replication duoc mo ta ro trong RTL thay vi phu thuoc register duplication tu dong.

## Timing sau route OOC 200 MHz

- Clock period: 5.000 ns.
- WNS: +0.254 ns.
- TNS: 0.000 ns.
- WHS: +0.020 ns.
- Weight address leaf fanout toi da: 2.
- Worst read-address leaf -> RAM: data path 3.954 ns, route 3.876 ns, slack +0.744 ns.
- Worst write-address leaf -> RAM: data path 3.832 ns, route 3.753 ns, slack +0.855 ns.
- Tai nguyen: 264 BRAM tiles, 18 DSP; khong tang BRAM/DSP so voi cau truc 65536x32 cu.

So voi report board ban dau, net delay truc tiep toi cac cong `RBWRADDR`, `DRBRWADDR`, `RARDDADDR`, `DRARDDADDR` giam khoang 0.65-0.78 ns va fanout 64-65 duoc loai bo. Critical path toan thiet ke hien tai da chuyen sang duong AXI write-enable -> `wr_pipe_*`, khong con la RAM address port.

Read seed stage them mot chu ky fill cho moi row, nhung khong lam giam throughput beat lien tiep trong mot row. Trong test 129 row, compute+poll tang tu 2336 len 2463 chu ky, tuong duong 0.635 us tai 200 MHz.

## Simulation

- `current_256_packed_xsim.log`: packed Q8 PASS va shard-boundary PASS tai row 63/64/65, ket qua `[16,32,-32]`.
- `packed_q8_xsim.log`: packed Q8 PASS; GEMV `4x4`, `3x17`, `4x64` PASS.
- `vpu_top_xsim.log`: 149 PASS, 0 FAIL; AXI4-Full VPU TEST PASSED.
- `current_256_impl.log`: synth/place/route thanh cong, 0 error.

## Report tao ra

- `current_256_impl_timing_200mhz.rpt`
- `current_256_impl_weight_address_fanout.rpt`
- `current_256_impl_weight_address_paths.rpt`
- `current_256_impl_utilization.rpt`
- `current_256_impl_route.dcp`

Luu y: implementation nay la OOC cua `VPU_Top` voi `MAX_COL_BEATS=256`. Sau khi cap nhat/repackage IP trong block design, can chay lai full board implementation de xac nhan placement cung PS, interconnect va cac clock domain cua ZCU104.
