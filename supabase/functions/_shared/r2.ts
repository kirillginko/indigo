// Cloudflare R2, where cached release documents live from 0051 on.
//
// The project is on Supabase's free plan: 500 MB of database and 1 GB of file
// storage. The release cache was 151,782 files and 1.37 GB in Supabase
// Storage -- over the storage limit on its own -- and Storage keeps a
// metadata row per file in Postgres, which was another 155 MB of the
// database. R2's free tier is 10 GB with no charge for reads, and keeps its
// bookkeeping to itself.
//
// Written through R2's S3-compatible API, signed with aws4fetch. Read by the
// app through the bucket's public address, and by the backend through the same
// signed API, so the backend never depends on the bucket being public.
//
// A row whose `payload_path` starts with `r2:` is in R2; anything else is
// still in Supabase Storage. The two coexist while the move runs.

import { AwsClient } from "npm:aws4fetch@1.0.20";

export const R2_PREFIX = "r2:";

export interface R2Config {
  accountID: string;
  accessKeyID: string;
  secretAccessKey: string;
  bucket: string;
}

/// An environment that cannot be read -- a test run without --allow-env --
/// is one with no R2, not a failure.
function readEnv(name: string): string | undefined {
  try {
    return Deno.env.get(name);
  } catch {
    return undefined;
  }
}

/// The four secrets, or null when any is missing -- in which case callers
/// keep using Supabase Storage, so a deploy before the secrets are set
/// changes nothing.
export function r2Config(env: (name: string) => string | undefined = readEnv): R2Config | null {
  const accountID = env("R2_ACCOUNT_ID")?.trim();
  const accessKeyID = env("R2_ACCESS_KEY_ID")?.trim();
  const secretAccessKey = env("R2_SECRET_ACCESS_KEY")?.trim();
  const bucket = env("R2_BUCKET")?.trim();
  if (!accountID || !accessKeyID || !secretAccessKey || !bucket) return null;
  return { accountID, accessKeyID, secretAccessKey, bucket };
}

export function isInR2(path: string | null | undefined): boolean {
  return typeof path === "string" && path.startsWith(R2_PREFIX);
}

/// "r2:releases/123.json" -> "releases/123.json".
export function r2Key(path: string): string {
  return path.startsWith(R2_PREFIX) ? path.slice(R2_PREFIX.length) : path;
}

/// Where any cached response other than a release lives in R2: a digest of
/// what identifies it, because a search's resource id is a whole query string
/// ("database/search?label=Warp Records&per_page=100") and not a safe key.
/// Deterministic, so fetching the same resource again overwrites its object
/// rather than adding one.
export async function cachePayloadKey(provider: string, resourceType: string, resourceID: string): Promise<string> {
  const digest = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(`${provider}\u001f${resourceType}\u001f${resourceID}`),
  );
  const hex = [...new Uint8Array(digest)].map((byte) => byte.toString(16).padStart(2, "0")).join("");
  return `cache/${provider}/${hex}.json`;
}

/// The object's address on R2's S3 endpoint. Each path segment is encoded on
/// its own, so the `/` between them stays a separator.
export function objectURL(config: R2Config, key: string): string {
  const encoded = key.split("/").map(encodeURIComponent).join("/");
  return `https://${config.accountID}.r2.cloudflarestorage.com/${encodeURIComponent(config.bucket)}/${encoded}`;
}

function client(config: R2Config): AwsClient {
  return new AwsClient({
    accessKeyId: config.accessKeyID,
    secretAccessKey: config.secretAccessKey,
    service: "s3",
    region: "auto",
  });
}

/// How long a copy may be served before being asked for again, matching what
/// Storage was told (release_cache.ts). A release is cached for sixty days and
/// rarely changes.
const CACHE_CONTROL = "public, max-age=3600";

export async function putObject(config: R2Config, key: string, body: string, contentType = "application/json"): Promise<void> {
  const response = await client(config).fetch(objectURL(config, key), {
    method: "PUT",
    body,
    headers: { "Content-Type": contentType, "Cache-Control": CACHE_CONTROL },
    signal: AbortSignal.timeout(30_000),
  });
  if (!response.ok) {
    // The body names the failure (SignatureDoesNotMatch, NoSuchBucket) and
    // carries no credential.
    const detail = (await response.text()).slice(0, 200);
    throw new Error(`r2 put ${key} answered ${response.status}: ${detail}`);
  }
  await response.body?.cancel();
}

/// The object's text, or null for one that is not there. Anything else --
/// a refusal, an outage -- throws, because it is not an answer about the key.
export async function getObject(config: R2Config, key: string): Promise<string | null> {
  const response = await client(config).fetch(objectURL(config, key), {
    method: "GET",
    signal: AbortSignal.timeout(30_000),
  });
  if (response.status === 404) {
    await response.body?.cancel();
    return null;
  }
  if (!response.ok) throw new Error(`r2 get ${key} answered ${response.status}`);
  return await response.text();
}
