#!/usr/bin/env python3
"""Export dense attention inputs and independent, pre-DUT numerical references.

Run from any directory: python generate_attention_vectors.py [--check]
Only the three adjacent attention_* artifacts are written; --check writes none.
No simulator output, DUT arithmetic implementation, or external dependency is used.
The existing testbench is read solely to audit its pinned fixture constants.
"""

import argparse
import hashlib
import json
import math
from pathlib import Path
import re
import struct
from decimal import Decimal, localcontext
from functools import lru_cache


HERE = Path(__file__).resolve().parent
Q8_MARGIN = 0.01
HALF_MARGIN_ULP = 0.05
MAX_ATTEMPTS = 10000
SPECS = [
    ("dense_d32_mha", 32, 4, 4, 33, 0x41322001, False),
    ("dense_d256_gqa", 256, 4, 1, 33, 0x42562001, False),
    ("dense_d32_late_max", 32, 4, 2, 33, 0x41324D58, True),
]


def f32(x):
    return struct.unpack("<f", struct.pack("<f", x))[0]


def bits32(x):
    return struct.unpack("<I", struct.pack("<f", x))[0]


def from32(x):
    return struct.unpack("<f", struct.pack("<I", x))[0]


def bits16(x):
    return struct.unpack("<H", struct.pack("<e", x))[0]


def from16(x):
    return struct.unpack("<e", struct.pack("<H", x))[0]


def rne_ratio(numerator, denominator):
    """Round an exact integer ratio directly to binary32, including subnormals."""
    sign = (numerator < 0) != (denominator < 0)
    numerator, denominator = abs(numerator), abs(denominator)
    assert denominator
    if numerator == 0:
        return from32(int(sign) << 31)
    exponent = numerator.bit_length() - denominator.bit_length()
    if exponent >= 0:
        if numerator < denominator << exponent:
            exponent -= 1
    elif numerator << -exponent < denominator:
        exponent -= 1
    shift = 23 - max(exponent, -126)
    if shift >= 0:
        whole, remainder = divmod(numerator << shift, denominator)
        divisor = denominator
    else:
        whole, remainder = divmod(numerator, denominator << -shift)
        divisor = denominator << -shift
    if 2 * remainder > divisor or (2 * remainder == divisor and whole & 1):
        whole += 1
    if whole == 1 << 24:
        whole >>= 1
        exponent += 1
    assert exponent <= 127, "fixtures must remain finite"
    if exponent < -126:
        raw = whole
    else:
        raw = ((exponent + 127) << 23) | (whole - (1 << 23))
    return from32((int(sign) << 31) | raw)


def add32(a, b):
    # Two binary32 operands can be added via binary64 then binary32 with RNE.
    return f32(a + b)


def mul32(a, b):
    # A binary32 product has <=48 significant bits, exact in binary64.
    return f32(a * b)


def div32(a, b):
    an, ad = a.as_integer_ratio()
    bn, bd = b.as_integer_ratio()
    return rne_ratio(an * bd, ad * bn)


def decimal32(value):
    # Direct exact-ratio rounding avoids Decimal -> binary64 -> binary32 ties.
    return rne_ratio(*value.as_integer_ratio())


@lru_cache(maxsize=None)
def exp32(x):
    """80-digit exp, checked at 120 digits and against a separate libm exp."""
    with localcontext() as ctx:
        ctx.prec = 80
        first = decimal32(Decimal.from_float(x).exp())
        ctx.prec = 120
        second = decimal32(Decimal.from_float(x).exp())
    assert bits32(first) == bits32(second), "exp precision did not converge"
    assert bits32(first) == bits32(f32(math.exp(x))), "libm exp cross-check"
    return first


class XorShift32:
    """Fully specified PRNG; does not depend on Python's random implementation."""

    def __init__(self, seed):
        self.state = seed & 0xFFFFFFFF
        assert self.state

    def next(self):
        x = self.state
        x ^= (x << 13) & 0xFFFFFFFF
        x ^= x >> 17
        x ^= (x << 5) & 0xFFFFFFFF
        self.state = x & 0xFFFFFFFF
        return self.state


def score_rows(q, k, dimension, heads, kvheads, tokens, mask):
    rows = []
    cancellation = []
    for head in range(heads):
        group = head // (heads // kvheads)
        scores = []
        for token in range(tokens):
            score, absolute_sum = 0.0, 0.0
            for dim in range(dimension):
                product = mul32(q[head * dimension + dim],
                                k[(token * kvheads + group) * dimension + dim])
                score = add32(score, product)
                absolute_sum += abs(product)
            scores.append(score)
            if mask[token]:
                cancellation.append(abs(score) / absolute_sum)
        rows.append(scores)
    return rows, cancellation


def online_schedule(scores, mask):
    schedule, maximum, denominator = [], None, 0.0
    for token, score in enumerate(scores):
        if not mask[token]:
            continue
        if maximum is None:
            schedule.append((token, "first", 1.0))
            maximum, denominator = score, 1.0
        elif score > maximum:
            alpha = exp32(add32(maximum, -score))
            denominator = add32(mul32(denominator, alpha), 1.0)
            maximum = score
            schedule.append((token, "rescale", alpha))
        else:
            beta = exp32(add32(score, -maximum))
            denominator = add32(denominator, beta)
            schedule.append((token, "add", beta))
    assert maximum is not None
    return schedule, denominator


def online_context(values, schedule, denominator):
    """values[token][dimension], with exactly the documented FP32 operation order."""
    accum = None
    for token, operation, weight in schedule:
        value = values[token]
        if operation == "first":
            accum = value.copy()
        elif operation == "rescale":
            accum = [add32(mul32(a, weight), v) for a, v in zip(accum, value)]
        else:
            accum = [add32(a, mul32(v, weight)) for a, v in zip(accum, value)]
    return [div32(a, denominator) for a in accum]


def quantize(context):
    scale = div32(max(map(abs, context)), 127.0)
    inverse = div32(1.0, scale) if scale else 0.0
    scaled = [mul32(value, inverse) for value in context]
    q8 = [round(value) for value in scaled]
    assert all(-127 <= value <= 127 for value in q8)
    margin = min(abs(abs(value) - (math.floor(abs(value)) + 0.5)) for value in scaled)
    half = bits16(scale)
    # Distance to either adjacent half-rounding midpoint / local FP16 spacing.
    if scale:
        middle = from16(half)
        low, high = from16(half - 1), from16(half + 1)
        half_margin = min(abs(scale - (low + middle) / 2) / (middle - low),
                          abs(scale - (middle + high) / 2) / (high - middle))
    else:
        half_margin = 0.5
    return {"scale": scale, "half": half, "q8": q8,
            "q8_margin": margin, "half_margin_ulp": half_margin}


def outward32(value, upward):
    rounded = f32(value)
    if (upward and rounded >= value) or (not upward and rounded <= value):
        return rounded
    raw = bits32(rounded)
    if rounded == 0:
        return from32(1 if upward else 0x80000001)
    return from32(raw + (1 if (rounded > 0) == upward else -1))


def quantization_error_allowance(online, reference):
    """Conservative interval bound, conditional on the existing context gate.

    Monotone RNE operations enclose all scales, reciprocals and scaled outputs.
    This checks numerical tolerance cannot excuse a changed raw Q8/half value;
    it is not a proof that any DUT satisfies the context gate.
    """
    records = []
    for offset in range(0, len(online), 32):
        values = online[offset:offset + 32]
        # Use exported F32 references, which are the values read by the bench.
        refs = [decimal32(x) for x in reference[offset:offset + 32]]
        error_bound = max(2e-6 + 2e-6 * abs(ref) + abs(ref - value)
                          for value, ref in zip(values, refs))
        amax = max(map(abs, values))
        dlow = div32(outward32(amax - error_bound, False), 127.0)
        dhigh = div32(outward32(amax + error_bound, True), 127.0)
        ilow, ihigh = div32(1.0, dhigh), div32(1.0, dlow)
        pack = quantize(values)
        unchanged = bits16(dlow) == bits16(dhigh) == pack["half"]
        margin = 0.5
        for value, target in zip(values, pack["q8"]):
            low = outward32(value - error_bound, False)
            high = outward32(value + error_bound, True)
            endpoints = [mul32(x, y) for x in (low, high) for y in (ilow, ihigh)]
            qlow, qhigh = min(endpoints), max(endpoints)
            unchanged = unchanged and round(qlow) == round(qhigh) == target
            margin = min(margin, qlow - (target - 0.5), (target + 0.5) - qhigh)
        records.append({"output_block": offset // 32,
                        "conservative_context_abs_error_allowance": error_bound,
                        "minimum_remaining_q8_boundary_distance": margin,
                        "same_raw_q8_and_half_for_entire_context_tolerance": unchanged})
    return records


def mathematical_weights(q, k, dimension, heads, kvheads, tokens, mask, precision):
    """Independent global stable softmax, exact input values, no FP32 dot rounding."""
    with localcontext() as ctx:
        ctx.prec = precision
        decimal_q = [Decimal.from_float(x) for x in q]
        decimal_k = [Decimal.from_float(x) for x in k]
        all_weights = []
        for head in range(heads):
            group = head // (heads // kvheads)
            scores = [sum((decimal_q[head * dimension + dim] *
                           decimal_k[(token * kvheads + group) * dimension + dim]
                           for dim in range(dimension)), Decimal(0)) for token in range(tokens)]
            maximum = max(score for score, visible in zip(scores, mask) if visible)
            weights = [(score - maximum).exp() if visible else Decimal(0)
                       for score, visible in zip(scores, mask)]
            denominator = sum(weights, Decimal(0))
            all_weights.append([weight / denominator for weight in weights])
        return all_weights


def mathematical_context(values, weights, precision):
    with localcontext() as ctx:
        ctx.prec = precision
        return [sum((weight * Decimal.from_float(values[token][dim])
                     for token, weight in enumerate(weights)), Decimal(0))
                for dim in range(len(values[0]))]


def error_metrics(online, reference, vscale):
    with localcontext() as ctx:
        ctx.prec = 80
        error = [Decimal.from_float(a) - b for a, b in zip(online, reference)]
        nmse = sum(x * x for x in error) / sum(x * x for x in reference)
        max_abs = max(map(abs, error))
        floor = Decimal.from_float(0.01 * vscale)
        relative = [abs(e / ref) for e, ref in zip(error, reference) if abs(ref) >= floor]
        tight_ratios = [abs(e) / (Decimal("0.000002") * (1 + abs(ref)))
                        for e, ref in zip(error, reference)]
        return {"nmse": float(nmse), "max_abs": float(max_abs),
                "max_abs_over_vscale": float(max_abs / Decimal.from_float(vscale)),
                "max_relative_above_0.01_vscale": float(max(relative, default=Decimal(0))),
                "existing_tb_tolerance_max_ratio": float(max(tight_ratios)),
                "vscale": vscale}


def create_case(spec):
    name, dimension, heads, kvheads, tokens, base_seed, late_max = spec
    rng = XorShift32(base_seed)
    # Pre-scaled Q is itself the contract input. No scaling inside either oracle.
    q = [f32(((-1) ** dim) * (64 + rng.next() % 129) / (128 * math.sqrt(dimension)))
         for head in range(heads) for dim in range(dimension)]
    k = []
    for token in range(tokens):
        for group in range(kvheads):
            for dim in range(dimension):
                if late_max and token == tokens - 1:
                    value = ((-1) ** dim) * (160 + rng.next() % 65) / 128
                else:
                    value = ((-1) ** (dim // 2 + token + group)) * (32 + rng.next() % 193) / 128
                k.append(from16(bits16(value)))
    mask = [1] * tokens
    scores, cancellation = score_rows(q, k, dimension, heads, kvheads, tokens, mask)
    schedules = [online_schedule(row, mask) for row in scores]
    weights50 = mathematical_weights(q, k, dimension, heads, kvheads, tokens, mask, 50)
    weights80 = mathematical_weights(q, k, dimension, heads, kvheads, tokens, mask, 80)
    v = [0.0] * (tokens * kvheads * dimension)
    online = [0.0] * (heads * dimension)
    reference = [Decimal(0)] * (heads * dimension)
    selections = []
    precision_delta = Decimal(0)
    for group in range(kvheads):
        for block in range(dimension // 32):
            head_ids = list(range(group * (heads // kvheads), (group + 1) * (heads // kvheads)))
            start_seed = (base_seed ^ ((group + 1) * 0x9E3779B9) ^ ((block + 1) * 0x85EBCA6B)) & 0xFFFFFFFF
            for attempt in range(MAX_ATTEMPTS):
                seed = (start_seed + attempt) & 0xFFFFFFFF
                if not seed:
                    continue
                vrng = XorShift32(seed)
                values = [[((-1) ** (token + dim + group)) * (1 + vrng.next() % 511) / 512
                           for dim in range(32)] for token in range(tokens)]
                outputs = {head: online_context(values, *schedules[head]) for head in head_ids}
                packs = {head: quantize(outputs[head]) for head in head_ids}
                if any(p["q8_margin"] < Q8_MARGIN or p["half_margin_ulp"] < HALF_MARGIN_ULP
                       for p in packs.values()):
                    continue
                references = {head: mathematical_context(values, weights80[head], 80) for head in head_ids}
                mathematical_packs = {head: quantize([decimal32(x) for x in references[head]]) for head in head_ids}
                if any(packs[head]["half"] != mathematical_packs[head]["half"] or
                       packs[head]["q8"] != mathematical_packs[head]["q8"] or
                       mathematical_packs[head]["q8_margin"] < Q8_MARGIN or
                       mathematical_packs[head]["half_margin_ulp"] < HALF_MARGIN_ULP for head in head_ids):
                    continue
                break
            else:
                raise AssertionError(f"pre-DUT deterministic seed search exhausted: {name}/{group}/{block}")
            for token in range(tokens):
                offset = (token * kvheads + group) * dimension + block * 32
                v[offset:offset + 32] = values[token]
            for head in head_ids:
                offset = head * dimension + block * 32
                online[offset:offset + 32] = outputs[head]
                reference[offset:offset + 32] = references[head]
                ref50 = mathematical_context(values, weights50[head], 50)
                with localcontext() as ctx:
                    ctx.prec = 100
                    precision_delta = max(precision_delta, max(abs(a - b) for a, b in zip(ref50, references[head])))
                assert [bits32(decimal32(x)) for x in ref50] == [bits32(decimal32(x)) for x in references[head]]
            selections.append({"kv_group": group, "dimension_block": block, "start_seed": start_seed,
                               "selected_seed": seed, "attempt": attempt, "affected_heads": head_ids,
                               "minimum_q8_margin": min(p["q8_margin"] for p in packs.values()),
                               "minimum_half_margin_ulp": min(p["half_margin_ulp"] for p in packs.values()),
                               "minimum_mathematical_q8_margin": min(p["q8_margin"] for p in mathematical_packs.values()),
                               "minimum_mathematical_half_margin_ulp": min(p["half_margin_ulp"] for p in mathematical_packs.values())})
    assert all(x != 0 and math.isfinite(x) for x in q + k + v)
    assert all(from16(bits16(x)) == x for x in k + v)
    packs = [quantize(online[offset:offset + 32]) for offset in range(0, len(online), 32)]
    metrics = error_metrics(online, reference, max(map(abs, v)))
    assert metrics["nmse"] <= 1e-6
    assert metrics["max_abs_over_vscale"] <= 1e-3
    assert metrics["max_relative_above_0.01_vscale"] <= 5e-3
    assert metrics["existing_tb_tolerance_max_ratio"] <= 1
    error_allowance = quantization_error_allowance(online, reference)
    assert all(x["same_raw_q8_and_half_for_entire_context_tolerance"] for x in error_allowance)
    if late_max:
        assert all(row[-1] > max(row[:-1]) for row in scores)
    return {"name": name, "D": dimension, "Hq": heads, "Hkv": kvheads, "N": tokens,
            "base_seed": base_seed, "late_max": late_max, "q": q, "k": k, "v": v, "mask": mask,
            "online": online, "reference": reference, "packs": packs,
            "provenance": {"seed_selections": selections, "oracle_error_metrics": metrics,
                           "decimal50_vs_decimal80_max_abs": str(precision_delta),
                           "scores_fp32": scores,
                           "rescale_tokens_by_head": [[token for token, operation, _ in schedule if operation == "rescale"]
                                                      for schedule, _ in schedules],
                           "min_dot_cancellation_ratio": min(cancellation),
                           "max_dot_cancellation_ratio": max(cancellation),
                           "all_input_scalars_nonzero": True,
                           "all_q8_and_half_scales_agree_between_oracles": True,
                           "conditional_quantization_error_allowance": error_allowance}}


def legacy_context(kind, dimension, heads, kvheads, tokens):
    """Reproduce the testbench fixture equations, independently of DUT outputs."""
    online, mathematical = [], []
    for head in range(heads):
        group = head // (heads // kvheads)
        query = (head + 1) / 2 if kind in (1, 2, 4) else 1.0
        keys = [(8.0 if token == tokens - 1 else 0.0) if kind in (1, 4) else
                ((token % 3 - 1) / 256 if kind == 2 else 0.25) for token in range(tokens)]
        scores = [mul32(query, key) for key in keys]
        values = [[((group + 1) * (dim % 8 - 4) +
                    (5 if kind in (1, 4) and token == tokens - 1 else token % 5 - 2) +
                    (dim // 32 if kind == 3 else 0)) / 32
                   for dim in range(dimension)] for token in range(tokens)]
        online.extend(online_context(values, *online_schedule(scores, [1] * tokens)))
        with localcontext() as ctx:
            ctx.prec = 80
            maximum = Decimal.from_float(max(scores))
            weights = [(Decimal.from_float(score) - maximum).exp() for score in scores]
            total = sum(weights, Decimal(0))
            weights = [weight / total for weight in weights]
        mathematical.extend(mathematical_context(values, weights, 80))
    return online, mathematical


def audit_existing_pins():
    """Assert pinned literals are present; publish both oracle comparisons in full."""
    text = (HERE / "tb_Attention_Engine.v").read_text(encoding="utf-8")
    pins = {
        "uniform31": (0, 32, 4, 4, 31, "1c0c1a1418101419", None),
        "uniform32": (0, 32, 4, 4, 32, "1c0e1a1818141420", None),
        "uniform33": (0, 32, 4, 4, 33, "1c0e1a1818141420", None),
        "uniform129": (0, 32, 4, 4, 129, "1c091a0e180a140c", None),
        "late_max": (1, 32, 4, 2, 33, "198b198b1801162a",
                     ["7f6a55412c1702ee", "7f6f5f4f3f2f1f0f", "7f68513a230cf4dd", "7f68513a230cf4dd"]),
        "low_variance": (2, 32, 4, 4, 129, "1c091a0e180a140c",
                         ["5e3f1f00e0c0a181", "5f3f1f00e0c0a181", "5f3f2000e0c0a181", "5f3f2000e0c0a181"]),
    }
    reports = []
    for name, (kind, dimension, heads, kvheads, tokens, scale_table, q8_tables) in pins.items():
        assert re.search(r"64'h" + scale_table, text, re.IGNORECASE), f"missing testbench pin {scale_table}"
        if q8_tables:
            assert all(re.search(r"64'h" + value, text, re.IGNORECASE) for value in q8_tables)
        online, mathematical = legacy_context(kind, dimension, heads, kvheads, tokens)
        op = [quantize(online[i:i + 32]) for i in range(0, len(online), 32)]
        mp = [quantize([decimal32(x) for x in mathematical[i:i + 32]]) for i in range(0, len(online), 32)]
        scales = [(int(scale_table, 16) >> (16 * head)) & 65535 for head in range(heads)]
        q8 = [[((int(value, 16) >> (8 * dim)) & 255) for dim in range(8)] for value in q8_tables] if q8_tables else None
        reports.append({"name": name, "fixture": kind, "D": dimension, "Hq": heads, "Hkv": kvheads, "N": tokens,
                        "pinned_scales_hex": [f"{s:04x}" for s in scales],
                        "ordered_scales_hex": [f"{p['half']:04x}" for p in op],
                        "mathematical_scales_hex": [f"{p['half']:04x}" for p in mp],
                        "scale_pins_match_ordered": scales == [p["half"] for p in op],
                        "scale_pins_match_mathematical": scales == [p["half"] for p in mp],
                        "pinned_q8_first8_lowbyte": q8,
                        "q8_pins_present": q8 is not None,
                        "ordered_q8_first8_lowbyte": [[x & 255 for x in p["q8"][:8]] for p in op],
                        "mathematical_q8_first8_lowbyte": [[x & 255 for x in p["q8"][:8]] for p in mp],
                        "q8_pins_match_ordered": q8 is None or q8 == [[x & 255 for x in p["q8"][:8]] for p in op],
                        "q8_pins_match_mathematical": q8 is None or q8 == [[x & 255 for x in p["q8"][:8]] for p in mp],
                        "ordered_context_hex": [f"{bits32(x):08x}" for x in online],
                        "mathematical_context_decimal": [str(x) for x in mathematical],
                        "oracle_error_metrics": error_metrics(online, mathematical, 1.0)})
    # The multi-block D256 table also has independent provenance.
    online, mathematical = legacy_context(3, 256, 4, 2, 3)
    block_tables = ["18891808170e160c150a14081408150a", "1a0c198b190a18891808170e18081889"]
    assert all(re.search(r"128'h" + value, text, re.IGNORECASE) for value in block_tables)
    expected = [(int(block_tables[head // 2], 16) >> (16 * block)) & 65535
                for head in range(4) for block in range(8)]
    op = [quantize(online[i:i + 32]) for i in range(0, 1024, 32)]
    mp = [quantize([decimal32(x) for x in mathematical[i:i + 32]]) for i in range(0, 1024, 32)]
    reports.append({"name": "dimension256_multiblock", "fixture": 3,
                    "D": 256, "Hq": 4, "Hkv": 2, "N": 3,
                    "pinned_scales_hex": [f"{s:04x}" for s in expected],
                    "ordered_scales_hex": [f"{p['half']:04x}" for p in op],
                    "mathematical_scales_hex": [f"{p['half']:04x}" for p in mp],
                    "scale_pins_match_ordered": expected == [p["half"] for p in op],
                    "scale_pins_match_mathematical": expected == [p["half"] for p in mp],
                    "q8_pins_match_ordered": True, "q8_pins_match_mathematical": True})
    return reports


def arithmetic_selfcheck():
    # Exact integer-ratio checks are independent of binary64 mul/add used above.
    rng = XorShift32(0xA771F032)
    for _ in range(4096):
        a = from32((rng.next() & 0x807FFFFF) | ((110 + rng.next() % 35) << 23))
        b = from32((rng.next() & 0x807FFFFF) | ((110 + rng.next() % 35) << 23))
        an, ad = a.as_integer_ratio()
        bn, bd = b.as_integer_ratio()
        assert bits32(add32(a, b)) == bits32(rne_ratio(an * bd + bn * ad, ad * bd))
        assert bits32(mul32(a, b)) == bits32(rne_ratio(an * bn, ad * bd))
    assert bits32(rne_ratio((1 << 24) + 1, 1 << 24)) == 0x3F800000
    assert bits32(rne_ratio((1 << 24) + 3, 1 << 24)) == 0x3F800002
    assert bits32(rne_ratio(1, 1 << 150)) == 0
    assert bits32(rne_ratio(3, 1 << 150)) == 2
    assert bits16(1 + 2 ** -11) == 0x3C00
    assert round(2.5) == 2 and round(3.5) == 4 and round(-2.5) == -2


def export(cases, pins):
    stride, header_words = 16, 4 + 16 * len(cases)
    inputs, expected = [0] * header_words, [0] * header_words
    metadata = []
    for index, case in enumerate(cases):
        offsets = []
        for values, encoder in [(case["q"], bits32), (case["k"], bits16), (case["v"], bits16), (case["mask"], int)]:
            offsets.append(len(inputs))
            inputs.extend(encoder(x) for x in values)
        outputs = []
        for values in [[bits32(x) for x in case["online"]], [p["half"] for p in case["packs"]],
                       [x & 255 for p in case["packs"] for x in p["q8"]],
                       [bits32(decimal32(x)) for x in case["reference"]]]:
            outputs.append(len(expected))
            expected.extend(values)
        descriptor = [case[k] for k in ("D", "Hq", "Hkv", "N")] + offsets + outputs + [int(case["late_max"]), case["base_seed"], 0, 0]
        start = 4 + index * stride
        inputs[start:start + stride] = descriptor
        expected[start:start + stride] = descriptor
        metadata.append({"index": index, "name": case["name"], "descriptor": descriptor,
                         **case["provenance"],
                         "mathematical_context_decimal": [str(x) for x in case["reference"]]})
    inputs[:4] = expected[:4] = [len(cases), stride, len(inputs), len(expected)]
    encoded_inputs = "".join(f"{x:08x}\n" for x in inputs).encode("ascii")
    encoded_expected = "".join(f"{x:08x}\n" for x in expected).encode("ascii")
    provenance = {
        "schema_version": 1,
        "evidence_level": "offline independent CPU references only; no RTL simulation or board evidence",
        "generator_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        "format": {
            "word": "one 32-bit hexadecimal word per line; readmemh array index is absolute word offset",
            "header": ["case_count", "descriptor_stride_words", "input_total_words", "expected_total_words"],
            "descriptor_base": "4 + case_index * 16; identical headers and descriptors in both files",
            "descriptor_fields": ["D", "Hq", "Hkv", "N", "q_offset", "k_offset", "v_offset", "mask_offset",
                                  "ordered_context_offset", "fp16_scale_offset", "q8_offset", "mathematical_context_offset",
                                  "flags_bit0_late_max", "base_seed", "reserved0", "reserved1"],
            "input_layout": "Q F32 [Hq,D]; K/V zero-extended F16 [N,Hkv,D]; mask zero-extended byte [N]",
            "expected_layout": "context F32 [Hq,D]; scale low16 [Hq*D/32]; Q8 low8 two's-complement [Hq,D]; mathematical context F32 [Hq,D]",
            "lengths": {"input_words": len(inputs), "expected_words": len(expected)},
        },
        "oracle": {
            "dot": "ascending dimension; separate RNE binary32 product then RNE binary32 add, initial +0",
            "online": "ascending visible token; first=(score,1,V); larger: alpha=RNE(exp(RNE(m-score))), l=RNE(RNE(l*alpha)+1), O=RNE(RNE(O*alpha)+V); otherwise beta=RNE(exp(RNE(score-m))), l=RNE(l+beta), O=RNE(O+RNE(V*beta)); normalize RNE(O/l)",
            "exp": "Decimal 80 and 120 digits, direct integer-ratio RNE binary32; independently checked against math.exp rounded to F32",
            "rtl_exp_distinction": "The oracle uses correctly rounded exp, not the RTL's Q48 degree-12 approximation. No bit-for-bit RTL exponential result is assumed. Context is checked with the existing numerical gate, while scale/Q8 remain exact. Per-case interval bounds prove that any context satisfying that gate retains the same raw scale/Q8 for these preselected fixtures; actual RTL compliance still requires simulation.",
            "mathematical": "global stable softmax with exact decoded Q/F16 inputs and unrounded dot; Decimal 50 and 80 precision agree on all exported F32 values",
            "arm_q8": "each consecutive 32 outputs: d=RNE_F32(amax/127), id=d?RNE_F32(1/d):0; scale=RNE_F16(d); qs=RNE_integer(RNE_F32(context*id)); no clipping",
            "original_gates": {"nmse_max": 1e-6, "max_abs_over_vscale": 1e-3,
                               "relative_max": 5e-3, "relative_reference_floor_over_vscale": 0.01},
            "existing_tb_context_gate": "abs(actual-mathematical) <= 2e-6 + 2e-6*abs(mathematical)",
        },
        "fixture_selection": {
            "timing": "Only independent references are used. No DUT or simulator outputs are read, and no fixtures are changed in response to DUT results.",
            "prng": "xorshift32: x ^= x<<13; x ^= x>>17; x ^= x<<5, uint32 truncation",
            "q_k_generation": "Q/K use base_seed, in serialized layout order; all signs alternate by dimensions and token, all magnitudes nonzero; late-max K signs align with Q at final token",
            "v_seed_search": "per KV group and 32-dimension block: start=base_seed XOR ((group+1)*0x9e3779b9) XOR ((block+1)*0x85ebca6b), uint32; try start+attempt, ascending attempt from zero, skip zero seed; first candidate meeting both oracles' quantization margins and identical scale/Q8 wins",
            "v_values": "token then dimension order: (-1)^(token+dimension+group) * (1+xorshift32()%511)/512, exactly representable FP16",
            "q8_half_integer_margin_min": Q8_MARGIN,
            "fp16_scale_midpoint_margin_min_local_ulp": HALF_MARGIN_ULP,
            "max_attempts_per_block": MAX_ATTEMPTS,
        },
        "verification": {"exact_ratio_add_mul_checks": 8192,
                         "exp_distinct_inputs_checked": exp32.cache_info().currsize,
                         "binary32_ties_subnormal_half_and_integer_ties": "passed",
                         "all_dense_numeric_gates_pass": True,
                         "all_legacy_pins_match_ordered": all(p["scale_pins_match_ordered"] and p["q8_pins_match_ordered"] for p in pins)},
        "files": {"attention_dense_vectors.mem": {"sha256": hashlib.sha256(encoded_inputs).hexdigest()},
                  "attention_dense_expected.mem": {"sha256": hashlib.sha256(encoded_expected).hexdigest()}},
        "cases": metadata,
        "legacy_pin_audit": pins,
    }
    return {"attention_dense_vectors.mem": encoded_inputs,
            "attention_dense_expected.mem": encoded_expected,
            "attention_vector_provenance.json": (json.dumps(provenance, indent=2, sort_keys=True) + "\n").encode("utf-8")}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="regenerate in memory and require byte-identical existing artifacts")
    args = parser.parse_args()
    arithmetic_selfcheck()
    cases = []
    for spec in SPECS:
        case = create_case(spec)
        cases.append(case)
        print(f"{case['name']}: {json.dumps(case['provenance']['oracle_error_metrics'], sort_keys=True)}", flush=True)
    pins = audit_existing_pins()
    for pin in pins:
        print(f"pin {pin['name']}: ordered_scale={pin['scale_pins_match_ordered']} ordered_q8={pin['q8_pins_match_ordered']} "
              f"mathematical_scale={pin['scale_pins_match_mathematical']} mathematical_q8={pin['q8_pins_match_mathematical']}", flush=True)
    for name, data in export(cases, pins).items():
        path = HERE / name
        if args.check:
            assert path.read_bytes() == data, f"regeneration differs: {path}"
        else:
            path.write_bytes(data)
        print(f"{'verified' if args.check else 'wrote'} {name}: {len(data)} bytes", flush=True)
    assert all(pin["scale_pins_match_ordered"] and pin["q8_pins_match_ordered"] for pin in pins), \
        "existing pins differ from independent ordered oracle; see provenance audit, never repair from DUT output"
    print("PASS: dense vectors, independent oracle gates, legacy pins, and artifact verification", flush=True)


if __name__ == "__main__":
    main()
