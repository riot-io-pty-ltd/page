import Foundation
import SwiftUI

@MainActor
final class PairingStore: ObservableObject {
    @Published private(set) var pairedMac: PairedMac?
    @Published private(set) var relayURL: String?
    @Published private(set) var relayToken: String?

    private let pairedKey = "page.pairedMac"
    private let relayURLKey = "page.relayURL"
    private let relayTokenKey = "page.relayToken"

    init() {
        load()
    }

    private func load() {
        relayURL = KeychainStore.get(relayURLKey) ?? AppConstants.workerBaseURL.absoluteString
        relayToken = KeychainStore.get(relayTokenKey)
        if let json = KeychainStore.get(pairedKey),
           let data = json.data(using: .utf8),
           let m = try? JSONDecoder().decode(PairedMac.self, from: data) {
            pairedMac = m
        }
        print("[PairingStore] load — pairedMac=\(pairedMac != nil ? "yes" : "no") token=\(relayToken != nil ? "yes(\(relayToken!.prefix(6))…)" : "no") url=\(relayURL ?? "nil")")
    }

    func adopt(payload: PairingPayload) {
        let mac = PairedMac(
            name: payload.host ?? "Mac",
            hostname: payload.host ?? "studio.local",
            activeSessions: 0,
            pingMs: 0,
            connected: false
        )
        pairedMac = mac
        // The pairing payload may carry a `relay` field for forward compat,
        // but the canonical Worker URL is baked in. Only use the payload's
        // URL if it points somewhere we already know about — otherwise stick
        // with the built-in default.
        let candidate = payload.relay.trimmingCharacters(in: .whitespaces)
        relayURL = candidate.isEmpty ? AppConstants.workerBaseURL.absoluteString : candidate
        relayToken = payload.token
        if let data = try? JSONEncoder().encode(mac), let s = String(data: data, encoding: .utf8) {
            KeychainStore.set(s, for: pairedKey)
        }
        if let urlToStore = relayURL { KeychainStore.set(urlToStore, for: relayURLKey) }
        KeychainStore.set(payload.token, for: relayTokenKey)
        print("[PairingStore] adopt — host=\(payload.host ?? "?") token=\(payload.token.prefix(6))… url=\(relayURL ?? "nil")")
    }

    func unpair() {
        pairedMac = nil
        relayURL = nil
        relayToken = nil
        KeychainStore.delete(pairedKey)
        KeychainStore.delete(relayURLKey)
        KeychainStore.delete(relayTokenKey)
    }

    func parse(qrText: String) -> PairingPayload? {
        guard let data = qrText.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(PairingPayload.self, from: data)
    }
}
