import SwiftUI
import UIKit

/// Dispatch, live: the Mac's known folders, a prompt, and Start, wired to the
/// existing `SessionStore.startSession` path. If no session appears within
/// 90 s, or the Mac refuses, the sheet says plainly where to look.
struct DispatchContainer: View {
    @EnvironmentObject var sessions: SessionStore
    @EnvironmentObject var api: APIClient
    @EnvironmentObject var pairing: PairingStore
    @EnvironmentObject var router: AppRouter
    @Environment(\.dismiss) private var dismiss
    @State private var draft = DispatchDraft()
    @State private var clientId: String?

    private var state: SessionDeliveryState? { clientId.flatMap { sessions.commands[$0]?.state } }
    private var availability: DispatchAvailability { DispatchAvailability.from(folders: sessions.startFolders, error: sessions.startFoldersError) }

    var body: some View {
        let folders = sessions.startFolders?.folders ?? []
        let sending = state == .sending
        NWDispatchScreen(
            data: DispatchScreenData(macName: nwMacName(sessions: sessions, pairing: pairing), availability: availability, folders: folders,
                                     now: Date(), status: DispatchStatus.from(state: state, startWaitExpired: sessions.startWaitExpired),
                                     sending: sending, runway: RunwayModel.build(status: api.macStatus, now: Date(), timeZone: .current)),
            actions: actions, draft: $draft)
            .background(NightWatch.Palette.backgroundDeep.color.ignoresSafeArea())
            .preferredColorScheme(.dark)
            .onAppear { sessions.requestFolders() }
            .onChange(of: sessions.startFolders) { _, f in draft.ensureSelection(in: f?.folders ?? [], now: Date()) }
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

    private var actions: DispatchScreenActions {
        var a = DispatchScreenActions()
        a.close = { dismiss() }
        a.retry = { sessions.requestFolders() }
        a.paste = { if let s = UIPasteboard.general.string { draft.prompt += s } }
        a.openTower = { router.openTower(.budget) }
        a.start = {
            guard let path = draft.selectedPath, draft.canStart(availability: availability, sending: state == .sending) else { return }
            clientId = sessions.startSession(folder: path, prompt: draft.trimmedPrompt)
        }
        return a
    }
}
