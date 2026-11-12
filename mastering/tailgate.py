# Speech-keyed downward expander that pulls the room down right behind each word.
# usage: tailgate.py in.wav out.wav [--below 26] [--range 20] [--ratio 4] [--hold 40] [--release 30] [--lookahead 60]
#
# After the live Waves dereverb the feed is fairly dry; what still sounds like "room" is the auditorium's
# ambience floor, ~30 dB under the voice, which DeepFilterNet only eases down over ~300 ms. This clamps it
# within ~100 ms of every word end, safely for speech:
#   - threshold sits --below dB under this recording's loud-speech level (p90 of 5 ms frames)
#   - 60 ms lookahead: the gain is fully open before a word starts, so soft onsets ("th", "f") survive
#   - --hold ms after the level drops before closing, so soft word endings ("-s", "-th") survive
#   - closes with a --release ms time constant, by at most --range dB, ratio-style (deeper under = more cut)
import argparse, numpy as np, soundfile as sf
from scipy.ndimage import maximum_filter1d

ap = argparse.ArgumentParser()
ap.add_argument("inp"); ap.add_argument("out")
# Defaults are the verified setting. Tighter ones failed the word check: a threshold 20 dB under speech
# turned a soft "that" into "it", and 10 ms lookahead shaved the "th" off phrase-initial "that's". Hold and
# range were 40 ms / 20 dB until a blind A/B: Auphonic won 2-1 for sounding less sucked-dry, so words now keep
# 13 ms more of their natural tail and the room comes down 15% less.
ap.add_argument("--below", type=float, default=26); ap.add_argument("--range", type=float, default=17)
ap.add_argument("--ratio", type=float, default=4); ap.add_argument("--hold", type=float, default=53)
ap.add_argument("--release", type=float, default=30); ap.add_argument("--lookahead", type=float, default=60)
ap.add_argument("--save-gain", help="write the per-5 ms gain in dB (.npy) for auditing")
a = ap.parse_args()

x, sr = sf.read(a.inp, dtype="float64"); x = x if x.ndim == 1 else x.mean(1)
hop = sr // 200  # 5 ms
n = len(x) // hop
db = 10 * np.log10((x[: n * hop].reshape(n, hop) ** 2).mean(1) + 1e-12)
thr = np.percentile(db, 90) - a.below
# Look ahead and hold: the detector sees the loudest frame from lookahead before to hold after.
ahead, hold = int(round(a.lookahead / 5)), int(round(a.hold / 5))
det = maximum_filter1d(db, size=ahead + hold + 1, origin=(hold - ahead) // 2)
target = np.clip((det - thr) * (a.ratio - 1), -a.range, 0)  # dB, 0 when open
# Opening is instant (lookahead already covers onsets); closing follows a one-pole release.
g = np.empty(n); k = np.exp(-5 / a.release); cur = 0.0
for i in range(n):
    cur = target[i] if target[i] > cur else k * cur + (1 - k) * target[i]
    g[i] = cur
if a.save_gain:
    np.save(a.save_gain, g)
gain = np.interp(np.arange(len(x)), np.arange(n) * hop + hop / 2, 10 ** (g / 20))
sf.write(a.out, (x * gain).astype(np.float32), sr, subtype="FLOAT")
print(f"{a.out}: threshold {thr:.1f} dBFS, mean reduction {-(g[g < -0.5]).mean() if (g < -0.5).any() else 0:.1f} dB "
      f"on {(g < -0.5).mean() * 100:.0f}% of frames")
