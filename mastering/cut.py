# Shorten long pauses and remove filler words ("um", "uh") from a processed mono wav.
#
# usage: cut.py in.wav whisper.json out.wav [--offset SECONDS] [--no-fillers]
#   whisper.json is whisper.cpp -ojf output (ideally with -nfa -dtw); --offset maps an excerpt into it.
# Writes out.wav plus out.cuts.json (kept spans in input time) so transcripts and chapters can be remapped.
#
# Whisper only locates a filler; the audio decides what gets cut. DTW onsets run 0.1-0.2 s late, so a
# cut on raw timestamps clips the next word. Instead a filler is the short island of sound nearest its
# onset, accepted only when silence brackets it and no real word starts inside it. The island is then
# treated as silence, so "word, uh, word" becomes one pause that the pause rule shortens like any other.
import argparse, json, re, numpy as np, soundfile as sf

ap = argparse.ArgumentParser()
ap.add_argument("inp"); ap.add_argument("asr"); ap.add_argument("out")
ap.add_argument("--offset", type=float, default=0.0)
ap.add_argument("--no-fillers", action="store_true")
ap.add_argument("--min-pause", type=float, default=1.0, help="plain pauses longer than this get shortened")
ap.add_argument("--keep-pause", type=float, default=0.7, help="base length a long pause shrinks to")
ap.add_argument("--max-pause", type=float, default=1.1, help="longest a pause may stay")
ap.add_argument("--filler-pause", type=float, default=0.45, help="pause left where a filler was")
ap.add_argument("--quiet-db", type=float, default=35, help="frames this far below loud speech count as silence")
ap.add_argument("--lag", type=float, default=0.12, help="how late Whisper DTW onsets run")
ap.add_argument("--aligned", help="falign.py output: forced-alignment bounds for fillers fused to a word")
a = ap.parse_args()

x, sr = sf.read(a.inp); x = x if x.ndim == 1 else x.mean(1)
hop = sr // 100
n = len(x) // hop
db = 10 * np.log10(np.add.reduceat(x[: n * hop] ** 2, np.arange(0, n * hop, hop)) / hop + 1e-12)
speech_level = np.percentile(db, 90)
quiet = db < speech_level - a.quiet_db
quiet = np.append(quiet, True)  # sentinel so runs close at the end

def runs(mask):
    """(start_frame, end_frame) for each run of True."""
    d = np.diff(np.concatenate([[0], mask.astype(int), [0]]))
    return list(zip(np.flatnonzero(d == 1), np.flatnonzero(d == -1)))

# Whole words with onsets. Only a token with a leading space starts a word: "Mic"+"ah" is Micah.
words = []
for seg in json.load(open(a.asr))["transcription"]:
    for t in seg["tokens"]:
        txt = t["text"]
        if txt.startswith("[_") or not txt.strip():
            continue
        on = (t["t_dtw"] / 100 if t.get("t_dtw", -1) >= 0 else t["offsets"]["from"] / 1000) - a.offset - a.lag
        if txt.startswith(" ") or not words:
            words.append([on, txt.strip()])
        else:
            words[-1][1] += txt
FILLER = re.compile(r"^\W*(u+m+|u+h+|e+r+m*|a+h+|h+m+|m+h*m+)\W*$", re.I)
real_onsets = np.array([s for s, w in words if not FILLER.match(w)])

# Fillers -> spans of sound, with safety checks; accepted spans become silence.
# Sub-60 ms blips (clicks, a stray consonant release) count as silence first, or they split pauses
# and pose as fillers.
for f0, f1 in runs(~quiet[:-1]):
    if f1 - f0 < 6:
        quiet[f0:f1] = True
islands = runs(~quiet[:-1])
starts = np.array([s for s, _ in islands]) / 100
ends = np.array([e for _, e in islands]) / 100
fillers, skipped = [], []

def island_at(t):
    """Island holding onset t (onsets can land a little before the sound starts), else None."""
    hit = np.flatnonzero((starts - 0.15 <= t) & (t <= ends))
    return int(hit[0]) if len(hit) else None

def dip_split(i, lead):
    """A filler fused to a neighbouring word: split island i at its deepest dip, which must sit at
    least 12 dB under the island's median. lead=True means the filler opens the island."""
    f0, f1 = islands[i]
    lo, hi = (f0 + 8, min(f1 - 8, f0 + 80)) if lead else (max(f0 + 8, f1 - 80), f1 - 8)
    if hi <= lo:
        return None
    d = lo + int(np.argmin(db[lo:hi]))
    if db[d] > np.median(db[f0:f1]) - 12:
        return None
    return (f0, d) if lead else (d, f1)

aligned = json.load(open(a.aligned)) if a.aligned else []

def quietest(lo, hi):
    lo, hi = max(0, int(lo * 100)), min(n, int(hi * 100))
    return lo + int(np.argmin(db[lo:hi])) if hi > lo else None

def aligned_cut(rec):
    """Cut span for a filler located by forced alignment. CTC is peaky: it marks where each letter
    fires, not how long the sound lasts, so it decides WHICH sound is the filler (the one holding its
    centre) and roughly where neighbours begin and end; the audio decides the edges. A gap between
    words often holds a breath too, which is why picking 'the island between the neighbours' cut
    breaths and left the "uh" on a full sermon."""
    c = (rec["start"] + rec["end"]) / 2
    hit = np.flatnonzero((starts - 0.03 <= c) & (c <= ends + 0.03))
    if not len(hit):
        # The letter spikes can land in the gap beside the "uh": take the nearest sound within 150 ms,
        # as long as it sits between the neighbouring words.
        near = np.flatnonzero((ends >= c - 0.15) & (starts <= c + 0.15))
        if rec["prev_end"] is not None:
            near = near[starts[near] >= rec["prev_end"] - 0.03]
        if rec["next_start"] is not None:
            near = near[ends[near] <= rec["next_start"] + 0.03]
        if not len(near):
            return None, "no sound at aligned centre"
        hit = near[np.argsort(np.minimum(np.abs(starts[near] - c), np.abs(ends[near] - c)))]
    f0, f1 = islands[int(hit[0])]
    pe, ns = rec["prev_end"], rec["next_start"]
    # A fused edge needs a real transition: a dip at least 3 dB under the filler's own peak. (The
    # island median is the wrong yardstick: it includes the louder word the filler is fused to.)
    peak = db[int(rec["start"] * 100): int(rec["end"] * 100) + 1].max()
    fused_before = pe is not None and pe > f0 / 100 + 0.03
    fused_after = ns is not None and ns < f1 / 100 - 0.03
    if fused_before:
        g = quietest(pe - 0.01, rec["start"] + 0.03)
        if g is None or db[g] > peak - 3:
            return None, "fused to previous word, no dip"
        f0 = g
    if fused_after:
        g = quietest(ns - 0.08, ns + 0.01)  # reaching past the aligned onset clipped "he" and "there's"
        if g is None or db[g] > peak - 3:
            return None, "fused to next word, no dip"
        f1 = g
    if pe is not None and f0 < pe * 100 - 2:
        return None, "would clip previous word"
    if ns is not None and f1 > ns * 100 + 2:
        return None, "would clip next word"
    # A drawn-out "uhhhh" with silence on both sides and no word inside can run long; fused ones can't.
    longest = 150 if not (fused_before or fused_after) else 80
    if not 8 <= f1 - f0 <= longest:
        return None, f"span {(f1 - f0) / 100:.2f}s"
    return (f0, f1), None

def nonfiller(j_range):
    return next((words[j][0] for j in j_range if not FILLER.match(words[j][1])), None)

if not a.no_fillers and aligned:
    # Forced alignment is the locator; Whisper's own timestamps only found the neighbourhood.
    for rec in aligned:
        span, why = aligned_cut(rec)
        if why:
            skipped.append((round(rec["start"], 2), rec["word"], why))
        else:
            fillers.append((span[0], span[1], rec["word"]))
            quiet[span[0]:span[1]] = True
elif not a.no_fillers:
    # Without alignment: the lone island between neighbouring real words, or a dip split.
    for k, (s, w) in enumerate(words):
        if not FILLER.match(w) or not len(islands):
            continue
        prev, nxt = nonfiller(range(k - 1, -1, -1)), nonfiller(range(k + 1, len(words)))
        ip = island_at(prev) if prev is not None else None
        iq = island_at(nxt) if nxt is not None else None
        span = None
        if ip is not None and iq is not None and iq - ip >= 2:
            i = min(range(ip + 1, iq), key=lambda j: abs(starts[j] - s))
            span = islands[i]
        elif ip is not None and iq is not None and iq == ip + 1:
            span = dip_split(iq, lead=True) if abs(starts[iq] - s) < abs(ends[ip] - s) else dip_split(ip, lead=False)
        why = None
        if span is None:
            why = "fused mid-phrase, no dip" if ip is not None and iq is not None else "neighbours not located"
        else:
            t0, t1 = span[0] / 100, span[1] / 100
            if not 0.08 <= t1 - t0 <= 0.8: why = f"span {t1 - t0:.2f}s"
            elif ((real_onsets > t0 + 0.04) & (real_onsets < t1 - 0.04)).any(): why = "real word inside"
        if why:
            skipped.append((round(s, 2), w, why))
        else:
            fillers.append((span[0], span[1], w))
            quiet[span[0]:span[1]] = True

# Pauses: every quiet run (now including former fillers) longer than its allowance gets shortened.
# Fillers keep silence from both sides so the cut always spans the whole island.
cuts = []
for r0, r1 in runs(quiet):
    L = (r1 - r0) / 100
    inside = [f for f in fillers if r0 <= f[0] and f[1] <= r1]
    if inside:
        sil = L - sum(f[1] - f[0] for f in inside) / 100
        keep = min(sil, max(a.filler_pause, min(a.max_pause, a.keep_pause + 0.15 * (sil - a.keep_pause))))
        pre = (inside[0][0] - r0) / 100
        post = (r1 - inside[-1][1]) / 100
        k1 = min(pre, keep / 2); k2 = min(post, keep - k1); k1 = min(pre, keep - k2)
        cuts.append((r0 / 100 + k1, r1 / 100 - k2, "filler " + ",".join(f[2] for f in inside) + f" ({L:.2f}s gap)"))
    elif L > a.min_pause:
        keep = min(a.max_pause, a.keep_pause + 0.15 * (L - a.keep_pause))
        mid = (r0 + r1) / 200
        cuts.append((mid - (L - keep) / 2, mid + (L - keep) / 2, f"pause {L:.2f}s"))
cuts = [c for c in cuts if c[1] - c[0] >= 0.06]

# Render with 25 ms equal-power crossfades, which sit inside the kept silence.
fade = int(0.025 * sr)
ramp = np.sin(np.linspace(0, np.pi / 2, fade)) ** 2
out, kept, pos = [], [], 0
loud = lambda t: db[min(int(t * 100), n - 1)] > speech_level - a.quiet_db
for s, e, _ in cuts:
    fade = int((0.008 if loud(s) or loud(e) else 0.025) * sr)
    ramp = np.sin(np.linspace(0, np.pi / 2, fade)) ** 2
    si, ei = int(s * sr), int(e * sr)
    if si - fade <= pos:
        continue
    # A kept span runs to the cut start; its last fade samples become the crossfade, and the next span
    # resumes fade samples past the cut end, so output time is just the sum of kept span lengths.
    out.append(x[pos:si - fade]); kept.append((pos / sr, si / sr))
    out.append(x[si - fade:si] * ramp[::-1] + x[ei:ei + fade] * ramp)
    pos = ei + fade
out.append(x[pos:]); kept.append((pos / sr, len(x) / sr))
y = np.concatenate(out)
sf.write(a.out, y, sr, subtype="PCM_16")
json.dump({"kept": kept, "cuts": cuts, "skipped_fillers": skipped},
          open(a.out.rsplit(".", 1)[0] + ".cuts.json", "w"), indent=1)
n_f = sum(c[2].startswith("filler") for c in cuts)
print(f"{a.out}: {len(x)/sr:.1f}s -> {len(y)/sr:.1f}s, cut {len(x)/sr - len(y)/sr:.1f}s "
      f"({len(cuts) - n_f} pauses shortened, {len(fillers)} fillers removed, {len(skipped)} fillers kept)")
