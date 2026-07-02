# podcast.creekside.life media Worker

Serves the podcast audio for the Creekside feed from Cloudflare R2, at
`https://podcast.creekside.life/<filename>.mp3`.

## Why this exists

The feed used to point enclosures directly at GitHub Releases
(`github.com/creekside-life/podcast/releases/download/...`). GitHub serves those
assets as `application/octet-stream` behind an expiring signed redirect. Strict
players — notably **Audible/Amazon (error IP-4555)** — refuse to decode a stream
that isn't delivered as real audio, so episodes wouldn't play.

This Worker fixes that by serving the bytes with a proper `audio/mpeg`
content-type, range support, and a stable non-expiring URL.

A Worker (rather than an R2 custom-domain binding) is required because the
`creekside.life` zone has a redirect rule that 302s non-primary hostnames to
`www.bellshoalscoc.org`. That rule fires before an R2 public bucket would answer,
but Worker routes run ahead of it — so the Worker is what makes this hostname
usable for the bucket.

## Behavior

- **Primary:** streams the object from the `creekside-podcast` R2 bucket.
- **Fallback:** if the object isn't in R2 yet, it proxies the original GitHub
  Releases asset and relabels the content-type to `audio/mpeg`. Every enclosure
  URL therefore stays playable even mid-migration.
- Response header `x-podcast-origin: r2|github` shows which origin answered.
- Supports `GET`/`HEAD`, `Range` requests (206), and conditional requests (304).

## Deploy

```bash
cd worker
wrangler deploy
```

Requires `wrangler login` (Cloudflare account "HD"). The route
`podcast.creekside.life/*` and the R2 binding are configured in `wrangler.toml`.
