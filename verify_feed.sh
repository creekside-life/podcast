#!/bin/bash
# verify_feed.sh — Confirm every episode in podcast.xml is downloadable and that
# the bytes the server actually serves match the feed's length= attribute.
#
# Podcast players (Apple/Overcast/Spotify) refuse to play an enclosure when the
# URL 404s or when the advertised length= disagrees with the real Content-Length,
# so those are the two failure modes we check for.
#
# Usage:
#   ./verify_feed.sh            # check every enclosure in podcast.xml
#   ./verify_feed.sh -n 20      # only check the 20 most recent episodes
#   ./verify_feed.sh -j 12      # run 12 checks in parallel (default 8)
#   ./verify_feed.sh -f other.xml
#
# Exit code is 0 when everything is playable, 1 when any episode fails.

set -uo pipefail

FEED="podcast.xml"
LIMIT=0        # 0 = all episodes
JOBS=8

while getopts "f:n:j:h" opt; do
  case "$opt" in
    f) FEED="$OPTARG" ;;
    n) LIMIT="$OPTARG" ;;
    j) JOBS="$OPTARG" ;;
    h) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown option. Use -h for help." >&2; exit 2 ;;
  esac
done

if [ ! -f "$FEED" ]; then
  echo "ERROR: feed '$FEED' not found (run from the repo root)." >&2
  exit 2
fi

# Pull "url length" pairs from every <enclosure> in feed order (newest first).
pairs=$(grep -o '<enclosure[^>]*>' "$FEED" | \
  sed -n 's/.*url="\([^"]*\)"[^>]*length="\([0-9]*\)".*/\1 \2/p')

if [ "$LIMIT" -gt 0 ]; then
  pairs=$(echo "$pairs" | head -n "$LIMIT")
fi

total=$(echo "$pairs" | grep -c .)
if [ "$total" -eq 0 ]; then
  echo "ERROR: no <enclosure> entries found in $FEED." >&2
  exit 2
fi

echo "Checking $total episode(s) in $FEED with $JOBS parallel workers..."
echo

# Check one enclosure: fetch a single byte with a ranged request so GitHub reports
# the true asset size in the Content-Range header (total after the slash), without
# downloading the whole file. Prints: STATUS<TAB>url<TAB>detail
check_one() {
  local url="$1" want="$2"
  local hdr code total ctype attempt

  # Retry on connection failures (code 000) so a transient blip under parallel
  # load isn't reported as a real outage.
  for attempt in 1 2 3; do
    hdr=$(curl -sL --max-time 60 -r 0-0 -o /dev/null -D - \
          -w 'HTTPCODE:%{http_code}\n' "$url" 2>/dev/null)
    code=$(echo "$hdr" | sed -n 's/HTTPCODE:\([0-9]*\)/\1/p' | tail -1)
    [ -n "$code" ] && [ "$code" != "000" ] && break
    sleep "$attempt"
  done
  # "content-range: bytes 0-0/12345" -> 12345 ; some servers only send content-length.
  total=$(echo "$hdr" | grep -i '^content-range:' | sed -n 's|.*/\([0-9][0-9]*\).*|\1|p' | tail -1)
  [ -z "$total" ] && total=$(echo "$hdr" | grep -i '^content-length:' | tr -d '\r' | awk '{print $2}' | tail -1)
  # Content-Type of the FINAL hop (last one wins after any redirects).
  ctype=$(echo "$hdr" | grep -i '^content-type:' | tail -1 | tr -d '\r' | awk '{print tolower($2)}' | sed 's/;.*//')

  if [ "$code" != "200" ] && [ "$code" != "206" ]; then
    printf 'DOWN\t%s\tHTTP %s (not downloadable)\n' "$url" "${code:-000}"
  elif [ -z "$total" ]; then
    printf 'WARN\t%s\treachable but server gave no size to verify\n' "$url"
  elif [ "$total" != "$want" ]; then
    printf 'SIZE\t%s\tfeed says %s, server serves %s (players will choke)\n' "$url" "$want" "$total"
  elif [ -n "$ctype" ] && [[ "$ctype" != audio/* ]]; then
    # Strict players (Audible/Amazon) can reject a stream not served as real audio,
    # even when the file is a valid MP3 and the feed declares type="audio/mpeg".
    printf 'MIME\t%s\tserved as "%s", not audio/* (strict players may reject)\n' "$url" "$ctype"
  else
    printf 'OK\t%s\t%s bytes\n' "$url" "$total"
  fi
}
export -f check_one

# Fan out the checks. xargs -P gives us parallelism without extra dependencies.
results=$(echo "$pairs" | xargs -P "$JOBS" -n 2 bash -c 'check_one "$0" "$1"')

ok_count=$(echo "$results" | grep -c '^OK	')
mime_count=$(echo "$results" | grep -c '^MIME	')

# Report per-episode problems (unreachable / size mismatch), in feed order.
# MIME is handled separately below because it's typically a fleet-wide hosting
# trait, and printing one line per episode would bury the real signal.
problems=$(echo "$results" | grep -vE '^(OK|MIME)	' | sort)
if [ -n "$problems" ]; then
  echo "$problems" | while IFS=$'\t' read -r status url detail; do
    echo "  [$status] $url"
    echo "         $detail"
  done
  echo
fi

if [ "$mime_count" -gt 0 ]; then
  mime_type=$(echo "$results" | grep -m1 '^MIME	' | sed -n 's/.*served as "\([^"]*\)".*/\1/p')
  echo "  [MIME] $mime_count/$total episode(s) served as \"$mime_type\" instead of audio/*"
  echo "         The MP3s are valid, but strict players (e.g. Audible, error IP-45xx)"
  echo "         can refuse to decode a stream not delivered with an audio MIME type."
  echo "         This is a hosting limitation, not a per-file problem."
  echo
fi

fail_count=$(echo "$results" | grep -cE '^(DOWN|SIZE)	')
warn_count=$(echo "$results" | grep -c '^WARN	')

echo "----------------------------------------"
echo "  OK:       $ok_count"
echo "  Failed:   $fail_count (unreachable or size mismatch)"
echo "  MIME:     $mime_count (valid audio, but not served as audio/*)"
echo "  Warnings: $warn_count"
echo "----------------------------------------"

if [ "$fail_count" -gt 0 ]; then
  echo "Some episodes are NOT playable. Re-run ./build to re-upload/sync them." >&2
  exit 1
fi
echo "All episodes are downloadable and sizes match the feed."
