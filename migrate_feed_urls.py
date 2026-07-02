#!/usr/bin/env python3
"""One-time: repoint the existing podcast.xml audio at podcast.creekside.life.

For every <enclosure> currently pointing at a GitHub Releases asset, this:
  - rewrites the enclosure url to the R2/Worker host (served as audio/mpeg), and
  - injects a Podcasting 2.0 <podcast:alternateEnclosure> listing the R2 URL
    (primary) and the original GitHub URL (backup) as redundant sources.
It also adds the podcast: namespace to <rss>. Output matches what the updated
`build` script now generates, so future rebuilds won't churn the feed.

Idempotent: re-running makes no further changes once migrated.
"""
import re
import sys

FEED = "podcast.xml"
MEDIA_BASE = "https://podcast.creekside.life"
PODCAST_NS = 'xmlns:podcast="https://podcastindex.org/namespace/1.0"'

GH_RE = re.compile(
    r'(?P<indent>[ \t]*)<enclosure url="'
    r'https://github\.com/creekside-life/podcast/releases/download/'
    r'(?P<year>\d{4})/(?P<file>[^"]+\.mp3)"'
    r' length="(?P<len>\d+)" type="audio/mpeg" />'
)


def rewrite_enclosure(m):
    indent = m.group("indent")
    fn = m.group("file")
    length = m.group("len")
    gh_url = (
        f"https://github.com/creekside-life/podcast/releases/download/"
        f"{m.group('year')}/{fn}"
    )
    r2_url = f"{MEDIA_BASE}/{fn}"
    return (
        f'{indent}<enclosure url="{r2_url}" length="{length}" type="audio/mpeg" />\n'
        f'{indent}<podcast:alternateEnclosure type="audio/mpeg" length="{length}" '
        f'default="true" title="Audio">\n'
        f'{indent}  <podcast:source uri="{r2_url}" />\n'
        f'{indent}  <podcast:source uri="{gh_url}" />\n'
        f'{indent}</podcast:alternateEnclosure>'
    )


def main():
    with open(FEED, encoding="utf-8") as fh:
        xml = fh.read()

    if "podcast.creekside.life" in xml and "alternateEnclosure" in xml:
        print("Feed already migrated — nothing to do.")
        return 0

    # Add the podcast: namespace to <rss> if missing.
    if PODCAST_NS not in xml:
        xml = xml.replace(
            '<rss xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd"',
            f'<rss xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd" {PODCAST_NS}',
            1,
        )

    xml, n = GH_RE.subn(rewrite_enclosure, xml)
    if n == 0:
        print("No GitHub enclosures found to rewrite.", file=sys.stderr)
        return 1

    with open(FEED, "w", encoding="utf-8") as fh:
        fh.write(xml)
    print(f"Rewrote {n} enclosure(s) to {MEDIA_BASE} with GitHub backup sources.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
