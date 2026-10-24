import type { Env } from "./types.ts";
import { apnsConfigured } from "./apns.ts";
import { errorResponse, jsonResponse } from "./durable.ts";
import { isoSeconds } from "./logic.ts";

export { UserRelay } from "./durable.ts";

/// Relay tokens are 43-char base64url strings (32 random bytes) generated on
/// the Mac. The floor only rejects obviously malformed or truncated tokens
/// (a typo would otherwise silently get its own empty relay); it isn't a
/// security boundary — anyone can mint a long string.
const MIN_TOKEN_LENGTH = 16;
const MAX_TOKEN_LENGTH = 512;

/// Entry point. Authenticates every request by `Authorization: Bearer <token>`
/// (the relay token both the Mac and the paired iPhone share, generated on the
/// Mac and delivered to the phone via the pairing QR/JSON).
///
/// Each unique token gets its own Durable Object instance — that DO holds:
///   - the persistent WebSockets to the Mac and the phone
///   - the pending interventions, recent history and closed-id tombstones
///   - the phones' APNs device tokens
///   - a buffered reply queue for when the Mac is briefly offline
export default {
  async fetch(req: Request, env: Env, _ctx: ExecutionContext): Promise<Response> {
    const url = new URL(req.url);

    // Health probe — useful for testing the deploy URL with curl. No
    // per-user data; `apnsConfigured` tells you whether the secrets are set.
    if (url.pathname === "/health" || url.pathname === "/") {
      return jsonResponse({
        ok: true,
        service: "page-relay",
        time: isoSeconds(Date.now()),
        apnsConfigured: apnsConfigured(env)
      });
    }

    const auth = req.headers.get("Authorization") ?? "";
    const token = auth.startsWith("Bearer ") ? auth.slice("Bearer ".length).trim() : "";
    if (!token) return errorResponse("missing_token", 401);
    if (token.length < MIN_TOKEN_LENGTH || token.length > MAX_TOKEN_LENGTH) {
      return errorResponse("invalid_token", 401);
    }

    // Route everything (REST + WS) to the per-user DO.
    const id = env.USERS.idFromName(token);
    const stub = env.USERS.get(id);
    return stub.fetch(req);
  }
};
