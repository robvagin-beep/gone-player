"""Synthetic bench: current BPM pipeline vs patch 01. Run: python3 bpm_bench.py"""
import numpy as np
from bpm_port import *

rng = np.random.default_rng(7)


def kick(sr):
    t = np.arange(int(0.12 * sr)) / sr
    f = 50 + 70 * np.exp(-t * 40)
    return np.sin(2 * np.pi * np.cumsum(f) / sr) * np.exp(-t * 25)


def noise_burst(sr, dur, decay):
    t = np.arange(int(dur * sr)) / sr
    return rng.standard_normal(len(t)) * np.exp(-t * decay)


def render(bpm, dur, pattern, sr=SR):
    """pattern: list of (beat_position_in_bar(0..4), instrument, gain)."""
    n = int(dur * sr)
    y = np.zeros(n + int(sr))
    k, hat, snare = kick(sr), noise_burst(sr, 0.03, 150) * 0.25, noise_burst(sr, 0.12, 30) * 0.5
    inst = {"k": k, "h": hat, "s": snare}
    beat = 60.0 / bpm
    bars = int(dur / (4 * beat)) + 1
    for b in range(bars):
        for pos, name, g in pattern:
            t0 = (b * 4 + pos) * beat
            i0 = int(round(t0 * sr))
            if i0 >= n:
                continue
            s = inst[name] * g
            y[i0: i0 + len(s)] += s[: len(y) - i0]
    y = y[:n] + rng.standard_normal(n) * 0.003
    return (y / np.max(np.abs(y)) * 0.8).astype(np.float32)


PATTERNS = {
    "4x4 kick": [(i, "k", 1.0) for i in range(4)],
    "house": [(i, "k", 1.0) for i in range(4)] + [(i + 0.5, "h", 1.0) for i in range(4)] + [(1, "s", 0.8), (3, "s", 0.8)],
    "techno16": [(i, "k", 1.0) for i in range(4)] + [(i / 4, "h", 0.6) for i in range(16)],
    "breaks": [(0, "k", 1), (1, "s", 1), (1.75, "k", .8), (2.5, "k", 1), (3, "s", 1), (3.75, "s", .5)] + [(i / 2, "h", .5) for i in range(8)],
    "dnb": [(0, "k", 1), (1, "s", 1), (2.5, "k", 1), (3, "s", 1)] + [(i / 2, "h", .4) for i in range(8)],
}

DUR = 200.0

if __name__ == "__main__":
    print("== Resolution grid, plain 4/4 kick, default range 60-200 ==")
    for true in [120, 122, 124, 125, 126, 127, 128, 129, 130, 132, 134, 136, 138, 140]:
        y = render(true, DUR, PATTERNS["4x4 kick"])
        c, p = full_pipeline(y, DUR), full_pipeline_patched(y, DUR)
        print(f"true {true:5.1f}   current {c:6.1f} ({c-true:+5.1f})   patch01 {p:6.1f} ({p-true:+5.2f})")

    print("\n== Sweep: 40 random tempos 86-174 per pattern (seed 11) ==")
    r = np.random.default_rng(11)
    for name in ["4x4 kick", "house", "techno16"]:
        ts = np.round(r.uniform(86, 174, 40), 1)
        stats = {}
        for label, fn in (("current", full_pipeline), ("patch01", full_pipeline_patched)):
            errs, wrong, examples = [], 0, []
            for t in ts:
                v = fn(render(t, DUR, PATTERNS[name]), DUR)
                if abs(v - t) > 3:
                    wrong += 1
                    if len(examples) < 2: examples.append(f"{t}->{v}")
                else:
                    errs.append(abs(v - t))
            stats[label] = (np.mean(errs), np.max(errs), wrong, examples)
        c, p = stats["current"], stats["patch01"]
        print(f"{name:9s} current: mean {c[0]:.2f} max {c[1]:.2f} wrong-tempo {c[2]:2d} {c[3]} | "
              f"patch01: mean {p[0]:.2f} max {p[1]:.2f} wrong-tempo {p[2]:2d}")

    print("\n== DnB pattern (kick 1 + 3&, snare 2/4, 8th hats) ==")
    for t in [166, 168, 170, 172, 174, 176]:
        y = render(t, DUR, PATTERNS["dnb"])
        print(f"true {t}: default range current {full_pipeline(y, DUR):6.1f} patch01 {full_pipeline_patched(y, DUR):6.1f}"
              f" | D&B preset 160-195 current {full_pipeline(y, DUR, 160, 195):6.1f} patch01 {full_pipeline_patched(y, DUR, 160, 195):6.1f}")
