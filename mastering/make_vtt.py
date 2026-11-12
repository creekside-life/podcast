# Build a WebVTT transcript for the FINAL (cut) audio from the Whisper run on the original.
# usage: make_vtt.py asr.json cuts.json out.vtt [out.txt]
# Times go through cut.py's kept spans, so cues line up with the published mp3. Fillers are dropped
# from the text ("clean verbatim"), which is what podcast apps display.
import json, re, sys

asr, cuts, out = sys.argv[1:4]
kept = json.load(open(cuts))["kept"]

def to_out(t):
    acc = 0.0
    for s, e in kept:
        if t < s:
            return acc  # inside a cut: snap to the splice
        if t < e:
            return acc + t - s
        acc += e - s
    return acc

FILLER = re.compile(r"(?i)(^|\s)(u+m+|u+h+|e+r+m*|a+h+|h+m+)[,.]?(?=\s|$)")
def clean(t):
    # Cues often start mid-sentence, so only re-capitalise when a sentence-opening filler was dropped.
    opened = bool(re.match(r"\s*(u+m+|u+h+|e+r+m*|a+h+|h+m+)\b", t, re.I)) and t.strip()[:1].isupper()
    t = FILLER.sub(" ", t)
    t = re.sub(r"\s+", " ", t).strip()
    t = re.sub(r"^,\s*", "", t)
    return t[:1].upper() + t[1:] if t and opened else t

def ts(t):
    h, r = divmod(t, 3600); m, s = divmod(r, 60)
    return f"{int(h):02d}:{int(m):02d}:{s:06.3f}"

cues = []
for seg in json.load(open(asr))["transcription"]:
    text = clean(seg["text"])
    if not text:
        continue
    a, b = to_out(seg["offsets"]["from"] / 1000), to_out(seg["offsets"]["to"] / 1000)
    if b - a < 0.3:
        continue
    cues.append((a, b, text))

with open(out, "w") as f:
    f.write("WEBVTT\n\n")
    for i, (a, b, t) in enumerate(cues, 1):
        f.write(f"{i}\n{ts(a)} --> {ts(b)}\n{t}\n\n")
if len(sys.argv) > 4:
    open(sys.argv[4], "w").write("\n".join(t for *_, t in cues) + "\n")  # one cue per line, like the old .en.txt
print(f"{out}: {len(cues)} cues")
