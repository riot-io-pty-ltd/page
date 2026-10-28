import type {
  ApnsEnvironment, Intervention, InterventionBackend, InterventionKind,
  InterventionSource, ReplyAction
} from "./types";

/// Pure decision logic for the relay: validation, reply gating, sync
/// reconciliation and push payloads. Nothing in here touches storage,
/// sockets or the network, so it can be unit-tested with plain node
/// (see test/). The Durable Object in durable.ts wires it to storage.

// MARK: limits & timings

export const MAX_ID_LENGTH = 200;
export const MAX_CONTEXT_LENGTH = 4000;
export const MAX_NAME_LENGTH = 500;
export const MAX_SUBTYPE_LENGTH = 100;
export const MAX_REASON_LENGTH = 64;
export const MAX_REPLY_TEXT_LENGTH = 16000;
export const MAX_DETAIL_LENGTH = 300;
export const MAX_METHOD_LENGTH = 100;
export const MAX_SYNC_IDS = 1000;
/// Prompt keys are agent tool_use ids ("toolu_01…", "call_…"). Anything
/// outside this shape is dropped rather than stored (the Mac then falls back
/// to its time-based staleness check).
const PROMPT_KEY_RE = /^[A-Za-z0-9_.:-]{1,200}$/;

/// A free-text reply may still reach a session whose page closed this
/// recently (the "cascade closed it a second before I hit send" race).
/// Older than this, the reply is refused with 410 — whatever the session is
/// doing now is not what the user was answering.
export const CLOSED_REPLY_WINDOW_MS = 10 * 60 * 1000;
/// Queued replies to live pages are dropped (and marked failed) after this.
/// Typing an hour-old answer into a terminal is worse than not typing it.
export const QUEUE_TTL_MS = 60 * 60 * 1000;
/// `sync` never closes a page that got a reply this recently, so it can't
/// race an injection that's still in flight on the Mac. A reply the Worker
/// handed to the Mac (or still holds in the queue) is protected for longer —
/// until DELIVERY_ACK_TIMEOUT_MS after it was forwarded — see
/// selectStaleForSync.
export const SYNC_REPLY_GRACE_MS = 2 * 60 * 1000;
/// `sync` never closes a page the Worker received this recently: the Mac
/// may have computed its openIds snapshot just before detecting it.
export const SYNC_OPEN_GRACE_MS = 30 * 1000;
/// Closed ids are remembered this long so a late or replayed open can't
/// resurrect a page that was already dealt with.
export const TOMBSTONE_TTL_MS = 24 * 60 * 60 * 1000;

/// A reply handed to the Mac that never got a `reply.injected` back (the Mac
/// crashed mid-injection, or a half-open socket swallowed the frame) stops
/// blocking retries after this long. Longer than the Mac's 15-minute ceiling
/// for a background `claude --resume --print`, so a slow-but-working delivery
/// is never double-sent.
export const DELIVERY_ACK_TIMEOUT_MS = 20 * 60 * 1000;

/// A blocking hook never waits longer than this (page-notify.sh clamps
/// PAGE_HOOK_TIMEOUT to 3600 s). Used when the hook didn't say how long it
/// would wait (`holdSeconds`), e.g. older hook scripts.
export const HOOK_MAX_HOLD_MS = 3600 * 1000;
/// Slack on top of the hook's own wait before the Worker treats its page as
/// orphaned: the wait starts after the open returns (up to 6 s), and the
/// last poll plus the close can run ~25 s past the deadline.
export const HOOK_EXPIRY_MARGIN_MS = 2 * 60 * 1000;
/// Notification-hook pages (`hook-`) have no owner that ever closes them
/// (the hook exits right after paging, and the Mac's sync skips them). They
/// expire after this long — well past an overnight absence, so a prompt
/// that is still on screen in the morning keeps its card.
export const HOOK_PAGE_MAX_AGE_MS = 24 * 60 * 60 * 1000;

const KINDS: ReadonlySet<string> = new Set<InterventionKind>([
  "permission", "plan", "question", "idle", "approval", "user_input", "rate_limit"
]);
const SOURCES: ReadonlySet<string> = new Set<InterventionSource>([
  "terminal", "desktop", "vscode", "exec", "remote", "unknown"
]);
const ACTIONS: ReadonlySet<string> = new Set<ReplyAction>([
  "approve", "deny", "carry_on", "custom"
]);
/// Actions that answer a specific prompt. They must never be applied to a
/// page that has closed — the prompt on screen now may be a different one.
const DECISION_ACTIONS: ReadonlySet<string> = new Set(["approve", "deny", "carry_on"]);

// MARK: id conventions

/// Blocking PreToolUse hook pages. The hook polls for the reply itself, so
/// the Worker never forwards these to the Mac, and supersede/cascade/sync
/// leave them alone (the hook closes them via its exit trap).
export function isHookPreId(id: string): boolean {
  return id.startsWith("hookpre-");
}

/// Any hook-owned page (notification hook or blocking hook). `sync` frames
/// from the Mac don't know about these, so they never close them.
export function isHookOwnedId(id: string): boolean {
  return id.startsWith("hook-") || id.startsWith("hookpre-");
}

/// A page whose reply is read by a waiting hook rather than delivered by the
/// Mac: `hookpre-` pages, and pages opened by the v1 blocking PreToolUse hook
/// (`hookBlocking`, set on ingest — see isLegacyBlockingHookOpen).
export function isHookBlocking(iv: Pick<Intervention, "id" | "hookBlocking">): boolean {
  return isHookPreId(iv.id) || iv.hookBlocking === true;
}

/// The v1 hook script (User-Agent `page-hook/1.x`) was a blocking PreToolUse
/// hook that used `hook-` ids, sent no `backend`, and polled GET
/// /interventions for `repliedAction` itself. Its PreToolUse pages are the
/// only ones with kind "permission"; its Notification pages are "question"
/// and still need the Mac to type the reply, so they are NOT matched. Without
/// this the Worker forwarded those replies to the Mac, whose "prompt is no
/// longer showing" failure then erased the answer the hook was polling for.
export function isLegacyBlockingHookOpen(raw: unknown, userAgent: string | undefined): boolean {
  if (!isObject(raw) || !userAgent || !/^page-hook\/1\./.test(userAgent)) return false;
  return typeof raw.id === "string" && raw.id.startsWith("hook-")
    && raw.kind === "permission" && raw.backend === undefined;
}

/// The wait a blocking hook announced in its open (`holdSeconds`), in ms,
/// clamped to the hook's own 5–3600 s range; undefined when absent/invalid.
export function hookHoldMs(raw: unknown): number | undefined {
  if (!isObject(raw) || typeof raw.holdSeconds !== "number" || !Number.isFinite(raw.holdSeconds)) return undefined;
  return Math.min(Math.max(Math.floor(raw.holdSeconds), 5), 3600) * 1000;
}

/// When a pending hook-owned page is considered abandoned (ms epoch), or
/// undefined for pages something else closes (Mac pages: the Mac and sync).
///  - blocking hook pages: the hook's announced wait (or the 3600 s cap) plus
///    HOOK_EXPIRY_MARGIN_MS. The hook's deadline is wall-clock, so past this
///    no live hook can still be polling; whatever is left was orphaned (a
///    lost open response, a failed close, a SIGKILL).
///  - notification hook pages: HOOK_PAGE_MAX_AGE_MS after they arrived.
export function hookPageExpiresAt(rec: PendingRecord): number | undefined {
  if (isHookBlocking(rec.iv)) return rec.hookExpiresAt ?? rec.receivedAt + HOOK_MAX_HOLD_MS + HOOK_EXPIRY_MARGIN_MS;
  if (isHookOwnedId(rec.iv.id)) return rec.receivedAt + HOOK_PAGE_MAX_AGE_MS;
  return undefined;
}

export function isExpiredHookPage(rec: PendingRecord, now: number): boolean {
  const at = hookPageExpiresAt(rec);
  return at !== undefined && now >= at;
}

/// Close reasons with which a blocking hook's page ends because the prompt
/// was actually dealt with. Any other reason (timeout, hook_exited,
/// hook_fallback, user_returned, hook_lost, …) means the agent may still be
/// blocked on that prompt.
export function hookCloseResolvedPrompt(reason: string): boolean {
  return reason === "replied" || reason === "resolved_elsewhere";
}

// MARK: hook push dedupe

/// How recent a same-session alert must be for a blocking-hook page to go
/// out quietly instead of buzzing again.
export const HOOK_DEDUPE_WINDOW_MS = 30 * 1000;

/// Kinds that block the agent until someone answers (an approval or a
/// question). Idle and rate-limit pages are a different event.
export function isBlockingKind(kind: InterventionKind): boolean {
  return kind === "permission" || kind === "plan" || kind === "approval"
    || kind === "question" || kind === "user_input";
}

/// How to push a newly opened page, given the pages pending before it.
///  - "none":  a non-hook page for a session whose blocking hook (hookpre-)
///             is already paging and waiting for the phone. It's the same
///             prompt seen by the Mac detector or the Notification hook; the
///             hook page is the one that can act on the reply. Stored and
///             shown live, but no second alert.
///  - "quiet": a hook page right after (< 30 s) an audible alert for the same
///             session's blocking prompt — most likely the same prompt. It
///             still replaces that page (supersede) and its banner, but
///             without sound, so one prompt doesn't buzz twice.
///  - "alert": everything else.
/// Blocking-hook records past their expiry are orphans and count for nothing.
export function decideOpenPush(iv: Intervention, pending: PendingRecord[], now: number): "alert" | "quiet" | "none" {
  const sameSession = pending.filter(r =>
    r.iv.sessionId === iv.sessionId && r.iv.id !== iv.id && !isExpiredHookPage(r, now));
  if (!isHookBlocking(iv)) {
    return sameSession.some(r => isHookBlocking(r.iv)) ? "none" : "alert";
  }
  if (!isBlockingKind(iv.kind)) return "alert";
  const recentAlert = sameSession.some(r =>
    !isHookBlocking(r.iv) && isBlockingKind(r.iv.kind)
    && r.alertedAt !== undefined && now - r.alertedAt >= 0 && now - r.alertedAt < HOOK_DEDUPE_WINDOW_MS
  );
  return recentAlert ? "quiet" : "alert";
}

// MARK: storage records & keys

export interface PendingRecord {
  iv: Intervention;
  /// When the Worker received the open (ms epoch). Internal; never sent.
  receivedAt: number;
  /// When an audible alert push went out for this page (ms epoch). Only
  /// read by the hook push dedupe; a record rewritten without it just means
  /// the next hook page buzzes, which is the safe direction.
  alertedAt?: number;
  /// Blocking hook pages: when the page counts as orphaned (ms epoch),
  /// from the hook's announced wait. See hookPageExpiresAt.
  hookExpiresAt?: number;
  /// Blocking hook pages: ids of same-session pages this one replaced. They
  /// are archived without a tombstone and put back if the hook gives up
  /// without the prompt being answered (the agent is still blocked on it,
  /// and the Mac never re-sends a page it already sent).
  shadowed?: string[];
}

export interface Tombstone {
  closedAt: string;
  reason: string;
  expiresAt: number;               // ms epoch
}

/// Inverted-timestamp base for history keys: lexical order of
/// `h:<INV_BASE - closedMs>` is newest-first, so `storage.list({prefix,
/// limit})` returns the most recent entries without a sort.
const INV_BASE = 9_999_999_999_999;

function pad13(n: number): string {
  return String(Math.max(0, Math.min(INV_BASE, Math.floor(n)))).padStart(13, "0");
}

export const keys = {
  meta: "meta",
  legacyState: "state.v1",
  pending: (id: string) => `p:${id}`,
  history: (closedMs: number, id: string) => `h:${pad13(INV_BASE - closedMs)}:${id}`,
  historyIndex: (id: string) => `hx:${id}`,
  queue: (queuedAt: number, id: string) => `q:${pad13(queuedAt)}:${id}`,
  device: (token: string) => `dev:${token}`,
  tomb: (id: string) => `tomb:${id}`
} as const;

export const prefixes = {
  pending: "p:",
  history: "h:",
  historyIndex: "hx:",
  queue: "q:",
  device: "dev:",
  tomb: "tomb:"
} as const;

/// Recovers the intervention id from a history or queue key (both are
/// `<prefix><13 digits>:<id>`; ids may themselves contain colons).
export function idFromTimeKey(key: string, prefix: string): string {
  return key.slice(prefix.length + 13 + 1);
}

// MARK: string helpers

/// ISO 8601 with whole seconds ("2026-10-24T12:00:00Z"). Every timestamp the
/// Worker writes uses this form: phones in the field decode dates with
/// Swift's `.iso8601` strategy, which rejects fractional seconds, so a
/// `toISOString()` value ("…:00.000Z") would make the whole inbox fail to decode.
export function isoSeconds(ms: number): string {
  return new Date(ms).toISOString().replace(/\.\d{3}Z$/, "Z");
}

/// Truncates by UTF-16 code units without splitting a surrogate pair.
export function truncate(s: string, max: number, ellipsis = false): string {
  if (s.length <= max) return s;
  let cut = ellipsis ? max - 1 : max;
  const code = s.charCodeAt(cut - 1);
  if (code >= 0xd800 && code <= 0xdbff) cut -= 1;
  return s.slice(0, Math.max(0, cut)) + (ellipsis ? "…" : "");
}

function coerceString(v: unknown): string {
  if (typeof v === "string") return v;
  if (v === null || v === undefined) return "";
  if (typeof v === "number" || typeof v === "boolean") return String(v);
  try { return JSON.stringify(v) ?? ""; } catch { return ""; }
}

function basename(path: string): string {
  return path.split("/").filter(Boolean).pop() ?? "";
}

function isObject(v: unknown): v is Record<string, unknown> {
  return typeof v === "object" && v !== null && !Array.isArray(v);
}

// MARK: ingest validation

export type NormalizeResult =
  | { ok: true; iv: Intervention }
  | { ok: false; error: string };

/// Validates and canonicalises an inbound `intervention.opened` payload.
/// Lenient where deployed clients might differ (coerce, truncate, default),
/// strict only where the relay can't function (id/sessionId). Builds the
/// stored object field by field so unknown or Worker-managed fields
/// (repliedAt, deliveryStatus, ...) sent by a client are never trusted.
export function normalizeIntervention(
  raw: unknown, nowMs: number, opts: { userAgent?: string } = {}
): NormalizeResult {
  if (!isObject(raw)) return { ok: false, error: "invalid_payload" };
  const { id, sessionId } = raw;
  if (typeof id !== "string" || id.length === 0 || id.length > MAX_ID_LENGTH) {
    return { ok: false, error: "invalid_id" };
  }
  if (typeof sessionId !== "string" || sessionId.length === 0 || sessionId.length > MAX_ID_LENGTH) {
    return { ok: false, error: "invalid_sessionId" };
  }
  const cwd = truncate(coerceString(raw.cwd), MAX_NAME_LENGTH);
  const projectName = truncate(
    coerceString(raw.projectName).trim() || basename(cwd) || "Agent", MAX_NAME_LENGTH
  );
  const kind: InterventionKind =
    typeof raw.kind === "string" && KINDS.has(raw.kind) ? raw.kind as InterventionKind : "question";
  const context = truncate(coerceString(raw.context), MAX_CONTEXT_LENGTH, true);
  const parsedOpened = typeof raw.openedAt === "string" ? Date.parse(raw.openedAt) : NaN;
  // Re-emitted in canonical form (UTC, whole seconds) so phones decode it
  // and string order matches time order.
  const openedAt = isoSeconds(Number.isFinite(parsedOpened) ? parsedOpened : nowMs);
  const backend: InterventionBackend =
    raw.backend === "claude" || raw.backend === "codex" ? raw.backend
      : id.startsWith("codex-") ? "codex" : "claude";
  const source: InterventionSource =
    typeof raw.source === "string" && SOURCES.has(raw.source) ? raw.source as InterventionSource
      : raw.source === undefined || raw.source === null ? "terminal" : "unknown";

  const iv: Intervention = { id, sessionId, cwd, projectName, kind, context, openedAt, backend, source };
  if (typeof raw.subtype === "string" && raw.subtype.length > 0) {
    iv.subtype = truncate(raw.subtype, MAX_SUBTYPE_LENGTH);
  }
  const promptKey = normalizePromptKey(raw.promptKey);
  if (promptKey) iv.promptKey = promptKey;
  if (isLegacyBlockingHookOpen(raw, opts.userAgent)) iv.hookBlocking = true;
  return { ok: true, iv };
}

/// The hook's `promptKey` (the pending tool_use id), or undefined when it is
/// absent or doesn't look like an id.
export function normalizePromptKey(raw: unknown): string | undefined {
  return typeof raw === "string" && PROMPT_KEY_RE.test(raw) ? raw : undefined;
}

export function normalizeCloseReason(raw: unknown): string {
  return typeof raw === "string" && raw.length > 0 ? truncate(raw, MAX_REASON_LENGTH) : "closed";
}

// MARK: replies

export type ParsedReply =
  | { ok: true; text: string; action: ReplyAction | null }
  | { ok: false; status: number; error: string };

/// Validates a phone reply body. An empty reply (no text and no decisive
/// action) is refused: tapping a banner to open the app used to post
/// `{text:"", action:null}`, which the Mac turned into "carry on".
export function parseReplyBody(body: unknown): ParsedReply {
  if (!isObject(body)) return { ok: false, status: 400, error: "bad_request" };
  let text: string;
  if (body.text === undefined || body.text === null) text = "";
  else if (typeof body.text === "string") text = body.text;
  else if (typeof body.text === "number" || typeof body.text === "boolean") text = String(body.text);
  else return { ok: false, status: 400, error: "bad_request" };
  if (text.length > MAX_REPLY_TEXT_LENGTH) return { ok: false, status: 413, error: "reply_too_long" };

  let action: ReplyAction | null;
  if (body.action === undefined || body.action === null) action = null;
  else if (typeof body.action === "string" && ACTIONS.has(body.action)) action = body.action as ReplyAction;
  else return { ok: false, status: 400, error: "invalid_action" };

  if (text.trim().length === 0 && (action === null || action === "custom")) {
    return { ok: false, status: 400, error: "empty_reply" };
  }
  return { ok: true, text, action };
}

/// A reply is "taken" unless its delivery failed (then the user may retry)
/// or it was forwarded to the Mac and never acknowledged within
/// DELIVERY_ACK_TIMEOUT_MS. Queued replies (Mac offline) stay taken until
/// the queue TTL fails them.
export function hasLiveReply(iv: Intervention, now: number = Date.now()): boolean {
  if (!iv.repliedAt || iv.deliveryStatus === "failed") return false;
  if (iv.deliveryStatus === "pending" && iv.deliveryForwardedAt) {
    const forwarded = Date.parse(iv.deliveryForwardedAt);
    if (Number.isFinite(forwarded) && now - forwarded > DELIVERY_ACK_TIMEOUT_MS) return false;
  }
  return true;
}

export interface ReplyContext {
  pending?: Intervention;
  /// The archived (closed) record, when the id isn't pending.
  closed?: Intervention;
  tomb?: Tombstone;
  /// Another pending intervention for the same session, if any.
  currentIdForSession?: string;
  action: ReplyAction | null;
  now: number;
}

export type ReplyDecision =
  | { ok: false; status: number; body: Record<string, unknown> }
  | { ok: true; target: Intervention; closed: boolean; forwardToMac: boolean };

/// Decides what to do with a phone reply. Order matters:
///  1. pending: 409 if it already has a live reply, else accept;
///  2. closed (archived): 409 if already replied, else 410 unless it's free
///     text to a page that closed < 10 min ago and the session hasn't moved
///     on to a newer prompt;
///  3. tombstoned only (never archived): 410;
///  4. unknown: 404.
export function decideReply(ctx: ReplyContext): ReplyDecision {
  const { pending, closed, tomb, action, now } = ctx;
  if (pending) {
    if (hasLiveReply(pending, ctx.now)) return alreadyReplied(pending);
    if (pending.hookBlocking === true && !isHookPreId(pending.id) && action !== "approve" && action !== "deny") {
      // The v1 hook turns ANY other reply (typed text, carry on, anything
      // unknown) into "allow". Only an explicit Approve or Deny is safe.
      return {
        ok: false, status: 422,
        body: {
          error: "approve_or_deny_only",
          why: "This page comes from an older Page hook that can only apply Approve or Deny. Update it in Page ▸ Integrations ▸ Install agent hooks…"
        }
      };
    }
    return { ok: true, target: pending, closed: false, forwardToMac: !isHookBlocking(pending) };
  }
  if (closed) {
    if (hasLiveReply(closed, ctx.now)) return alreadyReplied(closed);
    const gone = (why: string): ReplyDecision => ({
      ok: false, status: 410,
      body: {
        error: "gone", why,
        closeReason: closed.closeReason, closedAt: closed.closedAt,
        ...(ctx.currentIdForSession ? { currentId: ctx.currentIdForSession } : {})
      }
    });
    // The blocking hook has already decided and exited.
    if (isHookBlocking(closed)) return gone("hook_finished");
    if (closed.closeReason === "superseded") return gone("superseded");
    const closedMs = closed.closedAt ? Date.parse(closed.closedAt) : NaN;
    if (!Number.isFinite(closedMs) || now - closedMs > CLOSED_REPLY_WINDOW_MS) return gone("expired");
    if (action !== null && DECISION_ACTIONS.has(action)) return gone("prompt_closed");
    if (ctx.currentIdForSession) return gone("session_moved_on");
    return { ok: true, target: closed, closed: true, forwardToMac: true };
  }
  if (tomb) {
    return {
      ok: false, status: 410,
      body: { error: "gone", why: "closed", closeReason: tomb.reason, closedAt: tomb.closedAt }
    };
  }
  return { ok: false, status: 404, body: { error: "no_such_intervention" } };
}

function alreadyReplied(iv: Intervention): ReplyDecision {
  return {
    ok: false, status: 409,
    body: { error: "already_replied", repliedAt: iv.repliedAt, deliveryStatus: iv.deliveryStatus }
  };
}

// MARK: retract (reply-retract-v1)

/// GET /status feature: DELETE /reply/<id> takes back a reply that is still
/// waiting in the queue for an offline Mac.
export const REPLY_RETRACT_FEATURE = "reply-retract-v1";
/// The record's deliveryDetail and the reply.result detail after a retract.
export const RETRACTED_DETAIL = "Deleted — not sent";
export const RETRACTED_METHOD = "retracted";

export interface RetractContext {
  /// A q: entry for this id exists (and will be deleted on "deleted").
  queued: boolean;
  /// The page wherever it lives (pending or archived).
  iv?: Intervention;
  /// Tombstone, looked up only when the page isn't stored at all.
  tomb?: Tombstone;
}

export type RetractDecision = {
  kind: "deleted" | "too_late" | "hook_held" | "nothing" | "not_found";
  status: number;
  body: Record<string, unknown>;
};

/// Decides a phone's DELETE /reply/<id>. Only a reply still sitting in the
/// relay's queue can be taken back; anything else has left the relay (or,
/// for a blocking hook, may have been read already) and can't be.
/// Order matters:
///  1. a queue entry exists: delete it (even when the page record is gone or
///     the entry has expired but not been swept — either way nothing was sent);
///  2. delivered: 409 too_late / delivered;
///  3. pending and forwarded: 409 too_late / forwarded — also after the
///     20-min ack timeout, since the Mac may still type it;
///  4. pending on a blocking-hook page: 409 hook_held (the hook may already
///     have polled it from GET /interventions);
///  5. no live reply (none, or failed): 200 nothing;
///  6. pending but neither queued, forwarded nor hook-held: 409 too_late /
///     not_held (the relay doesn't hold it, so it can't vouch it wasn't sent);
///  7. tombstoned only: 200 nothing; unknown: 404.
export function decideRetract(ctx: RetractContext): RetractDecision {
  const { queued, iv, tomb } = ctx;
  if (queued) return { kind: "deleted", status: 200, body: { ok: true, retracted: true } };
  const nothing: RetractDecision = { kind: "nothing", status: 200, body: { ok: true, retracted: false, nothing: true } };
  if (!iv) {
    return tomb ? nothing : { kind: "not_found", status: 404, body: { error: "no_such_intervention" } };
  }
  if (iv.deliveryStatus === "delivered") return tooLate("delivered");
  if (!iv.repliedAt || iv.deliveryStatus !== "pending") return nothing;
  if (iv.deliveryForwardedAt) return tooLate("forwarded", { deliveryForwardedAt: iv.deliveryForwardedAt });
  if (isHookBlocking(iv)) return { kind: "hook_held", status: 409, body: { error: "hook_held" } };
  return tooLate("not_held");
}

function tooLate(stage: "delivered" | "forwarded" | "not_held", extra: Record<string, unknown> = {}): RetractDecision {
  return { kind: "too_late", status: 409, body: { error: "too_late", stage, ...extra } };
}

/// Whether a queued reply is still worth sending at `now`.
export function queueEntryExpired(entry: { queuedAt: number; closed?: boolean }, now: number): boolean {
  const ttl = entry.closed ? CLOSED_REPLY_WINDOW_MS : QUEUE_TTL_MS;
  return now - entry.queuedAt > ttl;
}

// MARK: Mac frames

export interface ParsedInjected {
  interventionId: string;
  method: string;
  success: boolean;
  detail: string;
}

/// Parses `reply.injected`. The free-form `output` field is deliberately
/// ignored: it can hold terminal or `claude --print` output, which must not
/// be stored, logged or shown on the phone. v2 Macs send a short `detail`.
export function parseReplyInjected(raw: unknown): ParsedInjected | null {
  if (!isObject(raw) || typeof raw.interventionId !== "string" || !raw.interventionId) return null;
  const success = raw.success === true;
  const method = typeof raw.method === "string" && raw.method
    ? truncate(raw.method, MAX_METHOD_LENGTH) : "unknown";
  const detail = typeof raw.detail === "string" && raw.detail.trim()
    ? truncate(raw.detail.trim(), MAX_DETAIL_LENGTH, true)
    : success ? "Delivered to your Mac" : "Your Mac couldn't deliver the reply";
  return { interventionId: raw.interventionId, method, success, detail };
}

export interface HeartbeatForecast {
  cutoff: number;                  // low-battery cutoff, %
  minutes: number;                 // to the cutoff at the current drain
  drainPerHour: number;            // percentage points per hour
}

export interface UsageWindow {
  pct: number;                     // 0-100 used
  resetsAt?: string;               // ISO, whole seconds
}

export interface HeartbeatUsage {
  fiveHour?: UsageWindow;
  sevenDay?: UsageWindow;
  hitAt?: string;                  // forecast: when 100% is reached
  updatedAt?: string;              // when the Mac last read the numbers
}

export interface ParsedHeartbeat {
  ts: string;
  activeSessions: number;
  battery: number;                 // -1 when unknown
  onAC?: boolean;
  /// v4, all optional: sessions mid-turn, battery forecast, Claude usage.
  working?: number;
  forecast?: HeartbeatForecast;
  usage?: HeartbeatUsage;
}

function finiteNumber(v: unknown, min: number, max: number): number | undefined {
  return typeof v === "number" && Number.isFinite(v) ? Math.min(max, Math.max(min, v)) : undefined;
}

/// An ISO timestamp re-emitted in whole seconds, or undefined.
function isoField(v: unknown): string | undefined {
  if (typeof v !== "string" || v.length > 64) return undefined;
  const ms = Date.parse(v);
  return Number.isFinite(ms) ? isoSeconds(ms) : undefined;
}

export function parseForecast(raw: unknown): HeartbeatForecast | undefined {
  if (!isObject(raw)) return undefined;
  const cutoff = finiteNumber(raw.cutoff, 0, 100);
  const minutes = finiteNumber(raw.minutes, 0, 7 * 24 * 60);
  const drain = finiteNumber(raw.drainPerHour, 0, 1000);
  if (cutoff === undefined || minutes === undefined || drain === undefined) return undefined;
  return { cutoff: Math.round(cutoff), minutes: Math.round(minutes), drainPerHour: Math.round(drain * 10) / 10 };
}

function parseUsageWindow(raw: unknown): UsageWindow | undefined {
  if (!isObject(raw)) return undefined;
  const pct = finiteNumber(raw.pct, 0, 100);
  if (pct === undefined) return undefined;
  const w: UsageWindow = { pct: Math.round(pct * 10) / 10 };
  const resetsAt = isoField(raw.resetsAt);
  if (resetsAt) w.resetsAt = resetsAt;
  return w;
}

export function parseUsage(raw: unknown): HeartbeatUsage | undefined {
  if (!isObject(raw)) return undefined;
  const u: HeartbeatUsage = {};
  const five = parseUsageWindow(raw.fiveHour);
  const seven = parseUsageWindow(raw.sevenDay);
  if (five) u.fiveHour = five;
  if (seven) u.sevenDay = seven;
  const hitAt = isoField(raw.hitAt);
  const updatedAt = isoField(raw.updatedAt);
  if (hitAt) u.hitAt = hitAt;
  if (updatedAt) u.updatedAt = updatedAt;
  return five || seven ? u : undefined;
}

export function parseHeartbeat(raw: unknown, nowMs: number): ParsedHeartbeat {
  const p = isObject(raw) ? raw : {};
  const sessions = typeof p.activeSessions === "number" && Number.isFinite(p.activeSessions)
    ? Math.max(0, Math.floor(p.activeSessions)) : 0;
  const battery = typeof p.battery === "number" && Number.isFinite(p.battery) && p.battery >= 0
    ? Math.min(100, p.battery) : -1;
  const hb: ParsedHeartbeat = {
    ts: typeof p.ts === "string" && p.ts ? truncate(p.ts, 64) : isoSeconds(nowMs),
    activeSessions: sessions,
    battery
  };
  if (typeof p.onAC === "boolean") hb.onAC = p.onAC;
  const working = finiteNumber(p.working, 0, 10000);
  if (working !== undefined) hb.working = Math.floor(working);
  const forecast = parseForecast(p.forecast);
  if (forecast) hb.forecast = forecast;
  const usage = parseUsage(p.usage);
  if (usage) hb.usage = usage;
  return hb;
}

export interface ParsedSync {
  backend: InterventionBackend;
  openIds: Set<string>;
}

export function parseSync(raw: unknown): ParsedSync | null {
  if (!isObject(raw)) return null;
  if (raw.backend !== "claude" && raw.backend !== "codex") return null;
  if (!Array.isArray(raw.openIds)) return null;
  const openIds = new Set<string>();
  for (const id of raw.openIds.slice(0, MAX_SYNC_IDS)) {
    if (typeof id === "string" && id) openIds.add(id);
  }
  return { backend: raw.backend, openIds };
}

/// Pending interventions a `sync` frame proves stale: same backend, not in
/// the Mac's open set, not hook-owned, not just replied to, not just opened.
/// A reply whose delivery is still unacknowledged keeps its page until
/// DELIVERY_ACK_TIMEOUT_MS after it was forwarded (a background `claude
/// --resume --print` can take 15 min, and a queued reply is only forwarded
/// when the Mac comes back, long after repliedAt): closing it as "stale"
/// (which archives nothing) would drop the delivery result on the floor.
export function selectStaleForSync(pending: PendingRecord[], sync: ParsedSync, now: number): string[] {
  const stale: string[] = [];
  for (const { iv, receivedAt } of pending) {
    if ((iv.backend ?? "claude") !== sync.backend) continue;
    if (sync.openIds.has(iv.id)) continue;
    if (isHookOwnedId(iv.id) || isHookBlocking(iv)) continue;
    if (now - receivedAt < SYNC_OPEN_GRACE_MS) continue;
    const repliedMs = iv.repliedAt ? Date.parse(iv.repliedAt) : NaN;
    if (Number.isFinite(repliedMs) && now - repliedMs < SYNC_REPLY_GRACE_MS) continue;
    if (iv.repliedAt && iv.deliveryStatus === "pending") {
      const fwdMs = Date.parse(iv.deliveryForwardedAt ?? iv.repliedAt);
      if (Number.isFinite(fwdMs) && now - fwdMs < DELIVERY_ACK_TIMEOUT_MS) continue;
    }
    stale.push(iv.id);
  }
  return stale;
}

// MARK: live sessions (sessions-v1)

/// Live sessions (docs/SESSIONS-PROTOCOL.md). The Worker never decrypts
/// these frames and never stores them: it checks the envelope's shape and
/// size, forwards it and forgets it. Advertised in GET /status `features`.
export const SESSIONS_FEATURE = "sessions-v1";
/// Largest serialised `sessions.update` payload a Mac may send.
export const MAX_SESSIONS_UPDATE_BYTES = 256 * 1024;
/// Largest POST /sessions/command body.
export const MAX_SESSIONS_COMMAND_BYTES = 64 * 1024;
/// Commands forwarded per minute per relay (an in-memory token bucket).
export const SESSIONS_COMMAND_RATE = 120;
export const SESSIONS_COMMAND_WINDOW_MS = 60 * 1000;
/// AES-GCM nonces are 12 bytes (16 base64url chars); generous headroom.
const MAX_SESSIONS_NONCE_LENGTH = 64;
/// base64url, unpadded or padded (readers accept both).
const B64URL_RE = /^[A-Za-z0-9_-]+={0,2}$/;

/// The only part of a sessions-v1 frame the Worker sees: AES-GCM nonce and
/// ciphertext‖tag, both base64url.
export interface SessionsEnvelope {
  v: 1;
  n: string;
  c: string;
}

/// Shape check for `e`. Rebuilt field by field, so nothing but `{v, n, c}`
/// is ever relayed.
export function parseSessionsEnvelope(raw: unknown): SessionsEnvelope | null {
  if (!isObject(raw) || raw.v !== 1) return null;
  const { n, c } = raw;
  if (typeof n !== "string" || typeof c !== "string") return null;
  if (n.length > MAX_SESSIONS_NONCE_LENGTH || !B64URL_RE.test(n) || !B64URL_RE.test(c)) return null;
  return { v: 1, n, c };
}

export type ParsedSessionsUpdate =
  | { ok: true; e: SessionsEnvelope; bytes: number }
  | { ok: false; error: "too_large" | "invalid_envelope" };

/// `sessions.update` payload `{e}` from the Mac. `bytes` is the serialised
/// payload size: the only thing about the frame that may be logged.
export function parseSessionsUpdate(raw: unknown): ParsedSessionsUpdate {
  if (!isObject(raw)) return { ok: false, error: "invalid_envelope" };
  const bytes = utf8Length(JSON.stringify(raw));
  if (bytes > MAX_SESSIONS_UPDATE_BYTES) return { ok: false, error: "too_large" };
  const e = parseSessionsEnvelope(raw.e);
  return e ? { ok: true, e, bytes } : { ok: false, error: "invalid_envelope" };
}

/// POST /sessions/command body `{e}` (its size is checked while reading it).
export function parseSessionsCommand(body: unknown): SessionsEnvelope | null {
  return isObject(body) ? parseSessionsEnvelope(body.e) : null;
}

export interface TokenBucket {
  tokens: number;
  at: number;                      // ms epoch of the last refill
}

/// Takes one token from `bucket` (full when undefined), refilling at
/// `capacity` per `windowMs`. Returns whether the call is allowed and the
/// bucket to keep. A clock that steps backwards refills nothing.
export function takeToken(
  bucket: TokenBucket | undefined, now: number,
  capacity: number = SESSIONS_COMMAND_RATE, windowMs: number = SESSIONS_COMMAND_WINDOW_MS
): { allowed: boolean; bucket: TokenBucket } {
  const prev = bucket ?? { tokens: capacity, at: now };
  const refill = Math.max(0, now - prev.at) * capacity / windowMs;
  const tokens = Math.min(capacity, prev.tokens + refill);
  // Never move `at` back: a clock step back would otherwise refill the
  // whole skew on the next call.
  const at = Math.max(prev.at, now);
  if (tokens < 1) return { allowed: false, bucket: { tokens, at } };
  return { allowed: true, bucket: { tokens: tokens - 1, at } };
}

export function utf8Length(s: string): number {
  return new TextEncoder().encode(s).length;
}

// MARK: devices

export type ParsedDevice =
  | { ok: true; token: string; appVersion: string; apnsEnv?: ApnsEnvironment }
  | { ok: false; error: string };

/// APNs device tokens are hex (64 chars today; Apple reserves the right to
/// grow them). Normalised to lowercase so re-registrations dedupe.
export function normalizeApnsToken(raw: unknown): string | null {
  if (typeof raw !== "string") return null;
  const t = raw.replace(/[\s<>]/g, "").toLowerCase();
  return /^[0-9a-f]{32,200}$/.test(t) ? t : null;
}

export function parseDeviceRegistration(raw: unknown): ParsedDevice {
  if (!isObject(raw)) return { ok: false, error: "bad_request" };
  if (raw.apnsToken === undefined || raw.apnsToken === null || raw.apnsToken === "") {
    return { ok: false, error: "missing_apnsToken" };
  }
  const token = normalizeApnsToken(raw.apnsToken);
  if (!token) return { ok: false, error: "invalid_apnsToken" };
  const envRaw = raw.apnsEnv ?? raw.apnsEnvironment;
  const apnsEnv = envRaw === "development" || envRaw === "production" ? envRaw : undefined;
  const appVersion = typeof raw.appVersion === "string" && raw.appVersion
    ? truncate(raw.appVersion, 50) : "unknown";
  return apnsEnv ? { ok: true, token, appVersion, apnsEnv } : { ok: true, token, appVersion };
}

// MARK: push payloads

export function categoryForKind(kind: InterventionKind): string {
  switch (kind) {
    case "permission":
    case "plan":
    case "approval":   return "PAGE_APPROVAL";
    case "question":
    case "user_input": return "PAGE_INPUT";
    case "idle":       return "PAGE_IDLE";
    case "rate_limit": return "PAGE_INFO";
    default:           return "PAGE_INFO";
  }
}

/// Time-sensitive breaks through Focus for pages that block an agent
/// (needs the time-sensitive entitlement on iOS; otherwise iOS treats it as
/// "active", which is harmless). An idle session can wait.
export function interruptionLevelForKind(kind: InterventionKind): "time-sensitive" | "active" {
  switch (kind) {
    case "permission":
    case "plan":
    case "approval":
    case "question":
    case "user_input": return "time-sensitive";
    default:           return "active";
  }
}

export function bodyForPush(iv: Intervention): string {
  // Truncate by code point so an emoji isn't split in half.
  const chars = Array.from(iv.context ?? "");
  const trimmed = chars.length > 180 ? chars.slice(0, 180).join("") + "…" : chars.join("");
  // v4 subtypes say what they are in their own context.
  switch (iv.subtype) {
    case "looping":
    case "stuck":            return trimmed ? `Looks stuck: ${trimmed}` : "A session looks stuck";
    case "workflow_stalled": return trimmed || "A workflow stopped making progress";
    case "battery_forecast": return trimmed || "Battery cutoff soon";
    case "usage_forecast":   return trimmed || "Claude usage limit soon";
  }
  switch (iv.kind) {
    case "permission":
    case "approval":   return trimmed ? `Approval needed: ${trimmed}` : "Approval needed";
    case "plan":       return trimmed ? `Plan ready: ${trimmed}` : "Plan ready for review";
    case "question":
    case "user_input": return trimmed || "Your agent has a question";
    case "idle":       return trimmed ? `Session is waiting: ${trimmed}` : "Session is waiting for you";
    case "rate_limit": return trimmed ? `Rate-limited: ${trimmed}` : "Rate-limited";
    default:           return trimmed || "Your agent needs you";
  }
}

/// `apns-collapse-id` must be ≤ 64 bytes. Intervention ids are ASCII in
/// practice; truncate by UTF-8 bytes anyway so a long id can't 400 the push.
export function collapseIdFor(id: string): string {
  const enc = new TextEncoder();
  if (enc.encode(id).length <= 64) return id;
  let out = "";
  for (const ch of id) {
    if (enc.encode(out + ch).length > 64) break;
    out += ch;
  }
  return out;
}

export interface BuiltPush {
  payload: Record<string, unknown>;
  collapseId?: string;
  expiration?: number;             // unix seconds
}

/// Alert push for a newly opened page. The collapse id is the intervention
/// id, which iOS also uses as the notification's request identifier, so the
/// phone can remove exactly this banner when the page closes.
/// `closedIds` lists pages this open superseded or evicted. The phone only
/// sees it when app code runs for this alert (foreground willPresent, or the
/// user acting on the banner); there is no Notification Service Extension,
/// so the Worker also sends a background close push with the same ids.
/// `quiet`: no sound and a passive interruption level — the banner still
/// lands (and replaces the ids in `closedIds`) but the phone doesn't buzz.
/// `badge`: the number of pending pages after this one opened (the app badge).
export function buildAlertPush(
  iv: Intervention, nowMs: number, closedIds: string[] = [], opts: { quiet?: boolean; badge?: number } = {}
): BuiltPush {
  const aps: Record<string, unknown> = {
    alert: { title: `${iv.projectName} paged you`, body: bodyForPush(iv) },
    category: categoryForKind(iv.kind),
    "mutable-content": 1,
    "thread-id": iv.sessionId,
    "interruption-level": opts.quiet ? "passive" : interruptionLevelForKind(iv.kind)
  };
  if (!opts.quiet) aps.sound = "default";
  setBadge(aps, opts.badge);
  const payload: Record<string, unknown> = {
    aps,
    interventionId: iv.id,
    kind: iv.kind,
    sessionId: iv.sessionId,
    // So the phone needn't parse "<project> paged you" out of the title.
    projectName: iv.projectName
  };
  if (closedIds.length) payload.interventionClosedIds = closedIds;
  return {
    payload,
    collapseId: collapseIdFor(iv.id),
    expiration: Math.floor(nowMs / 1000) + 3600
  };
}

/// Alert push when a reply couldn't be delivered (the user likely answered
/// from the lock screen and isn't looking at the app). Reuses the page's
/// collapse id so it replaces the original banner rather than stacking.
/// For a page that has already closed (`iv.closedAt` set) the banner gets
/// the action-less PAGE_INFO category: Approve/Deny on a closed page would
/// only be refused with 410.
export function buildReplyFailedPush(
  iv: Intervention, detail: string, nowMs: number, opts: { badge?: number } = {}
): BuiltPush {
  const aps: Record<string, unknown> = {
    alert: { title: `Reply to ${iv.projectName} not delivered`, body: detail },
    category: iv.closedAt ? "PAGE_INFO" : categoryForKind(iv.kind),
    sound: "default",
    "thread-id": iv.sessionId,
    "interruption-level": interruptionLevelForKind(iv.kind)
  };
  setBadge(aps, opts.badge);
  return {
    payload: {
      aps,
      interventionId: iv.id,
      kind: iv.kind,
      sessionId: iv.sessionId,
      projectName: iv.projectName,
      replyFailed: true
    },
    collapseId: collapseIdFor(iv.id),
    expiration: Math.floor(nowMs / 1000) + 3600
  };
}

/// Silent push telling the phone to drop delivered banners for closed pages.
/// `interventionClosedId` is the v1 key (first id); `interventionClosedIds`
/// carries every id closed in the same event (cascades, sync).
export function buildClosePush(ids: string[], _opts: { badge?: number } = {}): BuiltPush {
  // Background pushes must carry only content-available (Apple: no alert,
  // sound or badge). The app recounts its badge from a fresh inbox when the
  // push wakes it; alert pushes carry the authoritative badge.
  const aps: Record<string, unknown> = { "content-available": 1 };
  return {
    payload: {
      aps,
      interventionClosedId: ids[0],
      interventionClosedIds: ids
    }
  };
}

function setBadge(aps: Record<string, unknown>, badge: number | undefined): void {
  if (typeof badge === "number" && Number.isFinite(badge)) aps.badge = Math.max(0, Math.floor(badge));
}
