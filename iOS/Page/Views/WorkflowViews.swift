import SwiftUI

// MARK: - Workflows list (a session's third pane)

/// The session's dynamic workflows, as Claude Code's footer lists them, one
/// card each: name, status, progress, phase. Tapping opens the run.
struct WorkflowList: View {
    let runs: [WorkflowRun]
    let onOpen: (WorkflowRun) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.Space.m) {
                ForEach(runs) { run in
                    Button { onOpen(run) } label: { WorkflowCard(run: run) }
                        .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, Theme.Space.l)
            .padding(.vertical, Theme.Space.m)
        }
    }
}

struct WorkflowCard: View {
    let run: WorkflowRun

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(run.name)
                        .font(Theme.Font.mono13)
                        .foregroundStyle(Theme.Colour.text)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    WorkflowStatusChip(run: run)
                }
                ProgressView(value: Double(run.done), total: Double(max(run.total, 1)))
                    .tint(run.isRunning ? LiveSessionState.active.color : Theme.Colour.textMuted)
                HStack {
                    Text(run.progress(now: context.date))
                    Spacer()
                    if let phase = run.phase { Text(phase).lineLimit(1) }
                }
                .font(Theme.Font.caption12)
                .foregroundStyle(Theme.Colour.textMuted)
            }
            .cardStyle()
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens the workflow")
    }
}

struct WorkflowStatusChip: View {
    let run: WorkflowRun

    private var color: Color {
        switch run.status {
        case "running": return LiveSessionState.active.color
        case "failed": return Theme.Colour.destructiveText
        case "stalled": return Theme.Colour.warning
        default: return Theme.Colour.textMuted
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            StatusDot(color: color)
            Text(run.statusLabel.uppercased())
                .font(Theme.Font.chip11)
                .tracking(0.5)
                .lineLimit(1)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .overlay(Capsule().strokeBorder(color.opacity(0.6), lineWidth: 1))
    }
}

// MARK: - One run

/// A workflow run: what it's for, its progress, and its agents (running
/// first). Tapping an agent shows what it's doing. Read-only: workflow
/// agents can't be typed into.
struct WorkflowRunView: View {
    let sessionId: String
    let runId: String

    @EnvironmentObject var sessions: SessionStore
    @Environment(\.dismiss) private var dismiss
    /// Last known copy, so the screen stays readable if the run drops off.
    @State private var snapshot: WorkflowRun?

    private var live: WorkflowRun? { sessions.workflows[sessionId]?.first { $0.id == runId } }
    private var run: WorkflowRun? { live ?? snapshot }

    var body: some View {
        NavigationStack {
            Group {
                if let run {
                    content(run)
                } else {
                    Text("This workflow is no longer listed.")
                        .font(Theme.Font.body15)
                        .foregroundStyle(Theme.Colour.textMuted)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .background(Theme.Colour.surface.ignoresSafeArea())
            .navigationTitle(run?.name ?? "Workflow")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: { Image(systemName: "chevron.down") }
                        .accessibilityLabel("Close")
                }
            }
            .navigationDestination(for: WorkflowRun.Agent.self) { agent in
                AgentTranscriptView(sessionId: sessionId, runId: runId, agent: agent)
            }
        }
        .onAppear { if let live { snapshot = live } }
        .onChange(of: live) { _, newValue in if let newValue { snapshot = newValue } }
    }

    private func content(_ run: WorkflowRun) -> some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        WorkflowStatusChip(run: run)
                        Spacer()
                        TimelineView(.periodic(from: .now, by: 30)) { context in
                            Text(run.progress(now: context.date))
                                .font(Theme.Font.caption12)
                                .foregroundStyle(Theme.Colour.textMuted)
                        }
                    }
                    ProgressView(value: Double(run.done), total: Double(max(run.total, 1)))
                        .tint(run.isRunning ? LiveSessionState.active.color : Theme.Colour.textMuted)
                    if let phase = run.phase {
                        Text("Phase: \(phase)")
                            .font(Theme.Font.caption12)
                            .foregroundStyle(Theme.Colour.textMuted)
                    }
                    if let summary = run.summary {
                        Text(summary)
                            .font(Theme.Font.body15)
                            .foregroundStyle(Theme.Colour.text)
                            .textSelection(.enabled)
                    }
                }
                .padding(.vertical, 4)
            }
            let running = run.agents.filter(\.running)
            let done = run.agents.filter { !$0.running }
            if !running.isEmpty {
                Section("Running · \(running.count)") {
                    ForEach(running) { agentRow($0) }
                }
            }
            if !done.isEmpty {
                Section("Done · \(done.count)") {
                    ForEach(done) { agentRow($0) }
                }
            }
            if run.agents.isEmpty {
                Section { Text("No agents have started yet.").foregroundStyle(Theme.Colour.textMuted) }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }

    private func agentRow(_ agent: WorkflowRun.Agent) -> some View {
        NavigationLink(value: agent) {
            HStack(spacing: Theme.Space.m) {
                StatusDot(color: agent.running ? LiveSessionState.active.color : Theme.Colour.textMuted)
                VStack(alignment: .leading, spacing: 3) {
                    Text(agent.label)
                        .font(Theme.Font.body15)
                        .foregroundStyle(Theme.Colour.text)
                        .lineLimit(2)
                    HStack(spacing: 6) {
                        if let phase = agent.phase { Text(phase) }
                        if let at = agent.lastActivityAt {
                            Text(at, style: .relative) + Text(" ago")
                        }
                    }
                    .font(Theme.Font.caption12)
                    .foregroundStyle(Theme.Colour.textMuted)
                }
            }
        }
        .accessibilityLabel("\(agent.label), \(agent.running ? "running" : "done")")
    }
}

extension WorkflowRun.Agent: Hashable {
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - One agent

/// What a workflow agent is doing: its last 40 transcript entries (its task,
/// its replies, one line per tool call), sent by the Mac while this screen
/// is open.
struct AgentTranscriptView: View {
    let sessionId: String
    let runId: String
    let agent: WorkflowRun.Agent

    @EnvironmentObject var sessions: SessionStore

    private var transcript: SessionTranscript? {
        sessions.agentTranscript(sessionId: sessionId, runId: runId, agentId: agent.id)
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                if let t = transcript {
                    if t.truncated {
                        Text("Earlier steps aren't shown")
                            .font(Theme.Font.caption12)
                            .foregroundStyle(Theme.Colour.textMuted)
                            .frame(maxWidth: .infinity)
                    }
                    ForEach(t.entries) { entry in
                        AgentEntryRow(entry: entry)
                    }
                    if t.entries.isEmpty {
                        Text("Nothing yet.").foregroundStyle(Theme.Colour.textMuted)
                    }
                } else {
                    HStack(spacing: Theme.Space.s) {
                        ProgressView().controlSize(.small)
                        Text("Asking your Mac…")
                    }
                    .font(Theme.Font.body15)
                    .foregroundStyle(Theme.Colour.textMuted)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)
                }
            }
            .padding(.horizontal, Theme.Space.l)
            .padding(.vertical, Theme.Space.m)
        }
        .defaultScrollAnchor(.bottom)
        .background(Theme.Colour.surface.ignoresSafeArea())
        .navigationTitle(agent.label)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { sessions.watchAgent(sessionId: sessionId, runId: runId, agentId: agent.id) }
        .onDisappear { sessions.watchAgent(sessionId: sessionId, runId: nil, agentId: nil) }
    }
}

struct AgentEntryRow: View {
    let entry: TranscriptEntry

    var body: some View {
        switch entry.role {
        case .user:
            Text(entry.text)
                .font(Theme.Font.body15)
                .foregroundStyle(Theme.Colour.text)
                .padding(Theme.Space.m)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.Colour.kindUserInput.opacity(0.12)))
                .textSelection(.enabled)
        case .assistant:
            Text(entry.text)
                .font(Theme.Font.body15)
                .foregroundStyle(Theme.Colour.text)
                .textSelection(.enabled)
        case .tool:
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "chevron.right").font(.caption2)
                Text(entry.text).lineLimit(3)
            }
            .font(Theme.Font.mono13)
            .foregroundStyle(Theme.Colour.textMuted)
        case .system:
            Text(entry.text)
                .font(Theme.Font.caption12)
                .foregroundStyle(Theme.Colour.textMuted)
                .frame(maxWidth: .infinity)
        }
    }
}
