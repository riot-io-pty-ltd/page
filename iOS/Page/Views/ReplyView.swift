import SwiftUI
import UIKit

/// Context-first reply screen for one intervention, presented as a sheet
/// from the inbox, a notification tap or a `page://intervention/<id>` link.
///
/// It watches the live inbox: if the page is answered elsewhere, superseded
/// or resolved while open, the actions disable, a short "Resolved" state
/// shows, and the sheet closes itself — so a stale screen can never approve
/// a prompt that's no longer there.
struct ReplyView: View {
    let interventionId: String
    /// "Open session" handler. Nil (from the inbox) hands over to the
    /// session's detail screen through the router; a reply screen opened
    /// from that detail screen passes one that just closes itself.
    var onOpenSession: ((String) -> Void)? = nil

    @EnvironmentObject var api: APIClient
    @EnvironmentObject var router: AppRouter
    @Environment(\.dismiss) private var dismiss

    /// Last known copy, so content stays readable after the page closes.
    @State private var snapshot: Intervention?
    @State private var lookupFinished = false
    @State private var replyText = ""
    @State private var lastAttempt: Attempt?
    @State private var pendingQuickAction: ReplyAction?
    @State private var copied = false
    /// Ticks so "sent but unconfirmed" is noticed without other changes.
    @State private var now = Date()
    /// The archive lookup for a close that arrived without a reason is done.
    @State private var closeLookupFinished = false
    /// The session's changes, opened from a turn summary.
    @State private var showingDiff = false

    private struct Attempt: Equatable {
        let action: ReplyAction
        let text: String
    }

    /// What the screen is showing, derived from live state every render.
    private enum Phase: Equatable {
        case loading
        case missing
        case open
        case sending
        /// `slow`: past `ReplyConfirmation.slowAfter` without confirmation.
        case sent(queued: Bool, slow: Bool)
        /// Accepted by the relay but never confirmed by the Mac within the
        /// relay's ack window (`ReplyConfirmation`), so a second answer is
        /// accepted again. Input re-opens so the page can't get stuck.
        case unconfirmed
        /// Closed with no reason known yet while we had a reply out:
        /// checking the archive before saying what happened.
        case checkingClose
        case delivered(String?)
        case failed(String)
        case alreadyReplied
        case resolved(String)

        var acceptsInput: Bool {
            switch self {
            case .open, .failed, .unconfirmed: return true
            default: return false
            }
        }

        /// States after which the sheet closes on its own.
        var autoCloseDelay: Double? {
            switch self {
            case .delivered: return 1.4
            case .resolved, .alreadyReplied: return 2.2
            default: return nil
            }
        }
    }

    private var live: Intervention? { api.inbox.first { $0.id == interventionId } }
    private var intervention: Intervention? { live ?? snapshot }

    /// Only a relay known to predate delivery reporting gets the short
    /// legacy window; anything else holds a second answer for the Worker's
    /// ack window, which would refuse it with 409 before then.
    private var legacyRelay: Bool {
        api.relayIsLegacy && live?.deliveryStatus == nil
    }

    private var phase: Phase {
        let isLive = live != nil
        switch api.deliveries[interventionId] {
        case .sending?: return .sending
        case .sent(let queued, let at)?:
            if !isLive { return closedPhase(hadOwnReply: true) }
            if ReplyConfirmation.isUnconfirmed(sentAt: at, queued: queued, now: now, legacyRelay: legacyRelay) {
                return .unconfirmed
            }
            return .sent(queued: queued, slow: now.timeIntervalSince(at) > ReplyConfirmation.slowAfter)
        case .delivered(let detail)?: return .delivered(detail)
        case .failed(let message)?: return isLive ? .failed(message) : closedPhase(hadOwnReply: true)
        case .alreadyReplied?: return .alreadyReplied
        case .gone?: return .resolved("This page was already resolved.")
        case nil:
            if isLive { return .open }
            if snapshot != nil { return closedPhase(hadOwnReply: false) }
            return lookupFinished ? .missing : .loading
        }
    }

    private func closedPhase(hadOwnReply: Bool) -> Phase {
        let reason = api.recentCloseReasons[interventionId] ?? snapshot?.closeReason
        switch ClosedReplyPhase.decide(reason: reason, hadOwnReply: hadOwnReply, lookupFinished: closeLookupFinished) {
        case .delivered: return .delivered(nil)
        case .resolved(let why): return .resolved(why)
        case .checking: return .checkingClose
        }
    }

    var body: some View {
        ZStack {
            Theme.Colour.surface.ignoresSafeArea()
            VStack(spacing: 0) {
                topBar
                if let iv = intervention {
                    ScrollView {
                        content(iv)
                            .padding(.horizontal, Theme.Space.xl)
                            .padding(.vertical, Theme.Space.l)
                    }
                    .scrollDismissesKeyboard(.interactively)
                    statusStrip
                    actionZone(iv)
                    footer(iv)
                } else {
                    placeholder
                }
            }
        }
        .task { await lookUp() }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                now = Date()
            }
        }
        .onChange(of: live) { _, newValue in
            if let newValue { snapshot = newValue }
        }
        .task(id: phase == .checkingClose) {
            guard phase == .checkingClose else { return }
            await api.resolveCloseReason(interventionId)
            closeLookupFinished = true
        }
        .task(id: phase) {
            guard let delay = phase.autoCloseDelay else { return }
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            if !Task.isCancelled { dismiss() }
        }
        .confirmationDialog(discardTitle, isPresented: discardBinding, titleVisibility: .visible) {
            discardButtons
        } message: {
            Text("Your typed text won't be sent with this action.")
        }
    }

    /// Finds the intervention even on a cold launch from a notification,
    /// when the inbox hasn't loaded yet.
    private func lookUp() async {
        if let live { snapshot = live }
        if snapshot == nil {
            if api.inboxLoad != .loaded || lookupFinished == false { await api.refreshInbox() }
            snapshot = live ?? api.history.first { $0.id == interventionId }
        }
        if snapshot == nil {
            await api.refreshHistory()
            snapshot = api.history.first { $0.id == interventionId }
        }
        lookupFinished = true
    }

    // MARK: Header

    private var topBar: some View {
        HStack(spacing: Theme.Space.m) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.down")
                    .font(.system(.body, design: .default, weight: .semibold))
                    .foregroundStyle(Theme.Colour.text)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Close")
            VStack(spacing: 2) {
                Text(intervention?.projectName ?? " ")
                    .font(Theme.Font.mono13)
                    .foregroundStyle(Theme.Colour.textMuted)
                    .lineLimit(1)
                Text("Session \(String((intervention?.sessionId ?? "").prefix(8)))")
                    .font(Theme.Font.bodyEm)
                    .foregroundStyle(Theme.Colour.text)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .combine)
            Spacer().frame(width: 44)
        }
        .padding(.horizontal, Theme.Space.m)
        .padding(.top, Theme.Space.s)
        .padding(.bottom, Theme.Space.s)
        .overlay(Rectangle().fill(Theme.Colour.hairline).frame(height: 0.5), alignment: .bottom)
    }

    @ViewBuilder
    private var placeholder: some View {
        Spacer()
        if phase == .missing, let failure = api.inboxLoad.failureMessage {
            VStack(spacing: Theme.Space.m) {
                Image(systemName: "wifi.exclamationmark")
                    .font(.system(.largeTitle))
                    .foregroundStyle(Theme.Colour.textMuted)
                    .accessibilityHidden(true)
                Text("Couldn't load this page")
                    .font(Theme.Font.title17)
                    .foregroundStyle(Theme.Colour.text)
                Text(failure)
                    .font(Theme.Font.body15)
                    .foregroundStyle(Theme.Colour.textMuted)
                    .multilineTextAlignment(.center)
                Button("Try again") {
                    lookupFinished = false
                    Task { await lookUp() }
                }
                .font(Theme.Font.bodyEm)
                .padding(.top, Theme.Space.s)
            }
            .padding(Theme.Space.xxl)
        } else if phase == .missing {
            VStack(spacing: Theme.Space.m) {
                Image(systemName: "checkmark.circle")
                    .font(.system(.largeTitle))
                    .foregroundStyle(Theme.Colour.textMuted)
                    .accessibilityHidden(true)
                Text("This page is no longer available")
                    .font(Theme.Font.title17)
                    .foregroundStyle(Theme.Colour.text)
                Text("It was probably answered or resolved on your Mac.")
                    .font(Theme.Font.body15)
                    .foregroundStyle(Theme.Colour.textMuted)
                    .multilineTextAlignment(.center)
                Button("Close") { dismiss() }
                    .font(Theme.Font.bodyEm)
                    .padding(.top, Theme.Space.s)
            }
            .padding(Theme.Space.xxl)
        } else {
            ProgressView("Loading…")
        }
        Spacer()
    }

    // MARK: Content

    private func content(_ iv: Intervention) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            HStack(spacing: 6) {
                KindChip(kind: iv.kind, subtype: iv.subtype)
                if let backend = iv.backend {
                    BackendPill(backend: backend, source: iv.source)
                }
            }
            Text(ReplyCopy.headline(for: iv))
                .font(Theme.Font.display22)
                .foregroundStyle(Theme.Colour.text)
                .accessibilityAddTraits(.isHeader)
            TimelineView(.periodic(from: .now, by: 15)) { context in
                Text(RelativeTime.string("Paged", since: iv.openedAt, now: context.date))
                    .font(Theme.Font.caption12)
                    .tracking(0.5)
                    .textCase(.uppercase)
                    .foregroundStyle(Theme.Colour.textMuted)
            }
            contextBlock(iv)
            if !iv.cwd.isEmpty {
                Text("Working directory: \(PathDisplay.abbreviatingHome(iv.cwd))")
                    .font(Theme.Font.caption12)
                    .foregroundStyle(Theme.Colour.textMuted)
                    .textSelection(.enabled)
            }
            OpenSessionLink(sessionId: iv.sessionId) { openSession(iv.sessionId) }
        }
    }

    private func openSession(_ sessionId: String) {
        if let onOpenSession {
            onOpenSession(sessionId)
        } else {
            router.openSession(sessionId)
        }
    }

    private func contextBlock(_ iv: Intervention) -> some View {
        // Approvals are usually a command or a diff: monospace, selectable.
        let isCode = iv.kind == .approval && iv.subtype != "plan"
        return VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack {
                Text(isCode ? "REQUEST" : "CONTEXT")
                    .font(Theme.Font.chip11)
                    .tracking(0.5)
                    .foregroundStyle(Theme.Colour.textMuted)
                Spacer()
                Button {
                    UIPasteboard.general.string = iv.context
                    copied = true
                    Task {
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        copied = false
                    }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(Theme.Font.caption12)
                        .foregroundStyle(Theme.Colour.textMuted)
                        .frame(minHeight: 32)
                }
                .disabled(iv.context.isEmpty)
                .accessibilityLabel(copied ? "Copied" : "Copy request text")
            }
            let parts = iv.kind == .idle ? TurnSummaryLine.split(iv.context) : (summary: nil, rest: iv.context)
            if let summary = parts.summary {
                Button { showingDiff = true } label: {
                    HStack(spacing: Theme.Space.s) {
                        Image(systemName: summary.contains("tests failed") ? "exclamationmark.triangle" : "doc.text.magnifyingglass")
                        Text(summary).font(Theme.Font.bodyEm)
                        Spacer(minLength: 4)
                        Text("View changes").font(Theme.Font.caption12)
                        Image(systemName: "chevron.right").font(.caption2)
                    }
                    .foregroundStyle(summary.contains("tests failed") ? Theme.Colour.warning : Theme.Colour.text)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 10)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.Colour.surfaceInset))
                }
                .buttonStyle(.plain)
                .accessibilityHint("Shows the files and diff")
            }
            Text(parts.rest.isEmpty ? "No details were sent with this page." : parts.rest)
                .font(isCode ? Theme.Font.mono13 : Theme.Font.body15)
                .foregroundStyle(Theme.Colour.text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .sheet(isPresented: $showingDiff) { DiffView(sessionId: iv.sessionId, title: iv.projectName) }
        .padding(Theme.Space.l)
        .background(isCode ? Theme.Colour.surfaceInset : Theme.Colour.surfaceRaised)
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.Colour.hairline, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: Delivery / resolution state

    @ViewBuilder
    private var statusStrip: some View {
        switch phase {
        case .open, .loading, .missing:
            EmptyView()
        case .sending:
            StatusStrip(icon: nil, text: "Sending…", color: Theme.Colour.textMuted)
        case .sent(let queued, let slow):
            if queued {
                StatusStrip(icon: "clock", text: "Queued — your Mac is offline. It'll be typed in when the Mac reconnects (within an hour).", color: Theme.Colour.warning)
            } else if slow {
                StatusStrip(icon: nil, text: legacyRelay
                      ? "Sent — waiting for your Mac to confirm…"
                      : "Sent — waiting for your Mac. It hasn't confirmed this reply yet; if it reports a failure, or hasn't confirmed within 20 minutes, you can answer again.",
                      color: Theme.Colour.textMuted)
            } else {
                StatusStrip(icon: nil, text: "Sent — waiting for your Mac to confirm…", color: Theme.Colour.textMuted)
            }
        case .checkingClose:
            StatusStrip(icon: nil, text: "This page closed — checking whether your reply landed…", color: Theme.Colour.textMuted)
        case .delivered(let detail):
            StatusStrip(icon: "checkmark.circle.fill", text: "Delivered — \(detail ?? "typed into the session on your Mac").", color: Theme.Colour.success)
        case .failed(let message):
            HStack(alignment: .top, spacing: Theme.Space.s) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.Colour.destructiveText)
                    .accessibilityHidden(true)
                Text("Failed: \(message)")
                    .font(Theme.Font.caption12)
                    .foregroundStyle(Theme.Colour.text)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if let attempt = lastAttempt {
                    Button("Retry") { send(attempt.action, text: attempt.text) }
                        .font(Theme.Font.bodyEm)
                        .frame(minHeight: 32)
                }
            }
            .stripStyle()
        case .unconfirmed:
            StatusStrip(icon: "questionmark.circle", text: "Your Mac never confirmed this reply. If the session is still waiting, you can answer again.", color: Theme.Colour.warning)
        case .alreadyReplied:
            StatusStrip(icon: "checkmark.circle", text: "Already answered — another reply (maybe from your lock screen) got there first.", color: Theme.Colour.textMuted)
        case .resolved(let why):
            StatusStrip(icon: "checkmark.circle", text: "Resolved — \(why)", color: Theme.Colour.textMuted)
        }
    }

    // MARK: Actions

    @ViewBuilder
    private func actionZone(_ iv: Intervention) -> some View {
        let enabled = phase.acceptsInput
        VStack(spacing: Theme.Space.m) {
            switch iv.kind {
            case .approval:
                HStack(spacing: Theme.Space.s) {
                    QuickButton(iv.subtype == "plan" ? "Approve plan" : "Approve",
                                style: .accent, enabled: enabled) { tapQuick(.approve) }
                    QuickButton(iv.subtype == "plan" ? "Keep planning" : "Deny",
                                style: .destructive, enabled: enabled) { tapQuick(.deny) }
                }
                if iv.acceptsDecisionsOnly {
                    // The relay refuses anything else for these (422).
                    Text("This page comes from an older Page hook that can only apply Approve or Deny.")
                        .font(Theme.Font.caption12)
                        .foregroundStyle(Theme.Colour.textMuted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ReplyField(text: $replyText, placeholder: "Deny with instructions…", enabled: enabled) { send(.custom, text: $0) }
                }
            case .userInput:
                ReplyField(text: $replyText, placeholder: "Type your answer…", enabled: enabled) { send(.custom, text: $0) }
            case .idle where PageSubtype.isStuck(iv.subtype):
                if PageSubtype.canStop(iv.subtype) {
                    QuickButton("Stop it", style: .destructive, enabled: enabled) { tapQuick(.deny) }
                }
                ReplyField(text: $replyText, placeholder: PageSubtype.canStop(iv.subtype) ? "Tell it what to do instead…" : "Tell it what to do next…",
                           enabled: enabled) { send(.custom, text: $0) }
                Text(PageSubtype.canStop(iv.subtype)
                     ? "Stop presses Esc in the session. A message is queued until its current step ends."
                     : "Your message is typed into the session that started the workflow.")
                    .font(Theme.Font.caption12)
                    .foregroundStyle(Theme.Colour.textMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)
            case .idle:
                QuickButton("Carry on", style: .outline, enabled: enabled) { tapQuick(.carryOn) }
                ReplyField(text: $replyText, placeholder: "Tell it what to do next…", enabled: enabled) { send(.custom, text: $0) }
            case .rateLimit where PageSubtype.isForecast(iv.subtype):
                Text(iv.subtype == "battery_forecast"
                     ? "Nothing to answer. Plug your Mac in to keep the agents going."
                     : "Nothing to answer. Page keeps the Mac awake through the reset and can resume sessions when it resets.")
                    .font(Theme.Font.caption12)
                    .foregroundStyle(Theme.Colour.textMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                QuickButton("Close", style: .outline, enabled: true) { dismiss() }
            case .rateLimit:
                ReplyField(text: $replyText, placeholder: "Send this when the limit resets…", enabled: enabled) { send(.custom, text: $0) }
                Text("Page on your Mac types it into the session once the limit resets. Leave it empty to use auto-resume (if it's on).")
                    .font(Theme.Font.caption12)
                    .foregroundStyle(Theme.Colour.textMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                QuickButton("Close", style: .outline, enabled: true) { dismiss() }
            }
        }
        .padding(.horizontal, Theme.Space.xl)
        .padding(.top, Theme.Space.m)
    }

    private func footer(_ iv: Intervention) -> some View {
        Text(footerText(iv))
            .font(Theme.Font.caption12)
            .foregroundStyle(Theme.Colour.textMuted)
            .multilineTextAlignment(.center)
            .padding(.horizontal, Theme.Space.xl)
            .padding(.top, Theme.Space.s)
            .padding(.bottom, Theme.Space.l)
    }

    private func footerText(_ iv: Intervention) -> String {
        if iv.isBlockingHook {
            return "Your answer goes straight to \(iv.agentName)'s permission hook in session \(iv.sessionId.prefix(8))."
        }
        var where_ = "session \(iv.sessionId.prefix(8))"
        if let source = iv.source, source != .unknown { where_ += " (\(source.label))" }
        return "Page types your reply into \(where_) on your Mac."
    }

    /// Quick actions never carry the draft: the Mac uses non-empty text in
    /// place of the action, so a half-typed note would silently turn Deny
    /// into a prompt. With a draft present, ask first.
    private func tapQuick(_ action: ReplyAction) {
        if replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            send(action, text: "")
        } else {
            pendingQuickAction = action
        }
    }

    private func send(_ action: ReplyAction, text: String) {
        guard ReplyOutcome.validate(text: text, action: action) == nil else { return }
        lastAttempt = Attempt(action: action, text: text)
        Task {
            let outcome = await api.reply(to: interventionId, text: text, action: action)
            if case .accepted = outcome, action == .custom { replyText = "" }
        }
    }

    // MARK: Discard-draft confirmation

    private var discardBinding: Binding<Bool> {
        Binding(get: { pendingQuickAction != nil }, set: { if !$0 { pendingQuickAction = nil } })
    }

    private var discardTitle: String {
        switch pendingQuickAction {
        case .approve?: return "Approve without your note?"
        case .deny?: return "Deny with your note?"
        case .carryOn?: return "Send your note instead?"
        default: return ""
        }
    }

    @ViewBuilder
    private var discardButtons: some View {
        let draft = replyText.trimmingCharacters(in: .whitespacesAndNewlines)
        switch pendingQuickAction {
        case .approve?:
            Button("Approve and discard note") { replyText = ""; send(.approve, text: "") }
        case .deny?:
            Button("Deny with these instructions") { send(.custom, text: draft) }
            Button("Deny and discard note", role: .destructive) { replyText = ""; send(.deny, text: "") }
        case .carryOn?:
            Button("Send my note") { send(.custom, text: draft) }
            Button("Carry on and discard note") { replyText = ""; send(.carryOn, text: "") }
        default:
            EmptyView()
        }
        Button("Cancel", role: .cancel) { pendingQuickAction = nil }
    }
}

/// "Open session", shown while the page's session is live on the Mac. The
/// only part of the reply screen that watches `SessionStore`, so session
/// updates (every second while the Mac is busy) re-render this link, not the
/// whole screen.
private struct OpenSessionLink: View {
    let sessionId: String
    let action: () -> Void
    @EnvironmentObject var sessions: SessionStore

    var body: some View {
        if sessions.session(sessionId) != nil {
            Button(action: action) {
                Label("Open session", systemImage: "terminal")
                    .font(Theme.Font.bodyEm)
                    .foregroundStyle(Theme.Colour.text)
                    .frame(minHeight: 32)
            }
            .accessibilityHint("Shows this session's live transcript")
        }
    }
}
