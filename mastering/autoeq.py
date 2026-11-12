# Adaptive EQ toward a target long-term spectrum, the local stand-in for Auphonic's AutoEQ.
# usage: autoeq.py in.wav target.json  -> prints an ffmpeg firequalizer filter for this recording
# target.json is the averaged 1/3-octave spectrum of past Auphonic outputs (500 Hz-1.6 kHz normalised, speech
# frames only), so each speaker gets pulled toward the tonal balance listeners already know from the feed.
# Voices differ by up to ~14 dB above 4 kHz from the target, so corrections run to 16 kHz with a 12 dB cap: a
# 6 dB cap that stopped at 8 kHz left bright voices harsh.
import json, os, sys, numpy as np, soundfile as sf
from scipy.signal import welch

x, sr = sf.read(sys.argv[1]); x = x if x.ndim == 1 else x.mean(1)
t = json.load(open(sys.argv[2])); cents, target = np.array(t["cents"]), np.array(t["target"])
spread = np.array(t.get("spread", [1.0] * len(cents)))
# Only sound counts: pauses would drag the measured spectrum toward room tone.
hop = sr // 10
fr = x[: len(x) // hop * hop].reshape(-1, hop)
lev = 10 * np.log10((fr ** 2).mean(1) + 1e-12)
speech = fr[lev > np.percentile(lev, 90) - 25].ravel()
f, P = welch(speech, sr, nperseg=8192)
have = np.array([P[(f >= c / 2 ** (1 / 6)) & (f < c * 2 ** (1 / 6))].mean() for c in cents])
have = 10 * np.log10(have + 1e-20)
ref = (cents >= 500) & (cents <= 1600)
have -= np.median(have[ref])
corr = target - have
corr = np.convolve(np.pad(corr, 1, mode="edge"), np.ones(3) / 3, mode="valid")  # smooth over neighbours
# Trust the target less where past episodes disagree (10-12.5 kHz varies with each source's bandwidth).
corr *= np.clip(3.0 / np.maximum(spread, 1e-6), 0.3, 1.0)
cap = float(os.environ.get("AEQ_MAX", 12))  # dB, per band
corr = np.where((cents >= 100) & (cents <= 16000), np.clip(corr, -cap, cap), 0.0)
# Hold the top band's correction to Nyquist: snapping back to 0 dB above it left a bright "air" bump.
entries = ";".join(f"entry({c},{g:.2f})" for c, g in zip(cents, corr))
print(f"firequalizer=gain_entry='entry(0,0);{entries};entry(24000,{corr[-1]:.2f})'")
print(" ".join(f"{c}:{g:+.1f}" for c, g in zip(cents, corr)), file=sys.stderr)
