#!/bin/bash
# master.sh in.m4a out.mp3 "Title"
# Local, open-source replacement for auphonic.sh: dereverb, denoise, level, cut pauses and fillers, EQ, loudness,
# MP3. Also writes the episode's transcript (out.en.txt, from Whisper, timed edits removed) and its scores
# (out.mastering.json).
#
# Every episode is built twice, without and with a high-band compressor, because the compressor helps some
# voices and hurts others. Both builds are scored locally on three independent speech-quality predictors
# (DNSMOS overall, NISQA, SQUIM PESQ), and the one with the larger summed gain wins. Each change is scaled by
# that metric's usual spread (0.05 / 0.1 / 0.2) so one tiny gain can't outvote a big loss.
#
# Like auphonic.sh, it skips an episode that already has an mp3, reuses the mp3 of an earlier download of the
# same video, and keeps an existing .au file as the episode's GUID (the feed's <guid> comes from it). A new
# episode gets "creekside-<video id>", stable across rebuilds.
set -euo pipefail
L="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$L/.." && pwd)"
C="${CREEKSIDE_CACHE:-$HOME/.cache/creekside-podcast}"
in=$1; out=$2; title=$3
base="${out%.mp3}"
au="${in%.*}.au"

if [ -f "$out" ]; then
  echo "Mastering skipping: $out already exists"
  exit 0
fi
video_id=$(basename "$base" | gsed 's/^[0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}-//')
existing=$(find "$(dirname "$out")" -maxdepth 1 -type f -name "*-$video_id.mp3" ! -path "$out" | head -n 1)
if [ -n "$existing" ]; then
  echo "Mastering skipping: $out is the same video as $existing"
  cp "$existing" "$out"
  [ -f "${existing%.mp3}.au" ] && cp "${existing%.mp3}.au" "$au"
  [ -f "${existing%.mp3}.en.txt" ] && cp "${existing%.mp3}.en.txt" "$base.en.txt"
  exit 0
fi
if [ ! -f "$in" ]; then
  echo "Mastering skipping: $in does not exist"
  exit 1
fi

"$L/setup.sh"
w="$ROOT/.work/$(basename "$base")"
echo "Mastering locally: $(basename "$in") ($title), about 25 min..."
t0=$(date +%s)
for hfc in 0 1; do
  HFC=$hfc "$L/render.sh" "$in" "$w" "$w/hfc$hfc.mp3" "$title"
done
"$C/core/bin/python" -I "$L/score_dnsmos.py" "$w/hfc0.mp3" "$w/hfc1.mp3" 2> /dev/null | tail -2 > "$w/dnsmos.txt"
NISQA_WEIGHTS="$C/nisqa.tar" "$C/nisqa/bin/python" -I "$L/score_nisqa.py" "$w/hfc0.mp3" "$w/hfc1.mp3" 2> /dev/null \
  | tail -2 > "$w/nisqa.txt"
pick=$("$C/core/bin/python" -I - "$w" "$base.mastering.json" <<'EOF'
import json, sys
w, report = sys.argv[1], sys.argv[2]
d = [l.split() for l in open(f"{w}/dnsmos.txt")]  # name tail SIG BAK OVRL P808
n = [l.split() for l in open(f"{w}/nisqa.txt")]   # name NISQA noise colour discont STOI PESQ SI-SDR
score = {v: {"dnsmos_ovrl": float(d[v][4]), "nisqa": float(n[v][1]), "squim_pesq": float(n[v][6]),
             "room_tail_db": float(d[v][1]), "nisqa_coloration": float(n[v][3])} for v in (0, 1)}
scale = {"dnsmos_ovrl": 0.05, "nisqa": 0.1, "squim_pesq": 0.2}
gain = sum((score[1][k] - score[0][k]) / scale[k] for k in scale)
pick = 1 if gain > 0 else 0
json.dump({"high_band_compressor": bool(pick), "scaled_gain": round(gain, 2), "builds": score}, open(report, "w"),
          indent=1)
print(pick)
EOF
)
cp "$w/hfc$pick.mp3" "$out"
"$C/core/bin/python" -I "$L/make_vtt.py" "$w/asr.json" "$w/hfc$pick.cuts.json" "$w/transcript.vtt" "$base.en.txt" \
  > /dev/null
[ -s "$au" ] || echo "creekside-$video_id" > "$au"
echo "Mastering complete in $(( ($(date +%s) - t0) / 60 )) min: $(basename "$out") (high-band compressor: $pick)"
# The work folder holds a few GB of intermediate audio per episode.
case "$w" in "$ROOT/.work/"?*) rm -rf -- "$w" ;; esac
