#!/bin/bash

# Install gsed if not already installed
if ! command -v gsed &> /dev/null
then
    echo "gsed could not be found, installing..."
    brew install gnu-sed
fi

echo "Generating minimalist transcriptions"
for file in $(find data -maxdepth 1 -type f -name "*.vtt" | sort -r)
do
	newfile="${file/.vtt/.txt}"
	if [ -f "$newfile" ]
	then
		continue
	fi
	text=$(cat "$file")

	# Remove lines like:
	# WEBVTT
	# Kind: captions
	# Language: en
	text=$(echo "$text" | gsed '/^WEBVTT$/d' | gsed '/^Kind: captions$/d' | gsed '/^Language: en$/d')
	# Remove timestamps like: 00:00:00.000 --> 00:00:02.000 and the rest of that line
    text=$(echo "$text" | gsed 's/[0-9]\{2\}:[0-9]\{2\}:[0-9]\{2\}\.[0-9]\{3\} --> [0-9]\{2\}:[0-9]\{2\}:[0-9]\{2\}\.[0-9]\{3\}.*//g')
    # Remove <> tags and </> tags
    text=$(echo "$text" | gsed 's/<[^>]*>//g')
    text=$(echo "$text" | gsed 's/<\/[^>]*>//g')
    # Remove text in [] brackets like [Music]
    text=$(echo "$text" | gsed 's/\[.*\]//g')
	# Remove empty lines
	text=$(echo "$text" | gsed '/^\s*$/d')
	# Remove duplicate contiguous lines, but allow duplicate lines that are not contiguous
    text=$(echo "$text" | uniq)
	
	# Remove contiguous words or phrases
	text=$(echo "$text" | uniq -c)

    # echo "$text" > "$newfile"
    echo "$text"
    exit 0
done