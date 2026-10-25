import Foundation
import SwiftUI
import Combine

/// This phone's pairings with Macs. The active one's credentials live in the
/// Keychain slots every network path reads (see `RelayCredentials`); every
/// pairing, active or not, is also kept in `savedMacs` so the user can
/// switch between Macs. This object publishes whether we're paired and
/// drives the other services when that changes.
@MainActor
final class PairingStore: ObservableObject {
    @Published private(set) var pairedMac: PairedMac?
    /// Host of the paired relay, for display.
    @Published private(set) var relayHost: String?
    /// Why the last pairing ended on its own: the Mac replaced it (relay
    /// `token_retired`). Shown on the pairing screen until a new pairing is
    /// adopted or the user dismisses it; kept across launches.
    @Published private(set) var retirementNotice: String?
    /// Every paired Mac, newest first (the active one included).
    @Published private(set) var savedMacs: [SavedMac] = []
    /// The other Macs' status (`GET /status`), by saved id.
    @Published private(set) var otherStatus: [String: WidgetStatus] = [:]

    private static let pairedKey = "page.pairedMac"

    /// The paired Mac's name from the Keychain (no instance needed).
    nonisolated static func currentMacName() -> String? {
        guard let json = KeychainStore.get(pairedKey), let data = json.data(using: .utf8) else { return nil }
        return (try? JSONDecoder().decode(PairedMac.self, from: data))?.name
    }
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

    /// The saved entry for the active pairing.
    var activeMacId: String? {
        guard let token = RelayCredentials.current()?.token else { return nil }
        return savedMacs.first { $0.token == token }?.id
    }

    private func load() {
        let creds = RelayCredentials.current()
        relayHost = creds?.baseURL.host
        savedMacs = SavedMacs.decode(KeychainStore.get(SavedMacs.keychainKey))
        guard let creds,
              let json = KeychainStore.get(Self.pairedKey),
              let data = json.data(using: .utf8),
              let mac = try? JSONDecoder().decode(PairedMac.self, from: data) else {
            pairedMac = nil
            return
        }
        pairedMac = mac
        // Pairings made before several Macs were supported.
        if !savedMacs.contains(where: { $0.token == creds.token }) {
            remember(SavedMac(id: UUID().uuidString, name: mac.name, relayURL: creds.baseURL.absoluteString,
                              token: creds.token, sessionKey: KeychainStore.get(SessionKeyStore.keychainKey),
                              pairedAt: mac.pairedAt ?? Date()))
        }
    }

    private func remember(_ mac: SavedMac) {
        saveList(SavedMacs.upsert(savedMacs, mac))
    }

    private func saveList(_ list: [SavedMac]) {
        if let json = SavedMacs.encode(list), KeychainStore.set(json, for: SavedMacs.keychainKey) {
            savedMacs = list
        } else if list.isEmpty {
            KeychainStore.delete(SavedMacs.keychainKey)
            savedMacs = []
        }
        otherStatus = otherStatus.filter { id, _ in list.contains { $0.id == id } }
    }

    /// Makes another saved Mac the active one: its credentials go into the
    /// active slots, everything tied to the old Mac is cleared, and the app
    /// connects to the new one.
    func switchTo(_ id: String) {
        guard let mac = savedMacs.first(where: { $0.id == id }), id != activeMacId else { return }
        let paired = PairedMac(name: mac.name, pairedAt: mac.pairedAt)
        guard let macData = try? JSONEncoder().encode(paired),
              let macJSON = String(data: macData, encoding: .utf8) else { return }
        APIClient.shared.reset()
        AppRouter.shared.reset()
        guard KeychainStore.set(mac.relayURL, for: RelayCredentials.relayURLKey),
              KeychainStore.set(mac.token, for: RelayCredentials.relayTokenKey),
              KeychainStore.set(macJSON, for: Self.pairedKey) else { return }
        if let key = mac.sessionKey.flatMap(Base64URL.decode) { SessionKeyStore.save(key) } else { SessionKeyStore.clear() }
        SessionStore.shared.reloadKey()
        relayHost = mac.relayHost
        pairedMac = paired
        otherStatus[id] = nil
        WidgetShare.sync()
        NotificationService.shared.pairingChanged()
        APIClient.shared.activate()
    }

    /// Forgets a Mac that isn't the active one.
    func remove(_ id: String) {
        guard id != activeMacId, let mac = savedMacs.first(where: { $0.id == id }) else { return }
        saveList(SavedMacs.removing(id, from: savedMacs))
        if let url = URL(string: mac.relayURL) {
            let creds = RelayCredentials(baseURL: url, token: mac.token)
            Task { await NotificationService.shared.unregister(using: creds) }
        }
    }

    /// Checks every other Mac's relay (`GET /status`) for the switcher and
    /// the "another Mac needs you" banner.
    func refreshOthers() async {
        let active = activeMacId
        for mac in savedMacs where mac.id != active {
            guard let base = URL(string: mac.relayURL) else { continue }
            var req = URLRequest(url: base.appendingPathComponent("status"), timeoutInterval: 10)
            req.setValue("Bearer \(mac.token)", forHTTPHeaderField: "Authorization")
            guard let (data, response) = try? await URLSession.shared.data(for: req),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
            otherStatus[mac.id] = WidgetStatus.from(json: json, macName: mac.name, now: Date(),
                                                    format: { $0.formatted(date: .omitted, time: .shortened) })
        }
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
        remember(SavedMac(id: UUID().uuidString, name: pairing.macName, relayURL: pairing.relayBaseURL.absoluteString,
                          token: pairing.token, sessionKey: pairing.sessionKey.map(Base64URL.encode), pairedAt: mac.pairedAt ?? Date()))
        WidgetShare.sync()
        // MainTabView's .task connects and loads once it appears.
        NotificationService.shared.pairingChanged()
        return true
    }

    /// Forgets the Mac. The relay is told to stop pushing to this phone,
    /// using credentials captured before they're deleted; local state is
    /// cleared immediately so the UI never shows the old Mac's data.
    func unpair() {
        let creds = RelayCredentials.current()
        // Another Mac is paired: forget this one and switch to it.
        let leaving = activeMacId
        if let next = SavedMacs.next(in: savedMacs, excluding: leaving) {
            if let leaving { saveList(SavedMacs.removing(leaving, from: savedMacs)) }
            NotificationService.shared.clearAll()
            switchTo(next.id)
            if let creds { Task { await NotificationService.shared.unregister(using: creds) } }
            return
        }
        saveList([])
        KeychainStore.delete(Self.pairedKey)
        KeychainStore.delete(RelayCredentials.relayURLKey)
        KeychainStore.delete(RelayCredentials.relayTokenKey)
        SessionKeyStore.clear()
        #if DEBUG
        isDevPairing = false
        #endif
        pairedMac = nil
        relayHost = nil
        WidgetShare.sync()
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
        // The retired pairing can never work again; with another Mac
        // paired, move to it instead of the pairing screen.
        let retired = activeMacId
        if let next = SavedMacs.next(in: savedMacs, excluding: retired) {
            if let retired { saveList(SavedMacs.removing(retired, from: savedMacs)) }
            switchTo(next.id)
            return
        }
        saveList([])
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
        WidgetShare.sync()
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
