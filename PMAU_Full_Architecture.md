# PMAU_Full Pipeline Architecture

## Pipeline Diagram

```mermaid
graph TD
    subgraph Input["🔷 INPUT (Clock 0)"]
        ACT["16×INT8<br/>activation_data"]
        WGT["16×INT8<br/>weight_data"]
        SCALE["16-bit<br/>scale_factor"]
    end

    subgraph Stage0["📥 Stage 0: Input Register"]
        REG_ACT["mult_act_reg[15:0]<br/>8-bit each"]
        REG_WGT["mult_weight_reg[15:0]<br/>8-bit each"]
        REG_SCALE["reg scale"]
    end

    subgraph Stage1["⏱️ Stage 1-2: Multiply (DSP Latency)"]
        DSP["16× mult_gen_0<br/>INT8×INT8 → 16-bit<br/>(2-cycle IP latency)"]
        MULT_CAPTURE["Capture mult_ip_product[15:0]"]
    end

    subgraph Stage3["🔢 Stage 3: Adder Tree Level 0"]
        ADD_L0_1["ADD: prod[0] + prod[1]<br/>→ 32-bit"]
        ADD_L0_2["ADD: prod[2] + prod[3]"]
        ADD_L0_3["ADD: prod[4] + prod[5]"]
        ADD_L0_4["ADD: prod[6] + prod[7]"]
        ADD_L0_5["ADD: prod[8] + prod[9]"]
        ADD_L0_6["ADD: prod[10] + prod[11]"]
        ADD_L0_7["ADD: prod[12] + prod[13]"]
        ADD_L0_8["ADD: prod[14] + prod[15]"]
    end

    subgraph Stage4["🔢 Stage 4: Adder Tree Level 1"]
        ADD_L1_1["ADD: L0[0] + L0[1]<br/>→ 32-bit"]
        ADD_L1_2["ADD: L0[2] + L0[3]"]
        ADD_L1_3["ADD: L0[4] + L0[5]"]
        ADD_L1_4["ADD: L0[6] + L0[7]"]
    end

    subgraph Stage5["🔢 Stage 5: Adder Tree Level 2"]
        ADD_L2_1["ADD: L1[0] + L1[1]<br/>→ 32-bit"]
        ADD_L2_2["ADD: L1[2] + L1[3]"]
    end

    subgraph Stage6["🔢 Stage 6: Adder Tree Level 3"]
        ADD_L3["ADD: L2[0] + L2[1]<br/>→ Final Sum (32-bit)"]
    end

    subgraph Stage7["📊 Stage 7: Row Accumulator"]
        ACC["accumulator<br/>+= sum_final<br/>(INT32)<br/>Reset on last beat"]
    end

    subgraph Stage8["🔀 Stage 8: Dequantization S1"]
        DEQ_S1["deq_s1_raw = result_commit<br/>deq_s1_scale = scale<br/>dequant_mul = raw × scale"]
    end

    subgraph Stage9["🔀 Stage 9: Dequantization S2"]
        DEQ_S2["result_dequant = dequant_mul >>> 15<br/>(Right shift by SCALE_FRAC_BITS)<br/>Bypass if scale == FP16_ONE"]
        RESULT_VAL["result_final_value<br/>(INT32 output)"]
    end

    subgraph FIFOBlock["📦 Result FIFO (8 entries)"]
        FIFO["FIFO_Depth = 8<br/>Store INT32 results<br/>One per row completion"]
    end

    subgraph Output["🔶 OUTPUT"]
        RESULT["result_data<br/>(32-bit)"]
        VALID["result_valid"]
        LAST["result_last"]
    end

    %% Connections
    ACT --> REG_ACT
    WGT --> REG_WGT
    SCALE --> REG_SCALE

    REG_ACT --> DSP
    REG_WGT --> DSP

    DSP --> MULT_CAPTURE
    MULT_CAPTURE --> ADD_L0_1
    MULT_CAPTURE --> ADD_L0_2
    MULT_CAPTURE --> ADD_L0_3
    MULT_CAPTURE --> ADD_L0_4
    MULT_CAPTURE --> ADD_L0_5
    MULT_CAPTURE --> ADD_L0_6
    MULT_CAPTURE --> ADD_L0_7
    MULT_CAPTURE --> ADD_L0_8

    ADD_L0_1 --> ADD_L1_1
    ADD_L0_2 --> ADD_L1_1
    ADD_L0_3 --> ADD_L1_2
    ADD_L0_4 --> ADD_L1_2
    ADD_L0_5 --> ADD_L1_3
    ADD_L0_6 --> ADD_L1_3
    ADD_L0_7 --> ADD_L1_4
    ADD_L0_8 --> ADD_L1_4

    ADD_L1_1 --> ADD_L2_1
    ADD_L1_2 --> ADD_L2_1
    ADD_L1_3 --> ADD_L2_2
    ADD_L1_4 --> ADD_L2_2

    ADD_L2_1 --> ADD_L3
    ADD_L2_2 --> ADD_L3

    ADD_L3 --> ACC
    REG_SCALE --> DEQ_S1
    ACC --> DEQ_S1

    DEQ_S1 --> DEQ_S2
    DEQ_S2 --> RESULT_VAL

    RESULT_VAL --> FIFO
    FIFO --> RESULT
    FIFO --> VALID
    FIFO --> LAST

    RESULT --> Output
    VALID --> Output
    LAST --> Output

    style Stage0 fill:#fff4e6
    style Stage1 fill:#ffe6e6
    style Stage3 fill:#e6f3ff
    style Stage4 fill:#e6f3ff
    style Stage5 fill:#e6f3ff
    style Stage6 fill:#e6f3ff
    style Stage7 fill:#f0e6ff
    style Stage8 fill:#e6ffe6
    style Stage9 fill:#e6ffe6
    style FIFOBlock fill:#ffe6f0
    style Input fill:#f0f0f0
    style Output fill:#f0f0f0
```

## Pipeline Timing Summary

| Stage | Operation | Latency | Registers | Output Width |
|-------|-----------|---------|-----------|--------------|
| 0 | Input capture | 1 | mult_act_reg, mult_weight_reg | 8×16 bits |
| 1-2 | DSP multiply | 2 | mult_pipe[15:0] | 16×16 bits |
| 3 | Adder L0 (pair sum) | 1 | sum_pipe[0][7:0] | 8×32 bits |
| 4 | Adder L1 (quad sum) | 1 | sum_pipe[1][3:0] | 4×32 bits |
| 5 | Adder L2 (octal sum) | 1 | sum_pipe[2][1:0] | 2×32 bits |
| 6 | Adder L3 (final sum) | 1 | sum_pipe[3][0] | 1×32 bits |
| 7 | Accumulate | 1 | accumulator | 32 bits |
| 8 | Dequant S1 | 1 | deq_s1_raw, deq_s1_scale | 32 bits |
| 9 | Dequant S2 | 1 | deq_s2_value | 32 bits |
| - | Result FIFO | 0 | 8×32 bits | 32 bits |
| **Total** | **Complete** | **~11** | **Multiple stages** | **INT32 output** |

## Data Flow Details

### Input Channels (Synchronized)
- `activation_valid` & `weight_valid` must both be asserted
- Both must have matching `activation_last` & `weight_last`
- When synchronized, `input_fire` allows data to advance

### Backpressure Logic
```
reserved_result_slots = fifo_count_after_pop + pending_result_count

can_accept_pair = 
    incoming_last_match &&
    ((!incoming_pair_last) || (reserved_result_slots < FIFO_DEPTH))

activation_ready = can_accept_pair && weight_valid
weight_ready = can_accept_pair && activation_valid
```

### Scaling/Dequantization
- Input scale: 16-bit fixed-point (SCALE_FRAC_BITS = 15)
- FP16_ONE bypass: `16'h3c00` → use raw accumulator without scaling
- Dequant formula: `(raw_acc × scale) >> 15`
- Width: 32-bit × 16-bit → 48-bit → shifted back to 32-bit

### Result FIFO
- Depth: 8 entries (power of 2)
- Tracks row completion via `result_last` flag
- Enables decoupling of MAC pipeline from result readback
- Prevents input stall when BRAM write is slower

## Key Features
✅ **16 parallel INT8×INT8 multipliers** (16 DSP blocks)
✅ **Registered binary adder tree** (4 levels)
✅ **Row accumulator** for multi-beat vectors
✅ **Fixed-point scaling** with bypass
✅ **Result FIFO** for throughput decoupling
✅ **Full handshake backpressure** between pipeline stages
✅ **Throughput**: 1 beat/clock (when FIFO available)
