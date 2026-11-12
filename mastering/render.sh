#!/bin/bash
# render.sh in.m4a workdir out.mp3 "Title"   (HFC=1 adds the high-band compressor)
# One build of one episode. master.sh calls it twice and keeps the better-scoring build; the expensive stages
# (both Whisper passes, dereverb, denoise) are cached in workdir, so the second build only redoes the cheap tail.
#
# Chain: dereverb -> denoise -> [HFC] -> high-pass + leveler -> cut pauses and fillers -> auto-EQ -> room
# expander -> loudness rider + lookahead limiter -> 128k mono MP3 at -17 LUFS.
set -euo pipefail
L="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
C="${CREEKSIDE_CACHE:-$HOME/.cache/creekside-podcast}"
WHISPER_MODEL="${WHISPER_MODEL:-$HOME/.cache/whisper-cpp/ggml-large-v3-turbo.bin}"
in=$1; w=$2; out=$3; title=$4
mkdir -p "$w"
PY="$C/core/bin/python -I"
t0=$(date +%s); lap() { echo "    [$(( $(date +%s) - t0 ))s] $*"; }

# Whisper is primed with fillers on every 30 s window (--carry-initial-prompt): primed once, it drifts back to
# clean text after a few minutes and stops transcribing them. -nfa because flash attention silently disables
# the DTW word timestamps the cutter needs.
transcribe() {  # wav16k out_base
  [ -s "$2.json" ] || whisper-cli -m "$WHISPER_MODEL" -f "$1" -l en -t 4 -nfa -dtw large.v3.turbo -ojf -of "$2" \
    --carry-initial-prompt --prompt "Umm, so, uh, let me think, like, hmm. Okay, um, you know, er, the Lord." \
    > "$2.log" 2>&1
}

[ -s "$w/a.wav" ] || ffmpeg -hide_banner -v error -y -i "$in" -ac 1 -ar 48000 -c:a pcm_f32le "$w/a.wav"
[ -s "$w/a16k.wav" ] || ffmpeg -hide_banner -v error -y -i "$in" -ac 1 -ar 16000 -c:a pcm_s16le "$w/a16k.wav"
# First pass runs on the untouched audio (denoising hides the cues filler detection needs), on the GPU,
# while dereverb and denoise use the CPU.
transcribe "$w/a16k.wav" "$w/asr" &
asr_pid=$!

# Dereverb, then denoise. FoxJoy's MDX "Reverb HQ" model cleaned up the room colour better than slower RoFormer
# dereverbs did; DeepFilterNet at full strength sits after it.
if [ ! -s "$w/dry.wav" ]; then
  ffmpeg -hide_banner -v error -y -i "$w/a.wav" -ac 2 -ar 44100 -c:a pcm_s16le "$w/a44s.wav"
  "$C/sep/bin/audio-separator" "$w/a44s.wav" -m Reverb_HQ_By_FoxJoy.onnx \
    --model_file_dir "$HOME/.cache/audio-separator" --output_dir "$w/dv" --output_format WAV \
    --single_stem "No Reverb" > "$w/dv.log" 2>&1
  ffmpeg -hide_banner -v error -y -i "$(ls "$w"/dv/*"No Reverb"*.wav | head -1)" -ac 1 -ar 48000 -c:a pcm_f32le \
    "$w/dry.wav"
  lap dereverbed
fi
# Blend some of the original back in (KEEP_ROOM, default 15%). Full-strength dereverb lost a blind A/B to
# Auphonic 2-1 for "sucking the life out" of the voice. The dereverbed stem sits sample-aligned with the source,
# so this is exactly a 15% weaker dereverb, not a comb filter.
keep="${KEEP_ROOM:-0.15}"
den0="$w/den0_k$keep.wav"
if [ ! -s "$den0" ]; then
  ffmpeg -hide_banner -v error -y -i "$w/dry.wav" -i "$w/a.wav" \
    -filter_complex "[0][1]amix=inputs=2:weights='$(echo "1 - $keep" | bc -l) $keep':normalize=0" \
    -c:a pcm_f32le "$w/drymix.wav"
  "$C/bin/deep-filter" -D -a 100 -o "$w/df" "$w/drymix.wav" > /dev/null 2>&1
  mv "$w/df/drymix.wav" "$den0"
  lap denoised
fi
cp "$den0" "$w/den0.wav"
# High-band compressor: tames a harsh upper range on some voices and hurts others, so master.sh builds both.
if [ "${HFC:-0}" = 1 ]; then
  ffmpeg -hide_banner -v error -y -i "$w/den0.wav" -filter_complex "asplit=2[a][b];[a]highpass=f=4000:poles=2,\
acompressor=threshold=-30dB:ratio=3:attack=2:release=60:knee=6[h];[b]lowpass=f=4000:poles=2[l];\
[l][h]amix=inputs=2:normalize=0" -c:a pcm_f32le "$w/den.wav"
else
  cp "$w/den0.wav" "$w/den.wav"
fi

# High-pass and a slow leveler only, then a linear trip to -17 LUFS for the cutter. No compressor: it lifted
# the hiss under speech and lowered every quality score; the final loudness stage handles range and peaks.
ffmpeg -hide_banner -v error -y -i "$w/den.wav" -af "aresample=48000,highpass=f=75:poles=2,dynaudnorm=f=400:g=21:p=0.7:m=6:s=0" \
  -ac 1 -c:a pcm_f32le "$w/lev.wav"
m=$(ffmpeg -hide_banner -nostats -i "$w/lev.wav" -af loudnorm=I=-17:TP=-1.5:LRA=11:print_format=json -f null - 2>&1 \
  | sed -n '/^{/,/^}/p')
j() { echo "$m" | jq -r ".$1"; }
ffmpeg -hide_banner -v error -y -i "$w/lev.wav" -af "loudnorm=I=-17:TP=-1.5:LRA=11:linear=true:measured_I=$(j input_i):\
measured_TP=$(j input_tp):measured_LRA=$(j input_lra):measured_thresh=$(j input_thresh):offset=$(j target_offset),\
aresample=48000" -c:a pcm_s16le "$w/post.wav"

# Second Whisper pass on the denoised audio catches fillers the first one never wrote down. Forced alignment
# (MMS) then pins each filler, so the cutter can split ones fused to a neighbouring word.
wait $asr_pid
[ -s "$w/den16k.wav" ] || ffmpeg -hide_banner -v error -y -i "$w/den0.wav" -ac 1 -ar 16000 -c:a pcm_s16le "$w/den16k.wav"
transcribe "$w/den16k.wav" "$w/asr2"
if [ ! -s "$w/fillers.json" ]; then
  "$C/align/bin/python" -I "$L/falign.py" "$w/a16k.wav" "$w/asr.json" "$w/fillers1.json" > /dev/null 2>&1
  "$C/align/bin/python" -I "$L/falign.py" "$w/a16k.wav" "$w/asr2.json" "$w/fillers2.json" > /dev/null 2>&1
  $PY "$L/merge_fillers.py" "$w/fillers1.json" "$w/fillers2.json" "$w/fillers.json" > /dev/null
fi
$PY "$L/cut.py" "$w/post.wav" "$w/asr.json" "$w/cut.wav" --min-pause 0.8 --max-pause 1.0 --aligned "$w/fillers.json" \
  | sed 's|^.*/|    |'
cp "$w/cut.cuts.json" "$w/hfc${HFC:-0}.cuts.json"

# Auto-EQ toward the tonal balance of past Auphonic episodes, then clamp the room behind each word.
eq=$($PY "$L/autoeq.py" "$w/cut.wav" "$L/eq_target.json" 2> /dev/null)
ffmpeg -hide_banner -v error -y -i "$w/cut.wav" -af "$eq" -c:a pcm_f32le "$w/eq.wav"
$PY "$L/tailgate.py" "$w/eq.wav" "$w/gate.wav" > /dev/null

# Loudness in two jobs: loudnorm rides 3 s windows (LRA=1) to even out quiet and loud sentences with its own
# true-peak limiter off (TP=0, it dulled the speech), then a 5 ms lookahead limiter at 4x oversampling takes the
# peaks. The MP3 encode shaves a few tenths of a LU, so it is measured once and redone with the remainder.
LIMIT="aresample=192000,alimiter=limit=0.84:attack=5:release=50:level=false,aresample=48000"
lufs() { ffmpeg -hide_banner -nostats -i "$1" -af ebur128 -f null - 2>&1 | awk '/Summary/{s=1} s && /I:/{print $2; exit}'; }
m=$(ffmpeg -hide_banner -nostats -i "$w/gate.wav" -af loudnorm=I=-17:TP=0:LRA=1:print_format=json -f null - 2>&1 \
  | sed -n '/^{/,/^}/p')
ffmpeg -hide_banner -v error -y -i "$w/gate.wav" -af "loudnorm=I=-17:TP=0:LRA=1:measured_I=$(j input_i):\
measured_TP=$(j input_tp):measured_LRA=$(j input_lra):measured_thresh=$(j input_thresh):offset=$(j target_offset),\
$LIMIT" -c:a pcm_f32le "$w/lim.wav"
encode() {
  ffmpeg -hide_banner -v error -y -i "$w/lim.wav" -af "volume=${1}dB,$LIMIT" -ar 44100 -ac 1 -c:a libmp3lame -b:a 128k \
    -id3v2_version 3 -metadata title="$title" -metadata artist="Creekside Church of Christ" \
    -metadata publisher="Creekside Church of Christ" -metadata copyright="This work is licensed under CC BY-NC 4.0" \
    -metadata comment="813-685-0750
3949 Lithia Pinecrest Rd, Valrico, FL 33596
https://creekside.life" "$out"
}
trim=$(echo "-17 - ($(lufs "$w/lim.wav"))" | bc -l)
encode "$trim"
trim=$(echo "$trim + (-17 - ($(lufs "$out")))" | bc -l)
encode "$trim"
lap "built HFC=${HFC:-0}"
