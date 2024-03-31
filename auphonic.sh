#!/bin/bash
# Process an m3u file through Auphonic and download the processed file

source .env

FILE="$1"
TITLE="$2"
NEW_FILE="$3"
AU_FILE=$(echo "$FILE" | sed 's/\.[^.]*$/.au/')

if [ ! -f "$FILE" ]; then
    echo "File $FILE does not exist"
    exit 1
fi

if [ -f "$NEW_FILE" ]; then
    echo "File $FILE already processed"
    exit 0
fi

if [ -f "$AU_FILE" ]; then
  UUID=$(cat "$AU_FILE")
  echo "Already uploaded. UUID is $UUID"
else
  echo "Processing $FILE with title $TITLE"
  JSON=$(curl -s -X POST https://auphonic.com/api/simple/productions.json \
      -u "$AUPHONIC_USERNAME:$AUPHONIC_PASSWORD" \
      -F "preset=oFbHxxvDT2Wrg9CjV5xgBQ" \
      -F "title=$TITLE" \
      -F "input_file=@$FILE" \
      -F "action=start")

  UUID=$(echo "$JSON" | jq -r '.data.uuid')
  echo "UUID is $UUID"
fi

AU_FILE=$(echo "$FILE" | sed 's/\.[^.]*$/.au/')
echo "$UUID" > "$AU_FILE"

while true; do
  JSON=$(curl -X GET "https://auphonic.com/api/production/$UUID.json" \
  -u "$AUPHONIC_USERNAME:$AUPHONIC_PASSWORD")
  # echo "$JSON"
  STATUS=$(echo "$JSON" | jq -r '.data.status_string')
  if [ "$STATUS" == "Done" ]; then
    break
  fi
  sleep 30
done

DOWNLOAD_URL=$(echo "$JSON" | jq -r '.data.output_files[0].download_url')
echo "Downloading $DOWNLOAD_URL to $NEW_FILE"
curl -o "$NEW_FILE" "$DOWNLOAD_URL" -u "$AUPHONIC_USERNAME:$AUPHONIC_PASSWORD" > /dev/null 2>&1