# NISQA (MOS, noisiness, coloration, discontinuity) and torchaudio SQUIM (reference-free STOI / PESQ / SI-SDR),
# averaged over 10 s chunks. Higher is better in every column.
# usage: score_nisqa.py file...   (weights: $NISQA_WEIGHTS, default ~/.cache/creekside-podcast/nisqa.tar)
import os, sys, subprocess, tempfile, numpy as np, soundfile as sf, torch, torchaudio
from nisqa.NISQA_model import nisqaModel
from torchaudio.pipelines import SQUIM_OBJECTIVE

squim = SQUIM_OBJECTIVE.get_model().eval()
def load(p, sr):
    r = subprocess.run(["ffmpeg", "-v", "error", "-i", p, "-ac", "1", "-ar", str(sr), "-f", "f32le", "-"], capture_output=True, check=True)
    return np.frombuffer(r.stdout, np.float32).copy()
print(f"{'':24}{'NISQA':>7}{'noise':>7}{'colour':>7}{'discont':>8}{'STOI':>7}{'PESQ':>7}{'SI-SDR':>8}")
import pyloudnorm as pyln
def at17(x, sr):
    """NISQA moves with playback level (a pure gain from -25 to -17 LUFS shifts it ~0.15), so every file is
    scored at -17 LUFS (float gain, no clipping) and builds compare fairly."""
    I = pyln.Meter(sr).integrated_loudness(x.astype(np.float64))
    return (x * 10 ** ((-17 - I) / 20)).astype(np.float32)
for p in sys.argv[1:]:
    x48 = at17(load(p, 48000), 48000); x16 = at17(load(p, 16000), 16000)
    with tempfile.TemporaryDirectory() as d:
        k = 0
        for i in range(0, len(x48) - 480000, 480000):
            c = x48[i:i + 480000]
            if np.sqrt(np.mean(c ** 2)) < 1e-3: continue
            sf.write(f"{d}/c{k:04d}.wav", c, 48000); k += 1
        args = {"mode": "predict_dir", "pretrained_model": os.environ.get("NISQA_WEIGHTS", os.path.expanduser("~/.cache/creekside-podcast/nisqa.tar")), "data_dir": d,
                "output_dir": None, "num_workers": 0, "bs": 8, "ms_channel": None}
        import contextlib, io
        with contextlib.redirect_stdout(io.StringIO()):
            nm = nisqaModel(args); df = nm.predict()
    sq = []
    with torch.inference_mode():
        for i in range(0, len(x16) - 160000, 160000):
            c = torch.from_numpy(x16[i:i + 160000])[None]
            if c.pow(2).mean().sqrt() < 1e-3: continue
            sq.append([float(v) for v in squim(c)])
    sq = np.array(sq).mean(0)
    print(f"{p.split('/')[-1][:24]:24}{df.mos_pred.mean():7.3f}{df.noi_pred.mean():7.3f}{df.col_pred.mean():7.3f}{df.dis_pred.mean():8.3f}"
          f"{sq[0]:7.3f}{sq[1]:7.3f}{sq[2]:8.2f}", flush=True)
