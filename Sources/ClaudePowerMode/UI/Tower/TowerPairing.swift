import SwiftUI
import AppKit
import Combine

private typealias P = NightWatch.Palette

// MARK: - Backend

/// What the pairing page needs from outside, as closures. The live window
/// fills them in (running config, `PairingTokenManager`, the pasteboard); the
/// defaults touch nothing, so a render or a test never reads the session key
/// or the relay token and never goes to the network.
struct TowerPairingBackend {
    enum Info: Equatable {
        /// The relay is usable: its base URL and the pairing payload for the QR.
        case ready(base: URL, payload: String)
        /// A QR pointing at a disabled relay or the placeholder URL would pair
        /// "successfully" and then nothing would ever arrive on the phone.
        case setupNeeded(reason: String)
    }

    var info: () -> Info = { .setupNeeded(reason: "") }
    /// GET `<relay>/health`; calls back on the main queue.
    var probeHealth: (_ base: URL, _ done: @escaping (_ text: String, _ ok: Bool) -> Void) -> Void = { _, _ in }
    /// Copies the payload with the "don't record this" pasteboard markers.
    var copy: (_ payload: String) -> Void = { _ in }
    /// `PairingTokenManager.regenerate()` (posts `tokenDidChange`).
    var regenerate: () -> Void = {}
}

// MARK: - Model

/// Pairing: the QR for the paired phone, whether the relay answers, and the
/// token. The payload comes from `PairingTokenManager` and the QR from
/// `QRCode.image`, as before. Main thread only.
final class TowerPairingModel: ObservableObject {
    enum State: Equatable {
        case unknown
        case ready(host: String)
        case setupNeeded(reason: String)
    }

    enum Health: Equatable {
        case idle
        case checking
        case result(text: String, ok: Bool)
    }

    @Published private(set) var state: State = .unknown
    @Published private(set) var qr: NSImage?
    @Published private(set) var health: Health = .idle
    /// The QR holds the relay token and the session key, so it stays hidden until
    /// someone asks for it: opening the page reads nothing and shows nothing.
    @Published private(set) var revealed = false
    /// The payload behind the QR; empty whenever the relay is not usable.
    private(set) var payload = ""

    private weak var store: TowerStore?
    private var healthGeneration = 0

    init(store: TowerStore) { self.store = store }

    /// True when the page offers Regenerate token….
    var canRegenerate: Bool {
        if case .ready = state { return true }
        return false
    }

    /// Show pairing QR: an explicit request, so now the relay is read and the QR drawn.
    func reveal() {
        revealed = true
        refresh()
    }

    /// Takes the QR off screen again and forgets the payload (leaving the page, the window coming back).
    func hide() {
        guard revealed || state != .unknown else { return }
        revealed = false
        healthGeneration += 1
        health = .idle
        payload = ""
        qr = nil
        state = .unknown
    }

    /// Shows the QR for the running config, or says the relay needs setting up
    /// (and then clears the payload and skips the relay probe).
    func refresh() {
        guard let store else { return }
        switch store.env.pairing.info() {
        case .ready(let base, let payload):
            self.payload = payload
            qr = QRCode.image(from: payload, size: CGSize(width: 300, height: 300))
            state = .ready(host: base.host ?? base.absoluteString)
            probeHealth(base: base)
        case .setupNeeded(let reason):
            payload = ""
            qr = nil
            healthGeneration += 1
            health = .idle
            state = .setupNeeded(reason: reason)
        }
    }

    /// Sets what the page shows without reading any key or probing: the harness and tests.
    func setFixture(state: State, qr: NSImage? = nil, payload: String = "", health: Health = .idle, revealed: Bool = true) {
        healthGeneration += 1
        self.revealed = revealed
        self.state = state
        self.qr = qr
        self.payload = payload
        self.health = health
    }

    /// GET <relay>/health — proves the URL points at a live Page relay
    /// before the user scans (the endpoint needs no token).
    private func probeHealth(base: URL) {
        healthGeneration += 1
        let generation = healthGeneration
        health = .checking
        store?.env.pairing.probeHealth(base) { [weak self] text, ok in
            guard let self, generation == self.healthGeneration else { return }
            self.health = .result(text: text, ok: ok)
        }
    }

    func copyPayload() {
        guard !payload.isEmpty else { return }
        store?.env.pairing.copy(payload)
    }

    /// Regenerate token…: ask first, then retire the old token and show the new QR.
    func regenerate() {
        guard let store else { return }
        let spec = NWDialogSpec.confirm(
            "Regenerate the pairing token?",
            "Phones paired with the current token stop receiving pages until they scan the new QR code. Page asks the relay to retire the old token, so (on an up-to-date relay) those phones are told to re-pair. This Mac reconnects with the new token right away.",
            ok: "Regenerate", tone: .warning, destructive: true)
        guard store.ask(spec) == 0 else { return }
        // Posts tokenDidChange; the Coordinator reconnects the relay.
        store.env.pairing.regenerate()
        refresh()
    }

    /// Pure. "This Mac is connected to the relay." and its siblings.
    static func macLine(_ state: Coordinator.RelayState?) -> String {
        switch state {
        case .connected?: return "This Mac is connected to the relay."
        case .connecting?: return "This Mac is connecting to the relay…"
        case .off?, .misconfigured?: return "This Mac isn’t using the relay."
        case nil: return ""
        }
    }

    /// Pure. The copy for a relay that cannot be paired with yet.
    static func setupReason(relayEnabled: Bool, urlProblem: String?) -> String {
        if !relayEnabled {
            return "Phone paging is turned off. In Macs & phones, turn on “Send pages to my phone” and enter your relay’s URL."
        }
        return (urlProblem ?? "The relay URL isn’t valid.") + " Enter your Worker’s URL in Macs & phones."
    }

    /// Pure. The health probe's wording for a response.
    static func healthText(base: URL, data: Data?, response: URLResponse?, error: Error?) -> (text: String, ok: Bool) {
        if let error {
            return ("✗ Can’t reach the relay: \(error.localizedDescription)", false)
        }
        if let http = response as? HTTPURLResponse, http.statusCode == 200 {
            let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            if json?["ok"] as? Bool == true { return ("✓ Relay is reachable", true) }
            return ("⚠ Reached \(base.host ?? "the server"), but it doesn’t look like a Page relay", false)
        }
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        return ("✗ The relay answered HTTP \(code)", false)
    }
}

// MARK: - Page

/// Pairing & encryption: the QR on a glass card, then who can read what.
struct NWPairingPage: View {
    @ObservedObject var store: TowerStore
    @ObservedObject var model: TowerPairingModel

    init(store: TowerStore) {
        self.store = store
        self.model = store.pairing
    }

    var body: some View {
        NWPage(section: .pairing) {
            NWCard(title: "PAIR A PHONE") {
                switch model.state {
                case .unknown:
                    if model.revealed {
                        NWRow(title: "Looking at the relay…", detail: nil) {
                            Image(systemName: "ellipsis.circle").foregroundColor(P.textTertiary.color)
                        }
                    } else {
                        hidden
                    }
                case .ready(let host):
                    ready(host: host)
                case .setupNeeded(let reason):
                    setupNeeded(reason: reason)
                }
            }
            NWCard(title: "WHO CAN READ WHAT") {
                NWRow(title: "Sessions are end-to-end encrypted", detail: "with the key in the pairing QR. The relay carries the messages but can’t read them.") {
                    Image(systemName: "lock.fill").foregroundColor(P.teal.color)
                }
                NWDivider()
                NWRow(title: "Phones paired before encryption", detail: "need to scan the QR again.") {
                    Image(systemName: "qrcode").foregroundColor(P.textTertiary.color)
                }
                NWDivider()
                NWRow(title: "Retire a pairing",
                      detail: (model.canRegenerate ? "choose “Regenerate token…” above. " : "once the relay is set up and the QR is showing, choose “Regenerate token…” on this page. ")
                        + "Phones on the old token stop receiving pages until they scan the new QR.") {
                    Image(systemName: "arrow.triangle.2.circlepath").foregroundColor(P.textTertiary.color)
                }
            }
        }
    }

    /// Before the click: no QR, and nothing read from the relay or the Keychain.
    private var hidden: some View {
        HStack(alignment: .top, spacing: 24) {
            NWQRTile(image: nil)
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("The pairing QR is hidden")
                        .font(Font.system(size: 15, weight: .semibold))
                        .foregroundColor(P.textPrimary.color)
                    Text("It carries your relay token and encryption key, so it only appears when you ask — not while you’re sharing your screen.")
                        .font(Font.system(size: 12.5))
                        .foregroundColor(P.textSecondary.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
                NWButton(title: "Show pairing QR", kind: .primary) { model.reveal() }
            }
            Spacer(minLength: 0)
        }
        .padding(20)
    }

    private func ready(host: String) -> some View {
        HStack(alignment: .top, spacing: 24) {
            NWQRTile(image: model.qr)
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Scan this QR with Page on your iPhone")
                        .font(Font.system(size: 15, weight: .semibold))
                        .foregroundColor(P.textPrimary.color)
                    Text("Relay: \(host)")
                        .font(Font.system(size: 12, design: .monospaced))
                        .foregroundColor(P.textSecondary.color)
                }
                VStack(alignment: .leading, spacing: 6) {
                    healthChip
                    NWNote(text: TowerPairingModel.macLine(store.snapshot?.relayState))
                }
                HStack(spacing: 10) {
                    NWButton(title: "Copy pairing JSON", kind: .secondary, enabled: !model.payload.isEmpty, shortcut: KeyboardShortcut("c", modifiers: .command)) { model.copyPayload() }
                    NWButton(title: "Regenerate token…", kind: .secondary) { model.regenerate() }
                }
                NWNote(text: "Simulator can’t use a camera — use Copy pairing JSON and paste it into the app’s manual-pair screen.")
            }
            Spacer(minLength: 0)
        }
        .padding(20)
    }

    @ViewBuilder private var healthChip: some View {
        switch model.health {
        case .idle:
            EmptyView()
        case .checking:
            NWStateChip(text: "Checking the relay…", color: P.textTertiary, symbol: nil)
        case .result(let text, let ok):
            NWStateChip(text: text, color: ok ? P.green : (text.hasPrefix("⚠") ? P.amber : P.red.mixed(with: P.amber, 0.35)), symbol: nil)
        }
    }

    private func setupNeeded(reason: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "antenna.radiowaves.left.and.right.slash")
                    .font(Font.system(size: 26, weight: .regular))
                    .foregroundColor(P.amber.color)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(P.amber.opacity(0.12).color))
                VStack(alignment: .leading, spacing: 6) {
                    Text("Set up your relay first")
                        .font(Font.system(size: 15, weight: .semibold))
                        .foregroundColor(P.textPrimary.color)
                    Text(reason)
                        .font(Font.system(size: 12.5))
                        .foregroundColor(P.textSecondary.color)
                        .fixedSize(horizontal: false, vertical: true)
                    NWNote(text: "The relay is a small Cloudflare Worker you deploy once (see Cloudflare/README.md in the Page repository). Pairing needs it so your phone and this Mac can reach each other.")
                }
            }
            NWButton(title: "Go to Macs & phones", kind: .primary, shortcut: .defaultAction) { store.selection = .macsPhones }
        }
        .padding(20)
    }
}

/// The pairing QR: dark modules on a white tile with a quiet zone, whatever the
/// theme. A phone's camera needs the contrast.
struct NWQRTile: View {
    var image: NSImage?
    var side: CGFloat = 236

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.white)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.none)
                    .aspectRatio(contentMode: .fit)
                    .padding(16)
                    .accessibilityLabel(Text("Pairing QR code"))
            } else {
                Image(systemName: "qrcode").font(Font.system(size: 48)).foregroundColor(Color.black.opacity(0.25))
            }
        }
        .frame(width: side, height: side)
        .shadow(color: Color.black.opacity(0.35), radius: 14, y: 6)
    }
}
