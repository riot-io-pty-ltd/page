# Security Policy

## Reporting a vulnerability

**Please do not open a public GitHub issue for security vulnerabilities.**

Instead, email the maintainer with details. We'll acknowledge receipt within
72 hours and aim to land a fix within two weeks for anything that looks like
a real exposure.

## Scope

Page consists of three components, each with its own threat model:

| Component | Threat model |
|---|---|
| **Mac menu bar app** | Runs locally with the user's permissions. Can send Apple Events (Terminal automation) and synthesize keystrokes (Accessibility). Has no remote attack surface other than its WebSocket to the user's own Cloudflare Worker. |
| **Cloudflare Worker** | Public HTTP/WebSocket endpoint. Auth is a bearer token shared between Mac and phone via QR code. One Durable Object per token. |
| **iOS app** | Connects to the user's Worker over wss. Receives APNs pushes from the same Worker. |

We're most interested in:

- Bypasses of the pairing-token auth on the Worker
- Anything that lets a Mac inject replies into another user's terminal sessions
- Leaks of pairing tokens (in logs, build artifacts, telemetry)
- TCC bypasses or unexpected scope-creep in macOS permissions we request

We're **not** interested in:

- Attacks that require running arbitrary code on the user's Mac. We assume the
  Mac is trusted; Page's whole job is to relay between trusted environments.
- DoS against your own Worker. Cloudflare's rate limits are out of scope.
- Issues in third-party dependencies (Apple frameworks, Cloudflare Workers
  runtime). Please report those upstream.

## Disclosure

We'll credit reporters in release notes unless you'd prefer otherwise.
