// catalog-refresh
//
// The only thing allowed to write to Indigo's shared cache.
//
// The app ships a publishable key with read-only policies, so a cache miss
// cannot fill itself from the client. It calls here instead: this function
// checks the cache, fetches upstream with a server-side provider token when it
// has to, stores the result under the service-role key, and returns the
// payload — so a miss costs one round trip rather than a write and a re-read.

import { createClient } from "jsr:@supabase/supabase-js@2";
import type { SupabaseClient } from "jsr:@supabase/supabase-js@2";
import { normalizeDiscogsRelease } from "../_shared/discogs.ts";

// An allow-list, not a URL parameter. The request names a provider and a
// resource; it never supplies a URL, so this cannot be turned into a proxy for
// fetching arbitrary hosts.
const PROVIDERS: Record<string, Record<string, (id: string) => string>> = {
  discogs: {
    release: (id) => `https://api.discogs.com/releases/${id}`,
    artist: (id) => `https://api.discogs.com/artists/${id}`,
    label: (id) => `https://api.discogs.com/labels/${id}`,
    master: (id) => `https://api.discogs.com/masters/${id}`,
  },
  musicbrainz: {
    release: (id) => `https://musicbrainz.org/ws/2/release/${id}?inc=artist-credits+labels&fmt=json`,
    recording: (id) => `https://musicbrainz.org/ws/2/recording/${id}?inc=artist-credits&fmt=json`,
    artist: (id) => `https://musicbrainz.org/ws/2/artist/${id}?inc=url-rels&fmt=json`,
  },
};

// Upstream ids are opaque handles: Discogs uses integers, MusicBrainz uses
// UUIDs. Anything with a slash, dot or escape in it is not an id, and would be
// an attempt to reshape the URL built above.
const SAFE_ID = /^[A-Za-z0-9-]{1,64}$/;

// The second request shape: an explicit Discogs path plus query, for the calls
// that are searches rather than id lookups. Still an allow-list — a path that
// does not match one of these patterns is refused, and every query key must be
// named here. Without both halves this would be an open proxy wearing Indigo's
// credential.
const DISCOGS_PATHS: Array<{ pattern: RegExp; params: Set<string> }> = [
  {
    pattern: /^database\/search$/,
    params: new Set([
      "q", "type", "artist", "label", "style", "year",
      "track", "release_title", "per_page", "page",
    ]),
  },
  { pattern: /^artists\/\d{1,12}$/, params: new Set() },
  {
    pattern: /^artists\/\d{1,12}\/releases$/,
    params: new Set(["sort", "sort_order", "per_page", "page"]),
  },
  { pattern: /^releases\/\d{1,12}$/, params: new Set() },
  { pattern: /^labels\/\d{1,12}$/, params: new Set() },
  { pattern: /^masters\/\d{1,12}$/, params: new Set() },
];

const MAX_QUERY_VALUE = 200;

/// Validates a path request and returns the upstream URL plus a stable cache
/// key, or null if anything about it is not on the allow-list.
///
/// Keys are sorted so the same search always lands on the same cached row
/// however the caller happened to order them.
function resolvePath(
  path: string,
  query: Record<string, unknown>,
): { url: string; cacheKey: string } | null {
  const rule = DISCOGS_PATHS.find((candidate) => candidate.pattern.test(path));
  if (!rule) return null;

  const entries: Array<[string, string]> = [];
  for (const [key, raw] of Object.entries(query ?? {})) {
    if (!rule.params.has(key)) return null;
    const value = String(raw);
    if (value.length === 0 || value.length > MAX_QUERY_VALUE) return null;
    // Control characters have no business in a search term and are the shape
    // of a header- or URL-splitting attempt.
    if (/[\u0000-\u001f\u007f]/.test(value)) return null;
    entries.push([key, value]);
  }
  entries.sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0));

  const search = new URLSearchParams(entries).toString();

  // The cache key is deliberately NOT the encoded query string. It is only a
  // database key, and the app has to be able to reproduce it exactly to read
  // the row without invoking this function. Percent-encoding rules differ
  // between URLSearchParams and Swift's URLComponents (spaces alone become
  // "+" here and "%20" there), so the key uses raw values and leaves encoding
  // to the URL.
  const rawKey = entries.map(([key, value]) => `${key}=${value}`).join("&");

  return {
    url: `https://api.discogs.com/${path}${search ? `?${search}` : ""}`,
    cacheKey: rawKey ? `${path}?${rawKey}` : path,
  };
}

const MIN_TTL = 60;
const MAX_TTL = 365 * 24 * 60 * 60;

const USER_AGENT = "Indigo/1.0 (+https://github.com/kirillginko/indigo)";

function json(body: unknown, status = 200, extra: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json", ...extra },
  });
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch {
    return json({ error: "invalid_json" }, 400);
  }

  const provider = String(body.provider ?? "");
  const resources = PROVIDERS[provider];
  if (!resources) return json({ error: "unknown_provider", provider }, 400);

  // Two request shapes converge here. `path` + `query` covers the searches;
  // `resource_type` + `resource_id` remains the id lookup the normalizer keys
  // off. Both end up as a URL and a cache key, and neither lets the caller
  // choose a host.
  let upstreamURL: string;
  let resourceType: string;
  let resourceID: string;

  if (body.path !== undefined) {
    if (provider !== "discogs") return json({ error: "path_unsupported_for_provider" }, 400);

    const path = String(body.path);
    const resolved = resolvePath(path, (body.query ?? {}) as Record<string, unknown>);
    if (!resolved) return json({ error: "path_not_allowed", path }, 400);

    upstreamURL = resolved.url;
    // Cached under the path family, so one search's rows are easy to find and
    // expire together.
    resourceType = path;
    resourceID = resolved.cacheKey;
  } else {
    resourceType = String(body.resource_type ?? "");
    resourceID = String(body.resource_id ?? "");

    const buildURL = resources[resourceType];
    if (!buildURL) return json({ error: "unknown_resource_type", resourceType }, 400);
    if (!SAFE_ID.test(resourceID)) return json({ error: "invalid_resource_id" }, 400);

    upstreamURL = buildURL(resourceID);
  }

  const requestedTTL = Number(body.ttl_seconds ?? 0);
  const ttl = Number.isFinite(requestedTTL) && requestedTTL > 0
    ? Math.min(Math.max(Math.trunc(requestedTTL), MIN_TTL), MAX_TTL)
    : 30 * 24 * 60 * 60;

  // Service role: this is the one context that bypasses RLS, and it never
  // leaves the server.
  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  // Cache first, so a burst of clients asking for the same release costs the
  // upstream provider one request rather than one each.
  // The app reads the cache itself before calling — that direct Postgres read
  // is the fast path, and repeating it here just spent 160ms proving something
  // the caller already knew. It still runs when nobody says otherwise, so a
  // caller that has not checked is unaffected.
  const skipCacheRead = body.skip_cache_read === true;

  const { data: cached, error: readError } = skipCacheRead
    ? { data: null, error: null }
    : await supabase
    .from("metadata_cache")
    .select("payload,expires_at")
    .eq("provider", provider)
    .eq("resource_type", resourceType)
    .eq("resource_id", resourceID)
    .maybeSingle();

  if (readError) return json({ error: "cache_read_failed", detail: readError.message }, 500);

  if (cached && (!cached.expires_at || new Date(cached.expires_at) > new Date())) {
    // Self-healing: a payload cached before this normalizer existed, or by a
    // run that failed partway, still has no rows behind it. Cheap to check —
    // one indexed lookup — and it means the normalized tables catch up without
    // anyone having to expire the cache by hand.
    if (!(await isNormalized(supabase, provider, resourceType, resourceID))) {
      await normalize(supabase, provider, resourceType, cached.payload);
    }
    return json(cached.payload);
  }

  const headers: Record<string, string> = { "User-Agent": USER_AGENT, Accept: "application/json" };

  // Indigo's own Discogs credential, held here and never shipped to a client.
  if (provider === "discogs") {
    const token = Deno.env.get("DISCOGS_TOKEN");
    if (token) headers.Authorization = `Discogs token=${token}`;
  }

  let upstream: Response;
  try {
    upstream = await fetch(upstreamURL, { headers });
  } catch (cause) {
    return json({ error: "upstream_unreachable", detail: String(cause) }, 502);
  }

  if (!upstream.ok) {
    // A stale payload is worth more than an error when the provider is simply
    // rate-limiting us.
    if (cached) return json(cached.payload);
    // Carry the provider's own words through. This is Indigo's backend, the
    // body is a public API's error text, and without it a failure here is
    // indistinguishable from every other failure here.
    const detail = await upstream.text().catch(() => "");
    console.error("upstream_error", upstream.status, upstreamURL, detail.slice(0, 300));
    return json({
      error: "upstream_error",
      status: upstream.status,
      detail: detail.slice(0, 300),
    }, 502);
  }

  let payload: unknown;
  try {
    payload = await upstream.json();
  } catch {
    return json({ error: "upstream_malformed" }, 502);
  }

  // Caching and normalizing are for the *next* caller. This one already has
  // what it asked for, and making it wait for our bookkeeping was a third of
  // the time it spent here.
  const persist = (async () => {
    const { error: writeError } = await supabase
      .from("metadata_cache")
      .upsert({
        provider,
        resource_type: resourceType,
        resource_id: resourceID,
        payload,
        fetched_at: new Date().toISOString(),
        expires_at: new Date(Date.now() + ttl * 1000).toISOString(),
      }, { onConflict: "provider,resource_type,resource_id" });

    // The fetch succeeded; failing to cache it is worth logging, not failing on.
    if (writeError) console.error("cache_write_failed", writeError.message);

    await normalize(supabase, provider, resourceType, payload);
  })();

  // Supabase keeps the worker alive for this. Without it the response would
  // return and the write would be cut off mid-flight, so fall back to awaiting
  // if the runtime does not offer it.
  const runtime = (globalThis as { EdgeRuntime?: { waitUntil(p: Promise<unknown>): void } }).EdgeRuntime;
  if (runtime?.waitUntil) {
    runtime.waitUntil(persist.catch((cause) => console.error("persist_failed", String(cause))));
  } else {
    await persist.catch((cause) => console.error("persist_failed", String(cause)));
  }

  return json(payload);
});

/// Whether this resource already has normalized rows behind it.
///
/// `external_ids` doubles as the marker: it is written last, so its presence
/// means the entity it points at exists.
async function isNormalized(
  supabase: SupabaseClient,
  provider: string,
  resourceType: string,
  resourceID: string,
): Promise<boolean> {
  if (provider !== "discogs" || resourceType !== "release") return true;

  const { data } = await supabase
    .from("external_ids")
    .select("id")
    .eq("provider", provider)
    .eq("entity_type", "release")
    .eq("external_id", resourceID)
    .maybeSingle();

  return Boolean(data);
}

/// Normalization is a bonus on top of the cache, never a reason to fail the
/// request: the caller asked for a payload and we have one.
async function normalize(
  supabase: SupabaseClient,
  provider: string,
  resourceType: string,
  payload: unknown,
): Promise<void> {
  try {
    if (provider === "discogs" && resourceType === "release") {
      await normalizeDiscogsRelease(supabase, payload as Record<string, unknown>);
    }
  } catch (cause) {
    console.error("normalize_failed", String(cause));
  }
}
