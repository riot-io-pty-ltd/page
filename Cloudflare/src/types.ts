/// Kinds of intervention. The first four are the legacy Claude vocab kept
/// for back-compat with deployed hook scripts and phones; the last three are
/// the newer generic vocab. Treat both vocabularies as valid — iOS maps
/// old → new at decode time. Anything else is coerced to "question" on ingest.
export type InterventionKind =
  | "permission" | "plan" | "question" | "idle"
  | "approval" | "user_input" | "rate_limit";

/// Which agent fired the intervention. Optional on the wire; missing →
/// "claude" for back-compat with pre-Phase-4 Macs and the hook.
export type InterventionBackend = "claude" | "codex";

/// Where the agent is running. Optional on the wire; missing → "terminal".
export type InterventionSource =
  | "terminal" | "desktop" | "vscode" | "exec" | "remote" | "unknown";

/// Worker-managed reply delivery state (wire contract v2).
export type DeliveryStatus = "pending" | "delivered" | "failed";

export type ReplyAction = "approve" | "deny" | "carry_on" | "custom";

export type ApnsEnvironment = "development" | "production";

export interface Intervention {
  id: string;
  sessionId: string;
  cwd: string;
  projectName: string;
  kind: InterventionKind;
  context: string;
  openedAt: string;                // ISO8601
  closedAt?: string;
  closeReason?: string;
  repliedAt?: string;
  repliedText?: string;
  repliedAction?: string;
  /// Set by Phase 4+ Macs. Worker defaults to "claude" on store if missing.
  backend?: InterventionBackend;
  source?: InterventionSource;
  /// Optional sub-tag, e.g. `"plan"` for plan-mode approvals. Free-form.
  subtype?: string;
  // v2, Worker-managed. Never trusted from an inbound open.
  deliveryStatus?: DeliveryStatus;
  deliveryDetail?: string;
  deliveryMethod?: string;
  /// When the reply was actually handed to a Mac socket (not just queued).
  deliveryForwardedAt?: string;
  /// Worker-managed: the page was opened by the v1 blocking PreToolUse hook
  /// (`hook-` id, User-Agent page-hook/1.x, kind "permission", no backend).
  /// Its reply is read by that hook, never forwarded to the Mac, and only
  /// Approve / Deny are accepted. Never trusted from an inbound open.
  hookBlocking?: boolean;
  /// The prompt this page is about (the pending tool_use id), sent by hooks
  /// that know it. Echoed to the Mac as `promptKey` in the reply frame so it
  /// can tell whether the prompt on screen is still this one.
  promptKey?: string;
}

/// One registered phone. Keyed by APNs token in storage ("dev:<token>").
export interface DeviceRecord {
  appVersion: string;
  registeredAt: string;
  /// Which APNs host the token belongs to, as reported by the phone. Xcode
  /// debug builds get development tokens; TestFlight / App Store builds get
  /// production ones. Its presence also marks a phone that knows the
  /// per-kind notification categories.
  apnsEnv?: ApnsEnvironment;
  /// For phones that don't report apnsEnv: the host that last accepted a
  /// push (learned by retrying a BadDeviceToken on the other host).
  learnedEnv?: ApnsEnvironment;
}

/// A reply waiting for the Mac to come online. Everything the Mac needs is
/// captured at enqueue time so a flush never depends on the intervention
/// still being pending (it might have been archived meanwhile).
export interface QueuedReply {
  interventionId: string;
  text: string;
  action: ReplyAction | null;
  sessionId: string;
  cwd: string;
  kind: InterventionKind;
  backend: InterventionBackend;
  source?: InterventionSource;
  queuedAt: number;                // ms epoch
  /// True when the reply targets a recently closed intervention (free text
  /// only). These expire much sooner than replies to live pages.
  closed?: boolean;
  closeReason?: string;
  /// The page's promptKey at enqueue time (echoed in the reply frame).
  promptKey?: string;
}

/// Frame from Mac/hook → Worker over WS or POST /intervention.
export interface InboundEnvelope {
  type:
    | "intervention.opened"
    | "intervention.closed"
    | "heartbeat"
    | "reply.injected"
    | "device.register"
    | "sync"
    | "relay.retire";       // Mac: this token was replaced, shut it down
  payload: unknown;
}

/// Frame from Worker → connected client (Mac or iOS) over WS.
export interface OutboundEnvelope {
  type:
    | "reply"               // → Mac
    | "intervention.opened" // → phones
    | "intervention.closed" // → phones
    | "heartbeat"           // → phones
    | "reply.result"        // → phones
    | "mac.status"          // → phones
    | "relay.retired";      // → phones: re-pair needed
  payload: unknown;
}

export interface Env {
  USERS: DurableObjectNamespace;
  /// Secrets. Optional in practice: without them the relay still works over
  /// WebSocket, it just can't push to a backgrounded phone.
  APNS_KEY_P8?: string;
  APNS_KEY_ID?: string;
  APNS_TEAM_ID?: string;
  APNS_BUNDLE_ID: string;
  APNS_ENV: ApnsEnvironment;
}
