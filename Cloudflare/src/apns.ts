import type { ApnsEnvironment, Env } from "./types";

/// APNs HTTP/2 client. Signs an ES256 provider JWT with the configured .p8
/// key, then POSTs to api.{development.,}push.apple.com.
///
/// In Cloudflare Workers, `fetch()` to push.apple.com works because Apple
/// requires HTTP/2 and Workers' fetch negotiates it automatically.
///
/// Never throws: every failure (missing secrets, malformed key, network,
/// non-2xx) comes back as a PushResult so one bad device or a config mistake
/// can't break the relay's WebSocket path.

export interface PushRequest {
  pushType: "alert" | "background";
  payload: Record<string, unknown>;
  /// `apns-collapse-id` (≤ 64 bytes). Alerts only.
  collapseId?: string;
  /// `apns-expiration` as unix seconds. 0 / undefined = Apple's default.
  expiration?: number;
}

export interface PushTarget {
  token: string;
  env: ApnsEnvironment;
  /// False when the phone never told us which environment its token is for
  /// (older builds). Then a BadDeviceToken answer is retried once against
  /// the other host before the device is given up on.
  envKnown: boolean;
}

export interface PushResult {
  ok: boolean;
  /// HTTP status from Apple; 0 when nothing was sent.
  status: number;
  reason?: string;
  /// Apple says this token is dead for this app — remove the device.
  dropDevice: boolean;
  /// The environment the final attempt used (lets the caller learn it).
  env: ApnsEnvironment;
}

export class ApnsKeyError extends Error {}

export function apnsConfigured(env: Env): boolean {
  return !!(env.APNS_KEY_P8 && env.APNS_KEY_ID && env.APNS_TEAM_ID && env.APNS_BUNDLE_ID);
}

const DROP_REASONS = new Set(["BadDeviceToken", "DeviceTokenNotForTopic", "Unregistered"]);

/// Per-request ceiling for one APNs call.
const APNS_FETCH_TIMEOUT_MS = 4000;

export async function sendApnsPush(env: Env, target: PushTarget, req: PushRequest): Promise<PushResult> {
  if (!apnsConfigured(env)) {
    return { ok: false, status: 0, reason: "not_configured", dropDevice: false, env: target.env };
  }
  let result = await sendWithAuthRetry(env, target.token, target.env, req);
  if (!result.ok && !target.envKnown && result.status === 400 && result.reason === "BadDeviceToken") {
    // A development token sent to the production host (or vice versa) is
    // reported as BadDeviceToken. Try the other host before giving up.
    const other: ApnsEnvironment = target.env === "production" ? "development" : "production";
    result = await sendWithAuthRetry(env, target.token, other, req);
  }
  return result;
}

async function sendWithAuthRetry(
  env: Env, token: string, apnsEnv: ApnsEnvironment, req: PushRequest
): Promise<PushResult> {
  const first = await sendOnce(env, token, apnsEnv, req);
  if (first.status === 403 && (first.reason === "InvalidProviderToken" || first.reason === "ExpiredProviderToken")) {
    // Our cached JWT was rejected — mint a fresh one and retry once.
    invalidateJwt(env);
    return sendOnce(env, token, apnsEnv, req);
  }
  return first;
}

async function sendOnce(
  env: Env, token: string, apnsEnv: ApnsEnvironment, req: PushRequest
): Promise<PushResult> {
  const fail = (status: number, reason: string, dropDevice = false): PushResult =>
    ({ ok: false, status, reason, dropDevice, env: apnsEnv });

  let jwt: string;
  try {
    jwt = await getOrMintJwt(env);
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    console.error(`APNs: cannot sign provider token — ${msg}`);
    return fail(0, `key_error: ${msg}`);
  }

  const host = apnsEnv === "production" ? "api.push.apple.com" : "api.development.push.apple.com";
  const headers: Record<string, string> = {
    "authorization": `bearer ${jwt}`,
    "apns-topic": env.APNS_BUNDLE_ID,
    "apns-push-type": req.pushType,
    "apns-priority": req.pushType === "background" ? "5" : "10",
    "content-type": "application/json"
  };
  if (req.collapseId) headers["apns-collapse-id"] = req.collapseId;
  if (req.expiration !== undefined) headers["apns-expiration"] = String(Math.max(0, Math.floor(req.expiration)));

  let res: Response;
  try {
    res = await fetch(`https://${host}/3/device/${encodeURIComponent(token)}`, {
      method: "POST",
      headers,
      body: JSON.stringify(req.payload),
      // A page open answers only after its push: an APNs stall must not
      // outlast the hook's 6 s open request (a lost response used to leave
      // an orphaned page behind).
      ...(typeof AbortSignal?.timeout === "function" ? { signal: AbortSignal.timeout(APNS_FETCH_TIMEOUT_MS) } : {})
    });
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    console.warn(`APNs network error (${apnsEnv}, device …${token.slice(-8)}): ${msg}`);
    return fail(0, `network: ${msg}`);
  }
  if (res.ok) return { ok: true, status: res.status, dropDevice: false, env: apnsEnv };

  const text = await res.text().catch(() => "");
  let reason = "";
  try { reason = String((JSON.parse(text) as { reason?: unknown }).reason ?? ""); } catch { reason = text.slice(0, 100); }
  const apnsId = res.headers.get("apns-id") ?? "?";
  const drop = res.status === 410 || (res.status === 400 && DROP_REASONS.has(reason));
  console.warn(
    `APNs ${res.status} ${reason || "(no reason)"} — ${req.pushType} push to device …${token.slice(-8)} ` +
    `on ${host} (apns-id=${apnsId})${drop ? "; device will be removed" : ""}`
  );
  return fail(res.status, reason || `http_${res.status}`, drop);
}

// MARK: JWT minting

interface JwtCache {
  token: string;
  expiresAt: number;               // unix seconds
}
/// Keyed per team + key id, so rotating APNS_KEY_ID can't reuse a JWT
/// signed with the old key while the isolate is warm.
const jwtCache = new Map<string, JwtCache>();
/// Imported CryptoKeys keyed by the raw secret. Rejections are cached too:
/// a malformed secret fails the same way every time, and a fixed secret is
/// a different string (and usually a fresh isolate after `secret put`).
const keyCache = new Map<string, Promise<CryptoKey>>();

function jwtCacheKey(env: Env): string {
  return `${env.APNS_TEAM_ID ?? ""}.${env.APNS_KEY_ID ?? ""}`;
}

function invalidateJwt(env: Env): void {
  jwtCache.delete(jwtCacheKey(env));
}

async function getOrMintJwt(env: Env): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  const cacheKey = jwtCacheKey(env);
  const cached = jwtCache.get(cacheKey);
  // Apple wants the token refreshed at most every 20 min and no older than
  // 60 min. We mint at 50-min lifetimes and refresh a minute early.
  if (cached && cached.expiresAt > now + 60) return cached.token;

  const header = { alg: "ES256", kid: env.APNS_KEY_ID, typ: "JWT" };
  const claims = { iss: env.APNS_TEAM_ID, iat: now };
  const encoded =
    base64url(JSON.stringify(header)) + "." +
    base64url(JSON.stringify(claims));

  const key = await importPrivateKey(env.APNS_KEY_P8 ?? "");
  const signature = await crypto.subtle.sign(
    { name: "ECDSA", hash: { name: "SHA-256" } },
    key,
    new TextEncoder().encode(encoded)
  );
  // WebCrypto returns the raw IEEE-P1363 r||s form, which is what JWS ES256
  // requires — no DER conversion needed.
  const token = encoded + "." + base64urlBytes(new Uint8Array(signature));
  jwtCache.set(cacheKey, { token, expiresAt: now + 50 * 60 });
  return token;
}

function importPrivateKey(raw: string): Promise<CryptoKey> {
  let pending = keyCache.get(raw);
  if (!pending) {
    pending = (async () => {
      const body = normalizeP8(raw);
      const der = Uint8Array.from(atob(body), c => c.charCodeAt(0));
      try {
        return await crypto.subtle.importKey(
          "pkcs8", der, { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]
        );
      } catch (err) {
        const msg = err instanceof Error ? err.message : String(err);
        throw new ApnsKeyError(
          `APNS_KEY_P8 is not a P-256 PKCS#8 key (${msg}). Upload the AuthKey_XXXXXXXXXX.p8 ` +
          "file from developer.apple.com unchanged: cat AuthKey_XXXXXXXXXX.p8 | npx wrangler secret put APNS_KEY_P8"
        );
      }
    })();
    keyCache.set(raw, pending);
  }
  return pending;
}

/// Extracts the base64 body of a .p8 secret, tolerating the ways a PEM gets
/// mangled on its way into `wrangler secret put`: surrounding quotes,
/// literal "\n" escapes (CI secret stores, `echo` without -e), CRLF line
/// endings, and stray whitespace.
export function normalizeP8(raw: string): string {
  let s = (raw ?? "").trim();
  if (!s) throw new ApnsKeyError("APNS_KEY_P8 is not set");
  if (s.length >= 2 && (s[0] === "\"" || s[0] === "'") && s[s.length - 1] === s[0]) {
    s = s.slice(1, -1).trim();
  }
  s = s.replace(/\\r\\n|\\n|\\r/g, "\n").replace(/\r\n?/g, "\n");
  if (/-----BEGIN EC PRIVATE KEY-----/.test(s)) {
    throw new ApnsKeyError(
      "APNS_KEY_P8 is a SEC1 \"EC PRIVATE KEY\"; APNs keys are PKCS#8 (\"PRIVATE KEY\"). " +
      "Upload the original AuthKey_XXXXXXXXXX.p8, or convert with: " +
      "openssl pkcs8 -topk8 -nocrypt -in key.pem -out AuthKey.p8"
    );
  }
  if (/-----BEGIN ENCRYPTED PRIVATE KEY-----/.test(s)) {
    throw new ApnsKeyError(
      "APNS_KEY_P8 is encrypted; decrypt it first: openssl pkcs8 -in key.pem -nocrypt -out AuthKey.p8"
    );
  }
  const body = s.replace(/-----(BEGIN|END) [A-Z ]*-----/g, "").replace(/\s+/g, "");
  if (!body) throw new ApnsKeyError("APNS_KEY_P8 has no key body (only the BEGIN/END lines were saved?)");
  if (!/^[A-Za-z0-9+/]+={0,2}$/.test(body) || body.length % 4 === 1) {
    throw new ApnsKeyError(
      "APNS_KEY_P8 is not valid base64 — it was probably truncated or mangled when pasted. " +
      "Pipe the file instead: cat AuthKey_XXXXXXXXXX.p8 | npx wrangler secret put APNS_KEY_P8"
    );
  }
  return body;
}

function base64url(input: string): string {
  return base64urlBytes(new TextEncoder().encode(input));
}

function base64urlBytes(bytes: Uint8Array): string {
  let s = "";
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}
