#!/bin/bash
# Automatically make a youtube short video.
# Expects to be running on a mac, but could be changed to run on linux.
# Uses ollama and yt-dlp.

# This bash script will do the following:
#   1. Given a youtube playlist, get a list of the last ~100 videos.
#   2. Sort the videos by view count, descending.
#   3. Select the top video that has not yet been made into a short (we'll keep a log in ./data/).
#   4. Download the video, in highest quality, including the .vtt file.
#   5. Convert the .vtt file to a straight text file for easier ingestion.
#   6. Use an LLM to discern the most compelling/attention-grabbing sentence/paragraph.
#   7. Get the timestamps for the most compelling parts of the video using the .vtt file and the LLM output.
#   8. Use the timestamps to create a 60-second video clip using ffmpeg, we should:
#       - remove silence
#       - speed it up 1.1x
#       - crop it to the youtube short format of 1080x1920 from the center of the 1080p original
#   9. Add the most compelling sentence/paragraph as text overlay using ffmpeg and libass?
#       - take the appropriate portion of .vtt file and convert to

mkdir -p ./data/
mkdir -p ./data/processing
mkdir -p ./data/output

# Ensure that yt-dlp is installed, if not install it with brew.
if ! command -v yt-dlp &> /dev/null
then
  brew install yt-dlp > /dev/null 2>&1
fi

# Ensure that ollama is installed, if not install it with brew.
if ! command -v ollama &> /dev/null
then
  brew install ollama > /dev/null 2>&1
fi

# Ensure the best model is downloaded for ollama. This is currently phi4. Use ollama list to see all available models.
MODELS=$(ollama list)
if [[ $MODELS != *"phi4:latest"* ]]
then
  ollama pull phi4
fi

ollama loa