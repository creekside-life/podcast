#!/bin/bash
# Speed up an mp3 file by 10%

FILE="$1"
SPED_UP_FILE="$2"
if [ ! -f "$FILE" ]; then
  echo $SPED_UP_FILE
  exit 0
fi
if [ -f "$SPED_UP_FILE" ]; then
  echo $SPED_UP_FILE
  exit 0
fi
# Use ffmpeg in silent mode
echo "Speeding up $FILE to $SPED_UP_FILE"
ffmpeg -i "$FILE" -af "atempo=1.1" -vn "$SPED_UP_FILE" -y > /dev/null 2>&1