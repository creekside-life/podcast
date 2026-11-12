# Union of forced-aligned fillers from two Whisper runs (raw source and denoised audio). Whisper's filler recall
# drifts from run to run, so fillers one pass never transcribes are often caught by the other.
# Records within 0.35 s of each other are the same filler; the first file's record wins.
# usage: merge_fillers.py a.json b.json out.json
import json, sys
a, b = json.load(open(sys.argv[1])), json.load(open(sys.argv[2]))
out = list(a)
for r in b:
    if all(abs(r["start"] - x["start"]) > 0.35 for x in out):
        out.append(r)
out.sort(key=lambda r: r["start"])
json.dump(out, open(sys.argv[3], "w"), indent=1)
print(f"fillers: {len(a)} + {len(out) - len(a)} new from second pass = {len(out)}")
