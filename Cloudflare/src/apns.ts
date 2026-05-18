import type { Env } from "./types";

/// Sends an APNs push to a device token. Signs an ES256 JWT with the
/// configured .p8 key, then POSTs to api.{development,push}.apple.com over
/// HTTP/2.
///
/// In Cloudflare Workers, `fetch()` to push.apple.com works because Apple
/// requires HTTP/2 and Workers' fetch upgrades automatically.

interface JwtCache {
  token: string;
  expiresAt: number;
}
let cachedJwt: JwtCache | null = null;

interface PushOptions {
  silent?: boolean;
}

export async function sendApnsPush(
  env: Env,
  deviceToken: string,
  payload: Record<string, unknown>,
  opts: PushOptions = {}
): Promise<void> {
  const jwt = await getOrMintJwt(env);
  const host = env.APNS_ENV === "production"
    ? "api.push.apple.com"
    : "api.development.push.apple.com";
  const url = `https://${host}/3/device/${deviceToken}`;

  const headers: Record<string, string> = {
    "authorization": `bearer ${jwt}`,
    "apns-topic": env.APNS_BUNDLE_ID,
    "apns-push-type": opts.silent ? "background" : "alert",
    "apns-priority": opts.silent ? "5" : "10",
    "content-type": "application/json"
  };

  const res = await fetch(url, {
    method: "POST",
    headers,
    body: JSON.stringify(payload)
  });

  if (!res.ok) {
    const text = await res.text();
    const apnsId = res.headers.get("apns-id") ?? "?";
    console.warn(`APNs ${res.status} (apns-id=${apnsId}): ${text}`);
    // Invalidate cached JWT on 403 InvalidProviderToken so the next push remints.
    if (res.status === 403 && /InvalidProviderToken/.test(text)) {
      cachedJwt = null;
    }
    // Don't throw on individual delivery failures — the relay still works
    // even if the phone token has gone stale. Caller can decide to retry.
  }
}

// MARK: JWT minting

async function getOrMintJwt(env: Env): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  // Apple recommends rotating the token every < 60 minutes. We refresh at 50.
  if (cachedJwt && cachedJwt.expiresAt > now + 60) return cachedJwt.token;

  const header = { alg: "ES256", kid: env.APNS_KEY_ID, typ: "JWT" };
  const claims = { iss: env.APNS_TEAM_ID, iat: now };
  const encoded =
    base64url(JSON.stringify(header)) + "." +
    base64url(JSON.stringify(claims));

  const key = await importPrivateKey(env.APNS_KEY_P8);
  const signature = await crypto.subtle.sign(
    { name: "ECDSA", hash: { name: "SHA-256" } },
    key,
    new TextEncoder().encode(encoded)
  );
  // WebCrypto returns IEEE-P1363; APNs expects the same form, so we're good
  // (Apple's docs accept either, and IEEE-P1363 is what subtle outputs).
  const token = encoded + "." + base64urlBytes(new Uint8Array(signature));
  cachedJwt = { token, expiresAt: now + 50 * 60 };
  return token;
}

async function importPrivateKey(pem: string): Promise<CryptoKey> {
  const body = pem
    .replace(/-----BEGIN PRIVATE KEY-----/, "")
    .replace(/-----END PRIVATE KEY-----/, "")
    .replace(/\s+/g, "");
  const der = Uint8Array.from(atob(body), c => c.charCodeAt(0));
  return crypto.subtle.importKey(
    "pkcs8",
    der,
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["sign"]
  );
}

function base64url(input: string): string {
  return base64urlBytes(new TextEncoder().encode(input));
}

function base64urlBytes(bytes: Uint8Array): string {
  let s = "";
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}
