#!/bin/bash
# Process an m3u file through Auphonic and download the processed file

source .env

FILE="$1"
TITLE="$2"
NEW_FILE="$3"
AU_FILE=$(echo "$FILE" | sed 's/\.[^.]*$/.au/')

if [ -f "$NEW_FILE" ]; then
    echo "Auphonic skipping: $FILE already processed"
    exit 0
fi

# Find another mp3 file already based on the same video
VIDEO_ID=$(echo "$NEW_FILE" | gsed 's/.*\/[0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}-\([a-zA-Z0-9_-]*\)\.mp3/\1/')
EXISTING_FILE=$(find . -type f -name "*$VIDEO_ID.mp3" | grep -v "$NEW_FILE" | head -n 1)
if [ -f "$EXISTING_FILE" ]; then
    echo "Auphonic skipping: $FILE already processed (previous file $EXISTING_FILE)"
    cp "$EXISTING_FILE" "$NEW_FILE"
    EXISTING_AU_FILE=$(echo "$EXISTING_FILE" | sed 's/\.[^.]*$/.au/')
    cp "$EXISTING_AU_FILE" "$AU_FILE"
    exit 0
fi

if [ ! -f "$FILE" ]; then
    echo "Auphonic skipping: $FILE does not exist"
    exit 1
fi

UUID=""
if [ -f "$AU_FILE" ]; then
  UUID=$(cat "$AU_FILE")
  echo -n "Auphonic already received UUID: $UUID"
else
  echo -n "Auphonic is processing: $FILE with title $TITLE"
  # Keep running while UUID is empty
  while [ -z "$UUID" ]; do
    JSON=$(curl -s -X POST https://auphonic.com/api/simple/productions.json \
      -H "Authorization: Bearer $AUPHONIC_API_KEY" \
      -F "preset=oFbHxxvDT2Wrg9CjV5xgBQ" \
      -F "title=$TITLE" \
      -F "input_file=@$FILE" \
      -F "action=start")

    UUID=$(echo "$JSON" | jq -r '.data.uuid')
    if [ -z "$UUID" ]; then
      echo "Error processing file. Retrying in 30 seconds"
      sleep 30
    fi
  done
  # echo "UUID is $UUID"
fi

AU_FILE=$(echo "$FILE" | sed 's/\.[^.]*$/.au/')
echo "$UUID" > "$AU_FILE"

while true; do
  echo -n "."
  JSON=$(curl -s -X GET "https://auphonic.com/api/production/$UUID.json" \
    -H "Authorization: Bearer $AUPHONIC_API_KEY")
  # echo "$JSON"
  STATUS=$(echo "$JSON" | jq -r '.data.status_string')
  if [ "$STATUS" == "Done" ]; then
    break
  fi
  sleep 10
done

DOWNLOAD_URL=$(echo "$JSON" | jq -r '.data.output_files[0].download_url')

# Check if download URL is valid
if [[ -z "$DOWNLOAD_URL" || "$DOWNLOAD_URL" == "null" ]]; then
  echo "ERROR: Could not get download URL from Auphonic"
  echo "Response: $JSON"
  exit 1
fi

echo "Auphonic complete, downloading to $NEW_FILE"
curl -s -S -L -o "$NEW_FILE" "$DOWNLOAD_URL" -H "Authorization: Bearer $AUPHONIC_API_KEY"

# Verify download succeeded and file is not empty
if [ ! -f "$NEW_FILE" ] || [ ! -s "$NEW_FILE" ]; then
  echo "ERROR: Download failed or file is empty"
  rm -f "$NEW_FILE"
  exit 1
fi