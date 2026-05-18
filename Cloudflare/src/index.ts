import type { Env } from "./types";

export { UserRelay } from "./durable";

/// Entry point. Authenticates every request by `Authorization: Bearer <token>`
/// (the relay token both the Mac and the paired iPhone share, generated on the
/// Mac and delivered to the phone via the pairing QR/JSON).
///
/// Each unique token gets its own Durable Object instance — that DO holds:
///   - the persistent WebSocket to the Mac
///   - the list of currently-pending interventions
///   - the iPhone's APNs device token
///   - a buffered reply queue for when the Mac is briefly offline
export default {
  async fetch(req: Request, env: Env, _ctx: ExecutionContext): Promise<Response> {
    const url = new URL(req.url);

    // Health probe — useful for testing the deploy URL with curl.
    if (url.pathname === "/health" || url.pathname === "/") {
      return new Response(
        JSON.stringify({ ok: true, service: "page-relay", time: new Date().toISOString() }),
        { headers: { "content-type": "application/json" } }
      );
    }

    const auth = req.headers.get("Authorization") ?? "";
    const token = auth.startsWith("Bearer ") ? auth.slice("Bearer ".length).trim() : "";
    if (!token) {
      return new Response(JSON.stringify({ error: "missing_token" }), {
        status: 401,
        headers: { "content-type": "application/json" }
      });
    }

    // Route everything (REST + WS) to the per-user DO.
    const id = env.USERS.idFromName(token);
    const stub = env.USERS.get(id);
    return stub.fetch(req);
  }
};
