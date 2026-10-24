import Foundation
import SwiftUI
import Combine

/// The single pairing this phone has with a Mac. Credentials live in the
/// Keychain (see `RelayCredentials`); this object only publishes whether
/// we're paired and drives the other services when that changes.
@MainActor
final class PairingStore: ObservableObject {
    @Published private(set) var pairedMac: PairedMac?
    /// Host of the paired relay, for display.
    @Published private(set) var relayHost: String?
    /// Why the last pairing ended on its own: the Mac replaced it (relay
    /// `token_retired`). Shown on the pairing screen until a new pairing is
    /// adopted or the user dismisses it; kept across launches.
    @Published private(set) var retirementNotice: String?

    private static let pairedKey = "page.pairedMac"
    private static let retirementNoticeKey = "page.retirementNotice"
    private var retiredSubscription: AnyCancellable?

    init() {
        load()
        retirementNotice = UserDefaults.standard.string(forKey: Self.retirementNoticeKey)
        // @Published emits in willSet, before APIClient has stored the new
        // value, so hop to the next main-queue turn before unpairing (which
        // resets APIClient). A retirement noticed while no UI existed (a
        // background push) is replayed here on subscription.
        retiredSubscription = APIClient.shared.$retiredWhy
            .compactMap { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] why in self?.pairingRetired(why: why) }
    }

    var isPaired: Bool { pairedMac != nil }

    private func load() {
        let creds = RelayCredentials.current()
        relayHost = creds?.baseURL.host
        guard creds != nil,
              let json = KeychainStore.get(Self.pairedKey),
              let data = json.data(using: .utf8),
              let mac = try? JSONDecoder().decode(PairedMac.self, from: data) else {
            pairedMac = nil
            return
        }
        pairedMac = mac
    }

    /// The Keychain is unreadable until the first unlock after a reboot; if
    /// the app was launched in the background before that, we may have
    /// loaded "unpaired". Re-check when the UI becomes active.
    func reloadIfNeeded() {
        #if DEBUG
        if isDevPairing { return }
        #endif
        if pairedMac == nil { load() }
    }

    /// Saves a pairing that already passed validation and the relay probe.
    /// Returns false if the Keychain refused the write.
    @discardableResult
    func adopt(_ pairing: ValidatedPairing) -> Bool {
        let mac = PairedMac(name: pairing.macName, pairedAt: Date())
        guard let macData = try? JSONEncoder().encode(mac),
              let macJSON = String(data: macData, encoding: .utf8) else { return false }

        // Anything from a previous pairing must not bleed into this one.
        APIClient.shared.reset()
        AppRouter.shared.reset()
        dismissRetirementNotice()

        guard KeychainStore.set(pairing.relayBaseURL.absoluteString, for: RelayCredentials.relayURLKey),
              KeychainStore.set(pairing.token, for: RelayCredentials.relayTokenKey),
              KeychainStore.set(macJSON, for: Self.pairedKey) else {
            return false
        }
        // After the reset above, which cleared the previous Mac's key. A
        // failed write leaves the pairing usable: the Sessions tab then
        // asks for a re-pair.
        if let key = pairing.sessionKey { SessionKeyStore.save(key) } else { SessionKeyStore.clear() }
        SessionStore.shared.reloadKey()
        #if DEBUG
        isDevPairing = false
        #endif
        relayHost = pairing.relayHost
        pairedMac = mac
        // MainTabView's .task connects and loads once it appears.
        NotificationService.shared.pairingChanged()
        return true
    }

    /// Forgets the Mac. The relay is told to stop pushing to this phone,
    /// using credentials captured before they're deleted; local state is
    /// cleared immediately so the UI never shows the old Mac's data.
    func unpair() {
        let creds = RelayCredentials.current()
        KeychainStore.delete(Self.pairedKey)
        KeychainStore.delete(RelayCredentials.relayURLKey)
        KeychainStore.delete(RelayCredentials.relayTokenKey)
        SessionKeyStore.clear()
        #if DEBUG
        isDevPairing = false
        #endif
        pairedMac = nil
        relayHost = nil
        APIClient.shared.reset()
        AppRouter.shared.reset()
        NotificationService.shared.clearAll()
        if let creds {
            Task { await NotificationService.shared.unregister(using: creds) }
        }
    }

    /// The relay retired this pairing (the Mac regenerated its token). Same
    /// local cleanup as `unpair()`, but the relay isn't told anything: it
    /// refuses every call on the old token. The pairing screen shows `why`.
    func pairingRetired(why: String) {
        // Already handled, or a newer pairing replaced the retired one.
        guard APIClient.shared.retiredWhy == why else { return }
        retirementNotice = why
        UserDefaults.standard.set(why, forKey: Self.retirementNoticeKey)
        KeychainStore.delete(Self.pairedKey)
        KeychainStore.delete(RelayCredentials.relayURLKey)
        KeychainStore.delete(RelayCredentials.relayTokenKey)
        SessionKeyStore.clear()
        #if DEBUG
        isDevPairing = false
        #endif
        pairedMac = nil
        relayHost = nil
        APIClient.shared.reset()
        AppRouter.shared.reset()
        // APIClient already cleared banners and the badge when it saw the
        // retirement; clearing again here could drop the "Reply not sent"
        // notice a lock-screen reply posts right after.
        NotificationService.shared.pairingRetired()
    }

    func dismissRetirementNotice() {
        retirementNotice = nil
        UserDefaults.standard.removeObject(forKey: Self.retirementNoticeKey)
    }

    #if DEBUG
    /// "Skip pairing (DEV)": in-memory only, nothing written to the Keychain
    /// and no network, so a relaunch returns to the pairing screen.
    private(set) var isDevPairing = false

    func adoptDev(_ mac: PairedMac) {
        isDevPairing = true
        relayHost = "dev.invalid"
        pairedMac = mac
    }
    #endif
}
