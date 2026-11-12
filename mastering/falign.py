# Exact filler boundaries by CTC forced alignment (torchaudio MMS_FA), run only on a few seconds of
# context around each filler Whisper found, so a sermon costs seconds rather than a full pass.
# usage: falign.py audio16k.wav asr.json out.json
# out.json: [{"word", "start", "end", "score", "prev_end", "next_start"}], seconds in the source timeline.
import json, re, sys, soundfile as sf, torch
from torchaudio.pipelines import MMS_FA as bundle

x, sr = sf.read(sys.argv[1], dtype="float32")
wav = torch.from_numpy(x if x.ndim == 1 else x.mean(1)).unsqueeze(0)
assert sr == bundle.sample_rate, "expects 16 kHz mono"
model, tok, align = bundle.get_model(with_star=False), bundle.get_tokenizer(), bundle.get_aligner()
model.eval()

words = []
for seg in json.load(open(sys.argv[2]))["transcription"]:
    for t in seg["tokens"]:
        txt = t["text"]
        if txt.startswith("[_") or not txt.strip():
            continue
        on = (t["t_dtw"] / 100 if t["t_dtw"] >= 0 else t["offsets"]["from"] / 1000) - 0.12
        if txt.startswith(" ") or not words:
            words.append([on, txt.strip()])
        else:
            words[-1][1] += txt
FILLER = re.compile(r"^\W*(u+m+|u+h+|e+r+m*|a+h+|h+m+)\W*$", re.I)
NUM = {"0": "zero", "1": "one", "2": "two", "3": "three", "4": "four", "5": "five", "6": "six",
       "7": "seven", "8": "eight", "9": "nine"}
def norm(w):
    w = re.sub(r"\d", lambda m: NUM[m.group()], w.lower())
    return re.sub(r"[^a-z']", "", w).replace("'", "")

out = []
for k, (s, w) in enumerate(words):
    if not FILLER.match(w):
        continue
    lo, hi = max(0, k - 2), min(len(words), k + 3)
    ctx = [(i, norm(words[i][1])) for i in range(lo, hi)]
    ctx = [(i, x) for i, x in ctx if x]
    t0 = max(0.0, words[lo][0] - 0.4)
    t1 = (words[hi][0] if hi < len(words) else words[-1][0] + 1.5) + 0.1
    if t1 - t0 > 8:  # timestamps gone wrong; skip rather than align garbage
        continue
    clip = wav[:, int(t0 * sr): int(t1 * sr)]
    with torch.inference_mode():
        em, _ = model(clip)
    spans = align(em[0], tok([x for _, x in ctx]))
    fr = clip.size(1) / em.size(1) / sr
    pos = [i for i, _ in ctx].index(k)
    sp = spans[pos]
    rec = {"word": w, "start": round(t0 + sp[0].start * fr, 3), "end": round(t0 + sp[-1].end * fr, 3),
           "score": round(float(sum(x.score * (x.end - x.start) for x in sp) / sum(x.end - x.start for x in sp)), 3),
           "prev_end": round(t0 + spans[pos - 1][-1].end * fr, 3) if pos > 0 else None,
           "next_start": round(t0 + spans[pos + 1][0].start * fr, 3) if pos + 1 < len(spans) else None,
           "context": " ".join(x for _, x in ctx)}
    out.append(rec)
json.dump(out, open(sys.argv[3], "w"), indent=1)
for r in out:
    gp = r["start"] - r["prev_end"] if r["prev_end"] is not None else -1
    gn = r["next_start"] - r["end"] if r["next_start"] is not None else -1
    print(f"{r['start']:8.2f}-{r['end']:8.2f}s {r['word']:6} score {r['score']:.2f}  gap before {gp:5.2f} after {gn:5.2f} | {r['context']}")
