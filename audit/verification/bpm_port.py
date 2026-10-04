"""1:1 port of GONE LibraryScanner BPM pipeline (quick vote + deep + normalize) for verification.

Mirrors LibraryScanner.swift: computeBPMFromSamples, windowVote, voteBPM, foldIntoPreferredRange,
normalizeDanceBPM, bpmFromSamples (deep), analyzeBPMDeep (quarters), and the auto-deep rule in
PlayerState+Analysis.analyzeBPMCompute. Float32 where Swift uses Float.
"""
import numpy as np

SR = 11025.0


def energy_onset(samples, hop):
    n = len(samples) // hop
    x = samples[: n * hop].astype(np.float32).reshape(n, hop)
    energy = (x * x).sum(axis=1, dtype=np.float32) / np.float32(hop)
    onset = np.zeros(n, dtype=np.float32)
    if n > 1:
        onset[1:] = np.maximum(0, energy[1:] - energy[:-1])
    return onset


def fold_pref(bpm, lo, hi):
    pl, ph = max(lo, 85.0), min(hi, 175.0)
    if not (pl < ph and bpm > 0):
        return bpm
    while bpm < pl and bpm * 2 <= hi:
        bpm *= 2
    while bpm > ph and bpm / 2 >= lo:
        bpm /= 2
    return bpm


def normalize_dance(v, floor, ceiling):
    if v <= 0:
        return v
    lo = max(floor, 1)
    hi = max(ceiling, lo + 1)
    bpm = v
    pl, ph = max(lo, 85.0), min(hi, 175.0)
    if pl < ph:
        while bpm < pl and bpm * 2 <= hi:
            bpm *= 2
        while bpm > ph and bpm / 2 >= lo:
            bpm /= 2
    return round(bpm * 10) / 10


def corr_values(onset, min_lag, max_lag, max_len):
    frame_count = len(onset)
    alen = min(frame_count - max_lag, max_len)
    ref = onset[:alen]
    cv = np.zeros(max_lag + 1, dtype=np.float32)
    for lag in range(min_lag, max_lag + 1):
        cv[lag] = np.float32(np.dot(ref, onset[lag: lag + alen])) / np.float32(alen)
    return cv


def compute_bpm_from_samples(samples, floor, ceiling, refine=None):
    hop = 128
    onset = energy_onset(samples, hop)
    frame_count = len(onset)
    fps = SR / hop
    min_lag = max(1, int(fps * 60.0 / max(ceiling, floor + 1)))
    max_lag = int(fps * 60.0 / max(floor, 1))
    if not (min_lag < max_lag and max_lag < frame_count):
        return 0.0
    cv = corr_values(onset, min_lag, max_lag, 4096)
    best_lag, best = min_lag, np.float32(0)
    for lag in range(min_lag, max_lag + 1):
        c = cv[lag]
        h2 = cv[lag * 2] * np.float32(0.35) if lag * 2 <= max_lag else 0
        h3 = cv[lag * 3] * np.float32(0.15) if lag * 3 <= max_lag else 0
        s = c + h2 + h3
        if s > best:
            best, best_lag = s, lag
    if best <= 0:
        return 0.0
    half = best_lag // 2
    if half >= min_lag and half <= max_lag and cv[half] >= best * np.float32(0.82):
        best_lag = half
    for num, den in [(4, 3), (3, 4), (2, 3), (3, 2)]:
        cand = best_lag * num // den
        if min_lag <= cand <= max_lag and cv[cand] > cv[best_lag] * np.float32(1.08):
            best_lag = cand
    period = float(best_lag)
    if refine is not None:
        period = refine(onset, best_lag)
    bpm = 60.0 * fps / period
    lo = max(floor, 1)
    hi = max(ceiling, lo + 1)
    while 0 < bpm < lo:
        bpm *= 2
    while bpm > hi:
        bpm /= 2
    bpm = fold_pref(bpm, lo, hi)
    return round(bpm * 10) / 10


def window_vote(sl, floor, ceiling, refine=None):
    wide = compute_bpm_from_samples(sl, floor, ceiling, refine)
    if not (floor <= 110 and ceiling >= 180 and wide > 0):
        return wide
    if 110 <= wide <= 180:
        return wide
    narrow = compute_bpm_from_samples(sl, 110, 180, refine)
    if narrow <= 0:
        return wide
    ratio = narrow / wide
    for t in [1.5, 4.0 / 3.0]:
        if abs(ratio - t) < 0.04:
            return narrow
    return wide


def vote_bpm(samples, dur, floor, ceiling, refine=None):
    win = 30.0
    if not dur > 70:
        start = 15.0 if dur > 50 else 0.0
        s = int(start * SR)
        e = min(len(samples), s + int(min(win, dur) * SR))
        return window_vote(samples[s:e] if s < e else samples, floor, ceiling, refine)
    votes = []
    for a in [0.25, 0.5, 0.75]:
        start = max(0, dur * a - win / 2)
        s = int(start * SR)
        e = min(len(samples), s + int(win * SR))
        if not s < e:
            continue
        v = window_vote(samples[s:e], floor, ceiling, refine)
        if v > 0:
            votes.append(v)
    if not votes:
        return 0.0
    votes.sort()
    if len(votes) >= 2:
        for i in range(len(votes) - 1):
            if votes[i + 1] - votes[i] <= votes[i] * 0.02:
                return round(((votes[i] + votes[i + 1]) / 2) * 10) / 10
    return round(votes[len(votes) // 2] * 10) / 10


def bpm_from_samples_deep(samples, floor, ceiling):
    hop = 64
    onset = energy_onset(samples, hop)
    frame_count = len(onset)
    fps = SR / hop
    wmin = max(1, int(fps * 60.0 / 280.0))
    wmax = int(fps * 60.0 / 30.0)
    if not (wmin < wmax and wmax < frame_count):
        return 0.0
    cv = corr_values(onset, wmin, wmax, 8192)
    best_lag, best = wmin, np.float32(0)
    for lag in range(wmin, wmax + 1):
        c = cv[lag]
        h2 = cv[lag * 2] * np.float32(0.35) if lag * 2 <= wmax else 0
        h3 = cv[lag * 3] * np.float32(0.15) if lag * 3 <= wmax else 0
        s = c + h2 + h3
        if s > best:
            best, best_lag = s, lag
    if best <= 0:
        return 0.0
    raw = cv[best_lag]
    for d in [2, 3]:
        cand = best_lag // d
        if cand < wmin:
            break
        if cv[cand] >= raw * np.float32(0.30):
            best_lag = cand
            break
    refined = float(best_lag)
    if wmin < best_lag < wmax:
        y0, y1, y2 = float(cv[best_lag - 1]), float(cv[best_lag]), float(cv[best_lag + 1])
        den = 2.0 * (y0 - 2.0 * y1 + y2)
        if den < -1e-10:
            delta = (y0 - y2) / den
            if -0.5 < delta < 0.5:
                refined = best_lag + delta
    bpm = 60.0 * fps / refined
    lo = max(floor, 1)
    hi = max(ceiling, lo + 1)
    while 0 < bpm < lo:
        bpm *= 2
    while bpm > hi:
        bpm /= 2
    return bpm if bpm > 0 else 0.0


def analyze_deep(samples, dur, floor, ceiling):
    if not dur > 8:
        return 0.0
    win = min(25.0, max(8.0, dur / 4.0))
    cands = []
    for q in range(4):
        start = dur * q / 4.0
        aw = min(win, dur - start)
        if aw < 6.0:
            continue
        s = int(start * SR)
        e = min(len(samples), s + int(aw * SR), s + 11025 * 20 + 4096)  # readBPMSamples caps ~20 s
        sl = samples[s:e]
        if len(sl) <= 11025:
            continue
        b = bpm_from_samples_deep(sl, floor, ceiling)
        if b > 0:
            cands.append(b)
    if not cands:
        return 0.0
    buckets = [round(c / 2.0) * 2.0 for c in cands]
    freq = {}
    for b in buckets:
        freq[b] = freq.get(b, 0) + 1
    wk, wv = max(freq.items(), key=lambda kv: kv[1])
    pool = [c for c, b in zip(cands, buckets) if b == wk] if wv > 1 else cands
    pool.sort()
    return round(pool[len(pool) // 2] * 10) / 10


def full_pipeline(samples, dur, floor=60, ceiling=200, refine=None):
    bpm = vote_bpm(samples, dur, floor, ceiling, refine)
    if bpm > 0 and floor < 80 and ceiling > 160 and (bpm < 95 or bpm > 145):
        deep = analyze_deep(samples, dur, floor, ceiling)
        if deep > 0:
            d = normalize_dance(deep, floor, ceiling)
            if abs(d - bpm) > 0.5:
                bpm = d
    return bpm


# ── Proposed refinement (patch 01): long-lag peak search ───────────────────────
def refine_multi_lag(onset, lag, max_beats=8):
    """Estimate the beat period from the autocorrelation peak near k*lag (k up to 8 beats),
    with parabolic sub-frame interpolation. Relative resolution improves by a factor of k."""
    n = len(onset)
    best_k = 1
    for k in range(max_beats, 0, -1):
        if k * lag + k + 2 < n // 2:
            best_k = k
            break
    k = best_k
    centre = k * lag
    radius = k  # integer lag may be off by <1 frame per beat → <k frames at k beats
    lo_l, hi_l = max(1, centre - radius - 1), centre + radius + 1
    alen = n - hi_l - 1
    if alen < 64:
        return float(lag)
    ref = onset[:alen]
    vals = {}
    for L in range(lo_l, hi_l + 1):
        vals[L] = float(np.dot(ref, onset[L: L + alen])) / alen
    peak = max(range(lo_l + 1, hi_l), key=lambda L: vals[L])
    y0, y1, y2 = vals[peak - 1], vals[peak], vals[peak + 1]
    den = (y0 - 2 * y1 + y2)
    delta = 0.5 * (y0 - y2) / den if den < -1e-12 else 0.0
    delta = max(-0.5, min(0.5, delta))
    return (peak + delta) / k



# ── Patch 01, ported: refined deep pass, strength-guarded rescue, 2 % deep-override tolerance ──
def _compute_with_strength(samples, floor, ceiling):
    hop = 128
    onset = energy_onset(samples, hop)
    n = len(onset)
    if n <= 1:
        return 0.0, 0.0
    fps = SR / hop
    min_lag = max(1, int(fps * 60.0 / max(ceiling, floor + 1)))
    max_lag = int(fps * 60.0 / max(floor, 1))
    if not (min_lag < max_lag < n):
        return 0.0, 0.0
    cv = corr_values(onset, min_lag, max_lag, 4096)
    best_lag, best = min_lag, np.float32(0)
    for lag in range(min_lag, max_lag + 1):
        s = cv[lag] + (cv[lag * 2] * np.float32(.35) if lag * 2 <= max_lag else 0) \
            + (cv[lag * 3] * np.float32(.15) if lag * 3 <= max_lag else 0)
        if s > best:
            best, best_lag = s, lag
    if best <= 0:
        return 0.0, 0.0
    half = best_lag // 2
    if min_lag <= half <= max_lag and cv[half] >= best * np.float32(.82):
        best_lag = half
    for num, den in [(4, 3), (3, 4), (2, 3), (3, 2)]:
        c = best_lag * num // den
        if min_lag <= c <= max_lag and cv[c] > cv[best_lag] * np.float32(1.08):
            best_lag = c
    bpm = 60 * fps / refine_multi_lag(onset, best_lag)
    lo = max(floor, 1); hi = max(ceiling, lo + 1)
    while 0 < bpm < lo: bpm *= 2
    while bpm > hi: bpm /= 2
    return round(fold_pref(bpm, lo, hi) * 10) / 10, float(cv[best_lag])


def _window_vote_patched(sl, floor, ceiling):
    wide, ws = _compute_with_strength(sl, floor, ceiling)
    if not (floor <= 110 and ceiling >= 180 and wide > 0): return wide
    if 110 <= wide <= 180: return wide
    narrow, ns = _compute_with_strength(sl, 110, 180)
    if narrow <= 0: return wide
    if ns < 0.5 * ws: return wide
    r = narrow / wide
    for t in [1.5, 4 / 3]:
        if abs(r - t) < 0.04: return narrow
    return wide


def _deep_refined(samples, floor, ceiling):
    hop = 64
    onset = energy_onset(samples, hop)
    n = len(onset); fps = SR / hop
    wmin = max(1, int(fps * 60.0 / 280.0)); wmax = int(fps * 60.0 / 30.0)
    if not (wmin < wmax < n): return 0.0
    cv = corr_values(onset, wmin, wmax, 8192)
    best_lag, best = wmin, np.float32(0)
    for lag in range(wmin, wmax + 1):
        s = cv[lag] + (cv[lag * 2] * np.float32(.35) if lag * 2 <= wmax else 0) \
            + (cv[lag * 3] * np.float32(.15) if lag * 3 <= wmax else 0)
        if s > best: best, best_lag = s, lag
    if best <= 0: return 0.0
    raw = cv[best_lag]
    for d in [2, 3]:
        c = best_lag // d
        if c < wmin: break
        if cv[c] >= raw * np.float32(0.30): best_lag = c; break
    bpm = 60.0 * fps / refine_multi_lag(onset, best_lag)
    lo = max(floor, 1); hi = max(ceiling, lo + 1)
    while 0 < bpm < lo: bpm *= 2
    while bpm > hi: bpm /= 2
    return bpm if bpm > 0 else 0.0


def full_pipeline_patched(samples, dur, floor=60, ceiling=200):
    global window_vote, bpm_from_samples_deep
    saved = (window_vote, bpm_from_samples_deep)
    window_vote = lambda sl, f, c, refine=None: _window_vote_patched(sl, f, c)
    bpm_from_samples_deep = _deep_refined
    try:
        bpm = vote_bpm(samples, dur, floor, ceiling)
        if bpm > 0 and floor < 80 and ceiling > 160 and (bpm < 95 or bpm > 145):
            deep = analyze_deep(samples, dur, floor, ceiling)
            if deep > 0:
                d = normalize_dance(deep, floor, ceiling)
                if abs(d - bpm) > max(0.5, bpm * 0.02):
                    bpm = d
        return bpm
    finally:
        window_vote, bpm_from_samples_deep = saved
