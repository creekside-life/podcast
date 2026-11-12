# Room tail (level 100 ms after word ends, dB re the word) and DNSMOS P.835/P.808 over 10 s chunks.
# usage: score_dnsmos.py file...   columns: tail SIG BAK OVRL P808 (higher is better except tail)
import sys, subprocess, numpy as np, librosa
from speechmos import dnsmos
SR = 48000
def load(p):
    r = subprocess.run(["ffmpeg", "-v", "error", "-i", p, "-ac", "1", "-ar", str(SR), "-f", "f32le", "-"], capture_output=True, check=True)
    return np.frombuffer(r.stdout, np.float32).astype(np.float64)
def room_tail(x):
    y = librosa.resample(x, orig_sr=SR, target_sr=16000); hop = 80; n = len(y) // hop
    db = 10 * np.log10((y[: n * hop].reshape(n, hop) ** 2).mean(1) + 1e-12); sl = np.percentile(db, 90)
    ev = [db[i + 20] - db[i] for i in range(10, n - 80)
          if db[i] >= sl - 15 and db[i + 1] < db[i] and db[i + 10:i + 70].max() < sl - 25 and db[i - 10:i].min() > sl - 25]
    return float(np.median(ev))
def mos(x):
    y = np.clip(librosa.resample(x, orig_sr=SR, target_sr=16000), -1, 1)
    segs = [dnsmos.run(y[i:i + 160000], 16000) for i in range(0, len(y) - 160000, 160000)]
    return [np.mean([s[k] for s in segs]) for k in ("sig_mos", "bak_mos", "ovrl_mos", "p808_mos")]
print(f"{'':22}{'tail':>7}{'SIG':>7}{'BAK':>7}{'OVRL':>7}{'P808':>7}")
for p in sys.argv[1:]:
    x = load(p); print(f"{p.split('/')[-1][:22]:22}{room_tail(x):7.1f}" + "".join(f"{v:7.3f}" for v in mos(x)), flush=True)
