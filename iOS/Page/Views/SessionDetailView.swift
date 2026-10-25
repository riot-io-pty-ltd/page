import SwiftUI
import UIKit

/// One live session: what it's doing (the Mac's last 40 transcript
/// entries, chat-style), a composer that types into it, and Stop while it's
/// mid-turn. Presented as a sheet, like the reply screen.
///
/// While visible it tells the Mac it's watching (re-sent every 30 s), which
/// is what makes the Mac send this session's transcript at all.
struct SessionDetailView: View {
    let sessionId: String

    @EnvironmentObject var api: APIClient
    @EnvironmentObject var sessions: SessionStore
    @EnvironmentObject var router: AppRouter
    @Environment(\.dismiss) private var dismiss

    @State private var draft = ""
    @State private var composerProblem: String?
    @State private var confirmingStop = false
    @State private var presentedPage: AppRouter.PresentedIntervention?
    /// Last known copy, so the screen stays readable after the session ends.
    @State private var snapshot: LiveSession?
    /// The bottom of the transcript is on screen: new entries scroll in.
    @State private var atBottom = true
    @State private var scrollRequest = 0
    @State private var pane: Pane = .conversation

    /// Conversation (the transcript) or Terminal (the Mac's mirror of the
    /// session's screen, footer included). Terminal appears only once the
    /// Mac has sent a screen: older Macs, Terminal.app and iTerm2 don't.
    enum Pane: String, CaseIterable { case conversation = "Conversation", terminal = "Terminal" }

    private static let watchInterval: UInt64 = 30

    private var live: LiveSession? { sessions.session(sessionId) }
    private var session: LiveSession? { live ?? snapshot }
    private var agent: String { session?.backend.displayName ?? "Your agent" }

    private var availability: SessionAvailability {
        sessions.availability(presence: MacPresence.evaluate(api.macStatus, now: Date()),
                              socketConnected: api.connection == .connected, now: Date())
    }

    /// The session left the Mac's list while this screen was open.
    private var ended: Bool { live == nil && sessions.hasList && snapshot != nil }

    var body: some View {
        ZStack {
            Theme.Colour.surface.ignoresSafeArea()
            VStack(spacing: 0) {
                topBar
                if let s = session {
                    header(s)
                    banners(s)
                    if let screen = sessions.screens[sessionId] {
                        Picker("View", selection: $pane) {
                            ForEach(Pane.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .padding(.horizontal, Theme.Space.l)
                        .padding(.bottom, Theme.Space.s)
                        if pane == .terminal {
                            TerminalMirror(screen: screen)
                        } else {
                            transcript(s)
                        }
                    } else {
                        transcript(s)
                    }
                    bottomZone(s)
                } else {
                    placeholder
                }
            }
        }
        .onAppear { if let live { snapshot = live } }
        .onChange(of: live) { _, newValue in
            if let newValue { snapshot = newValue }
        }
        // Watch while visible and connected; the store re-arms it after a
        // reconnect, and sends nothing while the socket is down.
        .task(id: api.connection == .connected) {
            while !Task.isCancelled {
                sessions.watch(sessionId)
                try? await Task.sleep(nanoseconds: Self.watchInterval * 1_000_000_000)
            }
        }
        .onDisappear { sessions.watch(nil) }
        .sheet(item: $presentedPage) { item in
            // "Open session" there just comes back here.
            ReplyView(interventionId: item.id, onOpenSession: { _ in presentedPage = nil })
        }
        .confirmationDialog("Stop \(agent)?", isPresented: $confirmingStop, titleVisibility: .visible) {
            Button("Stop this turn", role: .destructive) { sessions.interrupt(sessionId: sessionId) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Page presses Esc in the session on your Mac. \(agent) stops what it's doing and waits for you.")
        }
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
                Text(session?.cwd.isEmpty == false ? session!.cwd : " ")
                    .font(Theme.Font.mono13)
                    .foregroundStyle(Theme.Colour.textMuted)
                    .lineLimit(1)
                    .truncationMode(.head)
                Text(session?.title ?? "Session")
                    .font(Theme.Font.bodyEm)
                    .foregroundStyle(Theme.Colour.text)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .combine)
            stopButton
        }
        .padding(.horizontal, Theme.Space.m)
        .padding(.top, Theme.Space.s)
        .padding(.bottom, Theme.Space.s)
        .overlay(Rectangle().fill(Theme.Colour.hairline).frame(height: 0.5), alignment: .bottom)
    }

    @ViewBuilder
    private var stopButton: some View {
        let stopping = sessions.latestInterrupt(for: sessionId, now: Date())?.state.isPending == true
        if let s = live, s.isStoppable, availability == .ready {
            Button { confirmingStop = true } label: {
                Group {
                    if stopping {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "stop.fill")
                            .font(.system(.body, design: .default, weight: .semibold))
                    }
                }
                .foregroundStyle(Theme.Colour.destructiveText)
                .frame(width: 44, height: 44)
                .background(Circle().fill(Theme.Colour.destructive.opacity(0.12)).frame(width: 36, height: 36))
            }
            .disabled(stopping)
            .accessibilityLabel(stopping ? "Stopping" : "Stop \(agent)")
            .accessibilityHint("Asks for confirmation, then presses Esc in the session")
        } else {
            Spacer().frame(width: 44)
        }
    }

    private func header(_ s: LiveSession) -> some View {
        HStack(spacing: 6) {
            BackendPill(agent: s.backend, host: s.hostLabel)
            SessionStateChip(state: ended ? .offline : s.state)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Space.xl)
        .padding(.vertical, Theme.Space.s)
    }

    @ViewBuilder
    private func banners(_ s: LiveSession) -> some View {
        let available = availability
        VStack(spacing: Theme.Space.s) {
            if ended {
                StatusBanner(tone: .info, systemImage: "checkmark.circle",
                             title: "This session has ended",
                             message: "It's no longer on your Mac's list. The transcript below is the last one Page received.")
            } else if available != .ready {
                let copy = SessionAvailabilityCopy(available)
                StatusBanner(tone: copy.tone, systemImage: copy.systemImage, title: copy.title,
                             message: copy.message.isEmpty ? "Waiting for your Mac…" : copy.message,
                             actionTitle: copy.action == .retry ? copy.actionTitle : nil,
                             action: copy.action == .retry ? { sessions.refresh() } : nil)
            } else if let pageId = s.openPageId {
                StatusBanner(tone: .warning, systemImage: "bell.badge",
                             title: s.state == .waitingOnApproval ? "\(agent) needs your approval" : "\(agent) is waiting for you",
                             message: "Answer the prompt from its page. Page won't type over a prompt.",
                             actionTitle: "Open page") { presentedPage = .init(id: pageId) }
            } else if s.state.isWaiting {
                StatusBanner(tone: .warning, systemImage: "bell.badge",
                             title: "\(agent) is showing a prompt",
                             message: "There's no page for it yet. Answer it on your Mac, or wait a moment for the page to arrive.")
            }
        }
        .padding(.horizontal, Theme.Space.xl)
        .padding(.bottom, Theme.Space.xs)
    }

    // MARK: Transcript

    private func transcript(_ s: LiveSession) -> some View {
        let entries = sessions.transcripts[sessionId]
        let items = TranscriptTimeline.merge(entries: entries?.entries ?? [], sent: sessions.sentMessages(for: sessionId))
        // Changes when an entry or a delivery state changes, not on every render.
        let signature = items.map { item -> String in
            switch item {
            case .entry(let e, let d): return e.id + (d.map { "\($0.state)" } ?? "")
            case .pending(let p): return p.clientId + "\(p.state)"
            }
        }.joined(separator: "|")
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if entries?.truncated == true {
                        Text("Earlier messages aren't shown")
                            .font(Theme.Font.caption12)
                            .foregroundStyle(Theme.Colour.textMuted)
                            .frame(maxWidth: .infinity)
                            .padding(.bottom, Theme.Space.s)
                    }
                    if items.isEmpty {
                        emptyTranscript(loaded: entries != nil)
                    }
                    ForEach(items) { item in
                        row(item)
                    }
                    Color.clear
                        .frame(height: 1)
                        .id(Self.bottomId)
                        .onAppear { atBottom = true }
                        .onDisappear { atBottom = false }
                }
                .padding(.horizontal, Theme.Space.l)
                .padding(.vertical, Theme.Space.m)
            }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: signature) { _, _ in
                // Follow new entries only while the user is at the bottom;
                // someone reading back up keeps their place.
                if atBottom { scrollToBottom(proxy) }
            }
            .onChange(of: scrollRequest) { _, _ in scrollToBottom(proxy) }
            .overlay(alignment: .bottomTrailing) {
                if !atBottom && !items.isEmpty {
                    Button { scrollToBottom(proxy) } label: {
                        Image(systemName: "arrow.down")
                            .font(.system(.body, design: .default, weight: .semibold))
                            .foregroundStyle(Theme.Colour.text)
                            .frame(width: 40, height: 40)
                            .background(Circle().fill(Theme.Colour.surfaceRaised))
                            .overlay(Circle().strokeBorder(Theme.Colour.hairline, lineWidth: 1))
                    }
                    .padding(Theme.Space.m)
                    .accessibilityLabel("Jump to latest")
                }
            }
        }
    }

    private static let bottomId = "transcript-bottom"

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(Self.bottomId, anchor: .bottom) }
    }

    private func emptyTranscript(loaded: Bool) -> some View {
        VStack(spacing: Theme.Space.m) {
            if loaded || availability != .ready {
                Text(loaded ? "Nothing in this session yet." : "The transcript appears once your Mac is connected.")
                    .font(Theme.Font.body15)
                    .foregroundStyle(Theme.Colour.textMuted)
                    .multilineTextAlignment(.center)
            } else {
                ProgressView("Loading transcript…")
                    .font(Theme.Font.body15)
                    .foregroundStyle(Theme.Colour.textMuted)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    @ViewBuilder
    private func row(_ item: TranscriptTimeline.Item) -> some View {
        switch item {
        case .entry(let e, let delivery):
            switch e.role {
            case .user:
                userBubble(text: e.text, delivery: delivery, pending: false)
            case .assistant:
                assistantBubble(e)
            case .tool:
                toolRow(e)
            case .system:
                systemRow(e)
            }
        case .pending(let message):
            userBubble(text: message.text, delivery: message, pending: true)
        }
    }

    private func userBubble(text: String, delivery: SentSessionCommand?, pending: Bool) -> some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack {
                Spacer(minLength: 48)
                Text(text)
                    .font(Theme.Font.body15)
                    .foregroundStyle(Theme.Colour.text)
                    .textSelection(.enabled)
                    .padding(.horizontal, Theme.Space.m)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Theme.Colour.kindUserInput.opacity(pending ? 0.08 : 0.16))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(Theme.Colour.kindUserInput.opacity(0.35), lineWidth: pending ? 1 : 0)
                    )
                    .contextMenu { copyButton(text) }
            }
            // The bubble carries its status as the value, explanation
            // included; deliveryLine hides its text from VoiceOver so it isn't
            // read twice, and its "Open page" button stays focusable.
            .accessibilityElement(children: .combine)
            .accessibilityLabel("You: \(text)")
            .accessibilityValue(delivery.map { $0.state.spokenBubbleStatus(.input, agent: agent) } ?? "")
            if let delivery {
                deliveryLine(delivery)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private func deliveryLine(_ message: SentSessionCommand) -> some View {
        let state = message.state
        let color: Color
        let icon: String?
        switch state {
        case .sending:          color = Theme.Colour.textMuted; icon = nil
        case .typed:            color = Theme.Colour.success; icon = "checkmark"
        case .queued:           color = Theme.Colour.textMuted; icon = "clock"
        case .refused, .failed: color = Theme.Colour.destructiveText; icon = "exclamationmark.triangle.fill"
        case .noAnswer:         color = Theme.Colour.warning; icon = "questionmark.circle"
        }
        let explanation = state.bubbleExplanation(.input, agent: agent)
        return VStack(alignment: .trailing, spacing: 2) {
            HStack(spacing: 4) {
                if let icon {
                    Image(systemName: icon)
                } else {
                    ProgressView().controlSize(.mini)
                }
                Text(state.label(.input))
            }
            .font(Theme.Font.chip11)
            .foregroundStyle(color)
            .accessibilityHidden(true)  // read as the bubble's value
            if let explanation {
                Text(explanation)
                    .font(Theme.Font.caption12)
                    .foregroundStyle(Theme.Colour.textMuted)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityHidden(true)
            }
            if case .refused(let reason, _) = state, reason == "waiting", let pageId = live?.interventionId {
                Button("Open page") { presentedPage = .init(id: pageId) }
                    .font(Theme.Font.bodyEm)
                    .frame(minHeight: 32)
                    .accessibilityHint("Answer the prompt from its page")
            }
        }
        .padding(.leading, 48)
    }

    private func assistantBubble(_ e: TranscriptEntry) -> some View {
        HStack {
            Text(e.text)
                .font(Theme.Font.body15)
                .foregroundStyle(Theme.Colour.text)
                .textSelection(.enabled)
                .padding(.horizontal, Theme.Space.m)
                .padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.Colour.surfaceRaised))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.Colour.hairline, lineWidth: 1))
                .contextMenu { copyButton(e.text) }
            Spacer(minLength: 32)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(agent): \(e.text)")
    }

    private func toolRow(_ e: TranscriptEntry) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "chevron.right")
                .font(.system(.caption2, design: .monospaced, weight: .bold))
                .foregroundStyle(Theme.Colour.textMuted)
                .accessibilityHidden(true)
            Text(e.text)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(Theme.Colour.textMuted)
                .lineLimit(3)
                .truncationMode(.tail)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Space.s)
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Tool: \(e.text)")
    }

    private func systemRow(_ e: TranscriptEntry) -> some View {
        Text(e.text)
            .font(Theme.Font.caption12)
            .tracking(0.3)
            .foregroundStyle(Theme.Colour.textMuted)
            .multilineTextAlignment(.center)
            .padding(.horizontal, Theme.Space.m)
            .padding(.vertical, 4)
            .background(Capsule().fill(Theme.Colour.surfaceInset))
            .frame(maxWidth: .infinity)
    }

    private func copyButton(_ text: String) -> some View {
        Button {
            UIPasteboard.general.string = text
        } label: {
            Label("Copy", systemImage: "doc.on.doc")
        }
    }

    // MARK: Composer

    @ViewBuilder
    private func bottomZone(_ s: LiveSession) -> some View {
        let ready = availability == .ready && !ended
        VStack(spacing: 0) {
            interruptStrip
            if let composerProblem {
                Text(composerProblem)
                    .font(Theme.Font.caption12)
                    .foregroundStyle(Theme.Colour.destructiveText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Theme.Space.xl)
                    .padding(.top, Theme.Space.s)
                    .accessibilityLabel("Can't send: \(composerProblem)")
            }
            Group {
                if !s.canType {
                    typeBlocker(s)
                } else {
                    VStack(alignment: .trailing, spacing: 4) {
                        ReplyField(text: $draft, placeholder: "Message \(agent)…", enabled: ready,
                                   sendLabel: "Send message") { send($0) }
                        if draft.count >= SessionComposer.counterFrom {
                            Text("\(draft.count) / \(SessionComposer.maxCharacters)")
                                .font(Theme.Font.caption12)
                                .monospacedDigit()
                                .foregroundStyle(draft.count > SessionComposer.maxCharacters
                                                 ? Theme.Colour.destructiveText : Theme.Colour.textMuted)
                        }
                    }
                }
            }
            .padding(.horizontal, Theme.Space.xl)
            .padding(.top, Theme.Space.m)
            Text(footerText(s))
                .font(Theme.Font.caption12)
                .foregroundStyle(Theme.Colour.textMuted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Theme.Space.xl)
                .padding(.top, Theme.Space.s)
                .padding(.bottom, Theme.Space.l)
        }
        .background(Theme.Colour.surface)
        .overlay(Rectangle().fill(Theme.Colour.hairline).frame(height: 0.5), alignment: .top)
        .onChange(of: draft) { _, _ in if composerProblem != nil { composerProblem = nil } }
    }

    @ViewBuilder
    private var interruptStrip: some View {
        if let stop = sessions.latestInterrupt(for: sessionId, now: Date()) {
            switch stop.state {
            case .sending:
                StatusStrip(icon: nil, text: "Stopping…", color: Theme.Colour.textMuted)
            case .typed, .queued:
                StatusStrip(icon: "stop.circle", text: "Stopped. \(stop.state.explanation(.interrupt, agent: agent) ?? "")",
                            color: Theme.Colour.success)
            case .refused, .failed, .noAnswer:
                StatusStrip(icon: "exclamationmark.triangle.fill",
                            text: "Couldn't stop: \(stop.state.explanation(.interrupt, agent: agent) ?? "")",
                            color: Theme.Colour.destructiveText)
            }
        }
    }

    private func typeBlocker(_ s: LiveSession) -> some View {
        HStack(alignment: .top, spacing: Theme.Space.s) {
            Image(systemName: "keyboard.badge.ellipsis")
                .foregroundStyle(Theme.Colour.textMuted)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(s.blockerText)
                    .font(Theme.Font.bodyEm)
                    .foregroundStyle(Theme.Colour.text)
                Text("You can still follow along here, and answer pages from the Inbox.")
                    .font(Theme.Font.caption12)
                    .foregroundStyle(Theme.Colour.textMuted)
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Colour.surfaceInset)
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.Colour.hairline, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }

    private func footerText(_ s: LiveSession) -> String {
        guard s.canType else { return "\(s.hostLabel) · \(s.state.label)" }
        return "Page types your message into this session (\(s.hostLabel)) on your Mac."
    }

    private func send(_ text: String) {
        if let problem = sessions.sendInput(sessionId: sessionId, text: text) {
            composerProblem = problem.message
            return
        }
        draft = ""
        composerProblem = nil
        scrollRequest += 1
    }

    // MARK: Placeholder

    @ViewBuilder
    private var placeholder: some View {
        Spacer()
        if sessions.hasList {
            VStack(spacing: Theme.Space.m) {
                Image(systemName: "checkmark.circle")
                    .font(.system(.largeTitle))
                    .foregroundStyle(Theme.Colour.textMuted)
                    .accessibilityHidden(true)
                Text("This session isn't running")
                    .font(Theme.Font.title17)
                    .foregroundStyle(Theme.Colour.text)
                Text("It's not on your Mac's list of live sessions anymore.")
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
}

// MARK: - Terminal mirror

/// The session's screen as the Mac last read it: monospace, unwrapped
/// (scrolls sideways), pinned to the bottom where the footer is.
struct TerminalMirror: View {
    let screen: SessionScreen

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView([.vertical, .horizontal]) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(screen.lines.enumerated()), id: \.offset) { i, line in
                            Text(line.isEmpty ? " " : line)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(Theme.Colour.text)
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                                .id(i)
                        }
                    }
                    .padding(Theme.Space.m)
                    .textSelection(.enabled)
                }
                .background(Theme.Colour.surfaceInset)
                .onAppear { proxy.scrollTo(screen.lines.count - 1, anchor: .bottomLeading) }
                .onChange(of: screen.lines) { _, lines in
                    proxy.scrollTo(lines.count - 1, anchor: .bottomLeading)
                }
            }
            TimelineView(.periodic(from: .now, by: 5)) { context in
                Text("Mirrored from your Mac · \(Self.age(screen.at, now: context.date))")
                    .font(Theme.Font.caption12)
                    .foregroundStyle(Theme.Colour.textMuted)
                    .padding(.vertical, Theme.Space.xs)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Terminal: " + screen.lines.suffix(12).joined(separator: ", "))
    }

    static func age(_ at: Date, now: Date) -> String {
        let s = max(0, Int(now.timeIntervalSince(at)))
        return s < 10 ? "live" : s < 60 ? "\(s)s ago" : "\(s / 60)m ago"
    }
}
