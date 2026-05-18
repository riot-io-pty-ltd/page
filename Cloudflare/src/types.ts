/// Kinds of intervention. The first four are the legacy Claude vocab kept
/// for back-compat with deployed hook scripts; the last three are the new
/// vocab introduced in Phase 4 (Codex + generic). Treat both vocabularies
/// as valid — iOS maps old → new at decode time.
export type InterventionKind =
  | "permission" | "plan" | "question" | "idle"
  | "approval" | "user_input" | "rate_limit";

/// Which agent fired the intervention. Optional on the wire; missing →
/// "claude" for back-compat with pre-Phase-4 Macs.
export type InterventionBackend = "claude" | "codex";

/// Where the agent is running. Optional on the wire; missing →
/// "terminal".
export type InterventionSource =
  | "terminal" | "desktop" | "vscode" | "exec" | "remote" | "unknown";

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
}

export interface Reply {
  interventionId: string;
  text: string;
  action?: "approve" | "deny" | "carry_on" | "custom" | null;
}

export interface DeviceRegistration {
  apnsToken: string;
  appVersion: string;
  registeredAt: string;
}

export interface Heartbeat {
  ts: string;
  activeSessions: number;
  battery: number;
}

/// Outgoing frame from Mac→Worker over WS or POST.
export interface InboundEnvelope {
  type:
    | "intervention.opened"
    | "intervention.closed"
    | "heartbeat"
    | "reply.injected"
    | "device.register";
  payload: unknown;
}

/// Outgoing frame from Worker→connected client (Mac or iOS) over WS.
export interface OutboundEnvelope {
  type: "reply" | "ack" | "ping" | "intervention.opened" | "intervention.closed" | "heartbeat";
  payload: unknown;
}

export interface Env {
  USERS: DurableObjectNamespace;
  APNS_KEY_P8: string;
  APNS_KEY_ID: string;
  APNS_TEAM_ID: string;
  APNS_BUNDLE_ID: string;
  APNS_ENV: "development" | "production";
}
