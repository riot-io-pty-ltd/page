import SwiftUI

/// A session's changes: this turn's files (or the repository's uncommitted
/// changes) with the redacted diff, asked from the Mac when the screen
/// opens (`diff` op). Read-only.
struct DiffView: View {
    let sessionId: String
    let title: String

    @EnvironmentObject var sessions: SessionStore
    @Environment(\.dismiss) private var dismiss
    @AppStorage("page.diff.wrap") private var wrap = false
    @State private var requestedAt = Date()

    private var diff: SessionDiff? { sessions.diffs[sessionId] }

    var body: some View {
        NavigationStack {
            Group {
                if let diff {
                    content(diff)
                } else if let error = sessions.diffErrors[sessionId] {
                    message(error, systemImage: "exclamationmark.triangle")
                } else {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        if context.date.timeIntervalSince(requestedAt) > 20 {
                            message("No answer from your Mac. Pull down or tap Refresh to try again.", systemImage: "wifi.exclamationmark")
                        } else {
                            VStack(spacing: Theme.Space.s) {
                                ProgressView()
                                Text("Asking your Mac…").foregroundStyle(Theme.Colour.textMuted)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                }
            }
            .background(Theme.Colour.surface.ignoresSafeArea())
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: { Image(systemName: "chevron.down") }
                        .accessibilityLabel("Close")
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { wrap.toggle() } label: {
                        Image(systemName: wrap ? "text.alignleft" : "arrow.left.and.right.text.vertical")
                    }
                    .accessibilityLabel(wrap ? "Don't wrap lines" : "Wrap lines")
                    Button { request() } label: { Image(systemName: "arrow.clockwise") }
                        .accessibilityLabel("Refresh")
                }
            }
        }
        .onAppear { request() }
    }

    private func request() {
        requestedAt = Date()
        sessions.requestDiff(sessionId: sessionId)
    }

    private func message(_ text: String, systemImage: String) -> some View {
        VStack(spacing: Theme.Space.m) {
            Image(systemName: systemImage).font(.title2).foregroundStyle(Theme.Colour.textMuted)
            Text(text)
                .font(Theme.Font.body15)
                .foregroundStyle(Theme.Colour.textMuted)
                .multilineTextAlignment(.center)
        }
        .padding(Theme.Space.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func content(_ d: SessionDiff) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.Space.l) {
                header(d)
                if let note = d.note {
                    Text(note).font(Theme.Font.body15).foregroundStyle(Theme.Colour.textMuted)
                }
                if d.files.isEmpty && d.note == nil {
                    Text(d.scope == "turn" ? "This turn didn't change any files." : "No uncommitted changes.")
                        .font(Theme.Font.body15)
                        .foregroundStyle(Theme.Colour.textMuted)
                }
                if !d.files.isEmpty { fileList(d) }
                ForEach(Array(d.sections.enumerated()), id: \.offset) { _, section in
                    patchSection(section.path, section.lines)
                }
                if d.truncated {
                    Text("Cut short to fit — the rest is on your Mac.")
                        .font(Theme.Font.caption12)
                        .foregroundStyle(Theme.Colour.textMuted)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, Theme.Space.l)
            .padding(.vertical, Theme.Space.m)
        }
        .refreshable { request() }
    }

    private func header(_ d: SessionDiff) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(d.scope == "turn" ? "THIS TURN" : "UNCOMMITTED CHANGES")
                .font(Theme.Font.chip11)
                .tracking(0.5)
                .foregroundStyle(Theme.Colour.textMuted)
            HStack(spacing: 8) {
                if let repo = d.repo { Text(repo).font(Theme.Font.mono13).foregroundStyle(Theme.Colour.text) }
                Text("\(d.files.count) file\(d.files.count == 1 ? "" : "s")").foregroundStyle(Theme.Colour.textMuted)
                Text("+\(d.added)").foregroundStyle(Theme.Colour.success)
                Text("−\(d.removed)").foregroundStyle(Theme.Colour.destructiveText)
            }
            .font(Theme.Font.caption12)
        }
        .accessibilityElement(children: .combine)
    }

    private func fileList(_ d: SessionDiff) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(d.files) { f in
                HStack(spacing: 8) {
                    Image(systemName: f.status == "added" ? "plus.circle" : f.status == "modified" ? "pencil.circle" : "circle.dashed")
                        .foregroundStyle(Theme.Colour.textMuted)
                    Text(f.path)
                        .font(Theme.Font.mono13)
                        .foregroundStyle(Theme.Colour.text)
                        .lineLimit(1)
                        .truncationMode(.head)
                    Spacer(minLength: 4)
                    if let a = f.added { Text("+\(a)").foregroundStyle(Theme.Colour.success) }
                    if let r = f.removed { Text("−\(r)").foregroundStyle(Theme.Colour.destructiveText) }
                }
                .font(Theme.Font.caption12)
                .padding(.vertical, 6)
                .accessibilityElement(children: .combine)
                Divider().overlay(Theme.Colour.hairline)
            }
        }
        .cardStyle()
    }

    @ViewBuilder
    private func patchSection(_ path: String, _ lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if !path.isEmpty {
                Text(path)
                    .font(Theme.Font.mono13.weight(.semibold))
                    .foregroundStyle(Theme.Colour.text)
                    .padding(.bottom, 6)
            }
            let body = VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line.isEmpty ? " " : line)
                        .font(Theme.Font.mono13)
                        .foregroundStyle(color(line))
                        .lineLimit(wrap ? nil : 1)
                        .fixedSize(horizontal: !wrap, vertical: true)
                        .frame(maxWidth: wrap ? .infinity : nil, alignment: .leading)
                        .padding(.horizontal, 6)
                        .background(background(line))
                }
            }
            if wrap {
                body
            } else {
                ScrollView(.horizontal, showsIndicators: true) { body }
            }
        }
        .padding(Theme.Space.m)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.Colour.surfaceInset))
        .textSelection(.enabled)
    }

    private func color(_ line: String) -> Color {
        if line.hasPrefix("@@") { return Theme.Colour.textMuted }
        if line.hasPrefix("+") { return Theme.Colour.success }
        if line.hasPrefix("-") { return Theme.Colour.destructiveText }
        return Theme.Colour.text
    }

    private func background(_ line: String) -> Color {
        if line.hasPrefix("+") && !line.hasPrefix("+++") { return Theme.Colour.success.opacity(0.08) }
        if line.hasPrefix("-") && !line.hasPrefix("---") { return Theme.Colour.destructiveText.opacity(0.08) }
        return .clear
    }
}

// MARK: - New session

/// Starts a new Claude session on the Mac (`folders` + `start` ops): pick
/// one of the folders Claude already worked in, type what it should do.
struct NewSessionView: View {
    @EnvironmentObject var sessions: SessionStore
    @EnvironmentObject var router: AppRouter
    @Environment(\.dismiss) private var dismiss
    @State private var folder: String?
    @State private var prompt = ""
    @State private var clientId: String?
    @State private var askedAt = Date()

    private var state: SessionDeliveryState? { clientId.flatMap { sessions.commands[$0]?.state } }

    var body: some View {
        NavigationStack {
            Form {
                if let f = sessions.startFolders {
                    if !f.enabled {
                        Section {
                            Label("Starting sessions from your phone is off", systemImage: "lock")
                                .font(Theme.Font.bodyEm)
                            Text("On your Mac, open Page → Settings → Phone and turn on “Let my phone start new Claude sessions”.")
                                .font(Theme.Font.caption12)
                                .foregroundStyle(Theme.Colour.textMuted)
                        }
                    } else if f.folders.isEmpty {
                        Section { Text("Page hasn't seen Claude work in any folder in the last 30 days.").foregroundStyle(Theme.Colour.textMuted) }
                    } else {
                        Section("Folder") {
                            Picker("Folder", selection: $folder) {
                                ForEach(f.folders) { item in
                                    VStack(alignment: .leading) {
                                        Text(item.name)
                                        Text(PathDisplay.abbreviatingHome(item.path))
                                            .font(Theme.Font.caption12)
                                            .foregroundStyle(Theme.Colour.textMuted)
                                    }
                                    .tag(Optional(item.path))
                                }
                            }
                            .pickerStyle(.inline)
                            .labelsHidden()
                        }
                        Section {
                            TextField("What should Claude do? (optional)", text: $prompt, axis: .vertical)
                                .lineLimit(3...8)
                        } header: { Text("Prompt") } footer: {
                            Text("Opens a new cmux workspace on your Mac and runs claude there.")
                        }
                        Section {
                            Button {
                                guard let folder else { return }
                                clientId = sessions.startSession(folder: folder, prompt: prompt)
                            } label: {
                                HStack {
                                    Text("Start session").font(Theme.Font.bodyEm)
                                    Spacer()
                                    if state == .sending { ProgressView() }
                                }
                            }
                            .disabled(folder == nil || state == .sending)
                            if let state { resultRow(state) }
                        }
                    }
                } else if let error = sessions.startFoldersError {
                    Section { Text(error).foregroundStyle(Theme.Colour.destructiveText) }
                } else {
                    Section { HStack { ProgressView(); Text("Asking your Mac…").foregroundStyle(Theme.Colour.textMuted) } }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.Colour.surface.ignoresSafeArea())
            .navigationTitle("New session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
        }
        .onAppear {
            askedAt = Date()
            sessions.requestFolders()
        }
        .onChange(of: sessions.startFolders) { _, f in
            if folder == nil { folder = f?.folders.first?.path }
        }
        // The new session showed up on the Mac: open it.
        .onChange(of: sessions.startedSessionId) { _, id in
            guard let id else { return }
            sessions.clearStartedSession()
            dismiss()
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 400_000_000)
                router.openSession(id)
            }
        }
    }

    @ViewBuilder
    private func resultRow(_ state: SessionDeliveryState) -> some View {
        switch state {
        case .sending: EmptyView()
        case .typed(let detail), .queued(let detail):
            VStack(alignment: .leading, spacing: 4) {
                Label(detail ?? "Started", systemImage: "checkmark.circle").foregroundStyle(Theme.Colour.success)
                if sessions.startWaitExpired {
                    Text("Started, but it hasn't shown up here yet. Look for it in Sessions, or in cmux on your Mac.")
                        .font(Theme.Font.caption12)
                        .foregroundStyle(Theme.Colour.textMuted)
                } else {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Opening it here as soon as it appears… On your Mac it's a new cmux workspace.")
                            .font(Theme.Font.caption12)
                            .foregroundStyle(Theme.Colour.textMuted)
                    }
                }
            }
        case .refused(_, let message), .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(Theme.Colour.destructiveText)
        case .noAnswer:
            Label("No answer from your Mac", systemImage: "wifi.exclamationmark").foregroundStyle(Theme.Colour.warning)
        }
    }
}
