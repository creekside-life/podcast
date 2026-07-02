// Cloudflare Worker: serves Creekside podcast audio at podcast.creekside.life.
//
// Why a Worker instead of an R2 custom-domain binding? The creekside.life zone has
// a redirect rule that 302s non-primary hostnames to bellshoalscoc.org, and it
// fires before R2's public bucket would answer. A Worker route runs ahead of that
// redirect, so it lets us serve the bucket on this hostname anyway.
//
// It serves from R2 first (correct audio/mpeg, range + conditional support), and
// falls back to the original GitHub Releases asset when the object isn't in R2 yet
// — so every enclosure URL stays playable even mid-migration.

const GH_BASE = "https://github.com/creekside-life/podcast/releases/download";

// data/2026-06-15-<id>.mp3 lives in the GitHub release tagged with its year.
function githubUrl(key) {
  const m = key.match(/^(\d{4})-\d{2}-\d{2}-/);
  return m ? `${GH_BASE}/${m[1]}/${key}` : null;
}

function guessType(key) {
  if (key.endsWith(".mp3")) return "audio/mpeg";
  if (key.endsWith(".txt")) return "text/plain; charset=utf-8";
  return "application/octet-stream";
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const key = decodeURIComponent(url.pathname.replace(/^\/+/, ""));

    if (request.method !== "GET" && request.method !== "HEAD") {
      return new Response("Method Not Allowed", {
        status: 405,
        headers: { Allow: "GET, HEAD" },
      });
    }
    if (key === "") {
      return new Response("Creekside Church of Christ podcast media\n", {
        status: 200,
        headers: { "content-type": "text/plain; charset=utf-8" },
      });
    }

    // ---- Primary: Cloudflare R2 ----
    // Passing the request Headers lets R2 honor Range and If-* conditionals.
    const object = await env.BUCKET.get(key, {
      range: request.headers,
      onlyIf: request.headers,
    });

    if (object !== null) {
      const headers = new Headers();
      object.writeHttpMetadata(headers);
      headers.set("etag", object.httpEtag);
      headers.set("accept-ranges", "bytes");
      headers.set("cache-control", "public, max-age=86400");
      headers.set("x-podcast-origin", "r2");
      if (!headers.get("content-type")) headers.set("content-type", guessType(key));

      // R2 can populate object.range even without a Range header, so only emit a
      // 206 when the client actually asked for one — a spurious 206 breaks players.
      let status = 200;
      if (request.headers.has("range") && object.range && "offset" in object.range) {
        const offset = object.range.offset || 0;
        const length = object.range.length ?? object.size - offset;
        headers.set("content-range", `bytes ${offset}-${offset + length - 1}/${object.size}`);
        headers.set("content-length", String(length));
        status = 206;
      }

      // No body => either a HEAD, or an onlyIf conditional that wasn't satisfied.
      const body = object.body ?? null;
      if (request.method === "HEAD") {
        headers.set("content-length", String(object.size));
        return new Response(null, { status, headers });
      }
      if (body === null) {
        return new Response(null, { status: 304, headers });
      }
      return new Response(body, { status, headers });
    }

    // ---- Fallback: original GitHub Releases asset ----
    const gh = githubUrl(key);
    if (gh) {
      // Only forward Range — passing the original Host/CF headers breaks GitHub.
      const fwd = new Headers();
      const range = request.headers.get("range");
      if (range) fwd.set("range", range);
      const ghResp = await fetch(gh, {
        method: request.method,
        headers: fwd,
        redirect: "follow",
      });
      const headers = new Headers(ghResp.headers);
      // GitHub serves mp3s as application/octet-stream; relabel so strict players decode it.
      if (key.endsWith(".mp3")) headers.set("content-type", "audio/mpeg");
      headers.set("x-podcast-origin", "github");
      return new Response(ghResp.body, { status: ghResp.status, headers });
    }

    return new Response("Not found", { status: 404 });
  },
};
