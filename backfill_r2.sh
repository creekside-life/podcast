#!/bin/bash
# One-time backfill: upload every local podcast MP3 to the Cloudflare R2 bucket
# with the correct audio/mpeg content-type. Safe to re-run — it re-uploads
# (overwrites) each object, which is idempotent for identical bytes.
#
# Uploads run through wrangler using its existing OAuth session, so no R2 S3
# API keys are required. The podcast Worker falls back to GitHub Releases for
# any file not yet in R2, so the feed stays playable throughout the backfill.
#
# Usage: ./backfill_r2.sh [parallelism]   (default 4)

set -uo pipefail

BUCKET="creekside-podcast"
JOBS="${1:-4}"

cd "$(dirname "$0")" || exit 1

total="$(find ./data -maxdepth 1 -type f -name "*.mp3" | wc -l | tr -d ' ')"
echo "Backfilling $total MP3(s) to R2 bucket '$BUCKET' ($JOBS at a time)..."

put_one() {
  local f="$1" bucket="$2"
  local bn
  bn="$(basename "$f")"
  if wrangler r2 object put "$bucket/$bn" --file "$f" \
       --content-type "audio/mpeg" --remote >/dev/null 2>&1; then
    echo "ok   $bn"
  else
    echo "FAIL $bn"
  fi
}
export -f put_one

find ./data -maxdepth 1 -type f -name "*.mp3" -print0 \
  | xargs -0 -P "$JOBS" -I{} bash -c 'put_one "$@"' _ {} "$BUCKET" \
  | tee /tmp/r2_backfill.log

fails="$(grep -c '^FAIL' /tmp/r2_backfill.log || true)"
oks="$(grep -c '^ok'   /tmp/r2_backfill.log || true)"
echo "----------------------------------------"
echo "  Uploaded: $oks / $total"
echo "  Failed:   $fails"
[ "$fails" -eq 0 ] && echo "Backfill complete." || echo "Some uploads failed (see /tmp/r2_backfill.log)." >&2
