#!/bin/bash
# Installs what mastering/master.sh needs. Idempotent and quick once done, so build runs it every time.
#
# Each Python toolchain gets its own environment because their pins conflict: NISQA needs torch 2.2, the
# filler aligner needs torchaudio 2.11 (its MMS_FA forced aligner), and audio-separator brings its own stack.
# Everything lives in $CREEKSIDE_CACHE (default ~/.cache/creekside-podcast), outside the repo.
set -euo pipefail
C="${CREEKSIDE_CACHE:-$HOME/.cache/creekside-podcast}"
WHISPER_MODEL="${WHISPER_MODEL:-$HOME/.cache/whisper-cpp/ggml-large-v3-turbo.bin}"
mkdir -p "$C/bin" "$(dirname "$WHISPER_MODEL")"

need() { command -v "$1" > /dev/null 2>&1; }
need uv || brew install uv > /dev/null
need whisper-cli || brew install whisper-cpp > /dev/null
need jq || brew install jq > /dev/null

# A marker is written only after a clean install, so an interrupted install is retried next run.
venv() {
  local name=$1 py=$2; shift 2
  [ -f "$C/$name/.ok" ] && return 0
  echo "  Setting up the $name environment (one time)..."
  rm -rf -- "${C:?}/$name"
  uv venv -q --python "$py" "$C/$name"
  VIRTUAL_ENV="$C/$name" uv pip install -q "$@"
  touch "$C/$name/.ok"
}
venv core 3.12 numpy scipy soundfile librosa pyloudnorm speechmos onnxruntime  # speechmos needs it, undeclared
venv align 3.11 torch==2.15.0 torchaudio==2.11.1 soundfile
venv sep 3.11 "audio-separator[cpu]==0.48.0"
# librosa 0.10 (NISQA's pin) still imports pkg_resources, which setuptools 70+ dropped.
venv nisqa 3.11 nisqa==2.0.post2 torch==2.2.1 torchaudio==2.2.1 pyloudnorm soundfile "setuptools<70"

fetch() {  # fetch url dest: download once, atomically, so a cut-off download never looks complete
  [ -s "$2" ] && return 0
  echo "  Downloading $(basename "$2") (one time)..."
  curl -fsSL -o "$2.part" "$1" && mv "$2.part" "$2"
}
arch=$(uname -m); [ "$arch" = arm64 ] && arch=aarch64
fetch "https://github.com/Rikorose/DeepFilterNet/releases/download/v0.5.6/deep-filter-0.5.6-$arch-apple-darwin" \
  "$C/bin/deep-filter"
chmod +x "$C/bin/deep-filter"; xattr -c "$C/bin/deep-filter" 2> /dev/null || true
fetch "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin" "$WHISPER_MODEL"
fetch "https://github.com/gabrielmittag/NISQA/raw/master/weights/nisqa.tar" "$C/nisqa.tar"
# The dereverb model (audio-separator) and the MMS aligner (torch hub) download themselves on first use.
