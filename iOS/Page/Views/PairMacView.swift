import SwiftUI
import AVFoundation
import UIKit

/// First-run pairing. A scanned or pasted code is validated locally, then
/// probed against the relay (is it a Page relay, does it accept the token?)
/// and only saved after the user confirms the Mac and relay it points at.
struct PairMacView: View {
    /// Set when adding another Mac from Settings (a sheet): called once the
    /// new pairing is saved.
    var onPaired: (() -> Void)? = nil
    @EnvironmentObject var pairing: PairingStore
    @EnvironmentObject var api: APIClient
    @Environment(\.colorScheme) private var scheme
    @ScaledMetric(relativeTo: .body) private var primaryHeight: CGFloat = 52

    private enum Stage: Equatable {
        case idle
        case checking(ValidatedPairing)
        /// `unused`: the relay has never seen a Mac with this token
        /// (`MacStatusSnapshot.looksUnused`).
        case confirm(ValidatedPairing, macOnline: Bool?, unused: Bool)
        case problem(title: String, message: String, retry: ValidatedPairing?, openSettings: Bool)
    }

    @State private var stage: Stage = .idle
    @State private var showingScanner = false
    @State private var showingManualEntry = false
    @State private var manualText = ""
    @State private var manualError: String?
    @State private var probeTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            Theme.Colour.surface.ignoresSafeArea()
            ScrollView {
                VStack(spacing: Theme.Space.xxl) {
                    Spacer().frame(height: 40)
                    PulseMark(size: 96)
                    Text("Pair your Mac")
                        .font(Theme.Font.display22)
                        .foregroundStyle(Theme.Colour.text)
                        .accessibilityAddTraits(.isHeader)
                    Text("On your Mac, click the Page icon in the menu bar → Pair phone…, then scan the QR code shown there.")
                        .font(Theme.Font.body15)
                        .foregroundStyle(Theme.Colour.textMuted)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, Theme.Space.l)

                    if let notice = pairing.retirementNotice {
                        StatusBanner(tone: .error, systemImage: "key.slash",
                                     title: "Pair again",
                                     message: "\(TokenRetirement.sentence(notice)) Your old inbox and history were cleared.",
                                     actionTitle: "Dismiss") { pairing.dismissRetirementNotice() }
                    }

                    stageView
                }
                .padding(.horizontal, Theme.Space.xxl)
                .padding(.bottom, 34)
            }
        }
        .sheet(isPresented: $showingScanner) {
            ScannerSheet(onValidCode: { pairing in
                showingScanner = false
                startProbe(pairing)
            }, onCancel: { showingScanner = false }, onCameraFailure: { message in
                showingScanner = false
                stage = .problem(title: "Camera unavailable", message: message, retry: nil, openSettings: false)
            })
        }
        .sheet(isPresented: $showingManualEntry) {
            ManualPairSheet(text: $manualText, error: $manualError, onPair: attemptManualPair,
                            onCancel: { showingManualEntry = false })
        }
        .onDisappear { probeTask?.cancel() }
        #if DEBUG
        .onAppear {
            // `-PageDevPairing` launch argument: same as tapping "Skip
            // pairing (DEV)", for simulator screenshots and UI checks.
            // `-PageDevOpen <id>` then opens that mock page's reply screen,
            // and `-PageDevSession` a mock session's detail screen.
            let args = ProcessInfo.processInfo.arguments
            if args.contains("-PageDevPairing") {
                DevBypass.start(pairing: pairing, api: api)
                if let i = args.firstIndex(of: "-PageDevOpen"), i + 1 < args.count {
                    AppRouter.shared.open(interventionId: args[i + 1])
                }
                // `-PageDevSession <id|active>` opens a mock session's detail.
                if let i = args.firstIndex(of: "-PageDevSession"), i + 1 < args.count {
                    AppRouter.shared.openSession(args[i + 1] == "active" ? DevBypass.activeSessionId : args[i + 1])
                }
            }
        }
        #endif
    }

    // MARK: Stage UI

    @ViewBuilder
    private var stageView: some View {
        switch stage {
        case .idle:
            startButtons
        case .checking(let p):
            VStack(spacing: Theme.Space.m) {
                ProgressView()
                Text("Checking \(p.relayHost)…")
                    .font(Theme.Font.body15)
                    .foregroundStyle(Theme.Colour.textMuted)
                Button("Cancel") { cancelProbe() }
                    .font(Theme.Font.body15)
                    .frame(minHeight: 44)
            }
            .padding(.top, Theme.Space.l)
        case .confirm(let p, let macOnline, let unused):
            confirmCard(p, macOnline: macOnline, unused: unused)
        case .problem(let title, let message, let retry, let openSettings):
            VStack(spacing: Theme.Space.m) {
                StatusBanner(tone: .error, systemImage: "exclamationmark.triangle", title: title, message: message)
                if openSettings {
                    primaryButton("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                }
                if let retry {
                    primaryButton("Try again") { startProbe(retry) }
                }
                Button("Start over") { stage = .idle }
                    .font(Theme.Font.body15)
                    .foregroundStyle(Theme.Colour.textMuted)
                    .frame(minHeight: 44)
            }
        }
    }

    private var startButtons: some View {
        VStack(spacing: Theme.Space.m) {
            primaryButton("Scan pairing code") { Task { await openScanner() } }
            Button("Enter pairing code manually") {
                manualError = nil
                showingManualEntry = true
            }
            .font(Theme.Font.body15)
            .foregroundStyle(Theme.Colour.textMuted)
            .frame(minHeight: 44)

            #if DEBUG
            Button("Skip pairing (DEV)") {
                DevBypass.start(pairing: pairing, api: api)
            }
            .font(Theme.Font.caption12)
            .foregroundStyle(Theme.Colour.textMuted)
            #endif
        }
        .padding(.top, Theme.Space.l)
    }

    private func confirmCard(_ p: ValidatedPairing, macOnline: Bool?, unused: Bool) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text("Pair with \(p.macName)?")
                .font(Theme.Font.title17)
                .foregroundStyle(Theme.Colour.text)
            Text("Relay: \(p.relayHost)")
                .font(Theme.Font.mono13)
                .foregroundStyle(Theme.Colour.textMuted)
                .lineLimit(1)
                .truncationMode(.middle)
            switch macOnline {
            case true?:
                Label("Your Mac is connected to this relay.", systemImage: "checkmark.circle.fill")
                    .font(Theme.Font.caption12)
                    .foregroundStyle(Theme.Colour.success)
            case false? where unused:
                Label("No Mac has connected to this relay with this code yet. If it's an old screenshot or you regenerated the token on your Mac, show the pairing code on your Mac again and scan the new one.", systemImage: "exclamationmark.triangle")
                    .font(Theme.Font.caption12)
                    .foregroundStyle(Theme.Colour.destructiveText)
            case false?:
                Label("Your Mac isn't connected to this relay right now. That's fine — pages will arrive once it is.", systemImage: "exclamationmark.circle")
                    .font(Theme.Font.caption12)
                    .foregroundStyle(Theme.Colour.warning)
            case nil:
                EmptyView()
            }
            Text("Only pair with a code from your own Mac: whoever runs this relay sees your pages and replies.")
                .font(Theme.Font.caption12)
                .foregroundStyle(Theme.Colour.textMuted)
            primaryButton("Pair") { confirm(p) }
            Button("Cancel") { stage = .idle }
                .font(Theme.Font.body15)
                .foregroundStyle(Theme.Colour.textMuted)
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .cardStyle()
    }

    private func primaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(Theme.Font.button17)
                .frame(maxWidth: .infinity)
                .frame(minHeight: primaryHeight)
                .background(Theme.Colour.pulseGradient(scheme))
                .foregroundStyle(Theme.Colour.onAccent)
                .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: Flow

    private func openScanner() async {
        guard AVCaptureDevice.default(for: .video) != nil else {
            stage = .problem(title: "No camera available",
                             message: "This device can't scan codes. Use “Enter pairing code manually” and paste the pairing JSON from your Mac (Pair phone… → Copy pairing JSON).",
                             retry: nil, openSettings: false)
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            showingScanner = true
        case .notDetermined:
            if await AVCaptureDevice.requestAccess(for: .video) {
                showingScanner = true
            } else {
                stage = cameraDeniedProblem
            }
        default:
            stage = cameraDeniedProblem
        }
    }

    private var cameraDeniedProblem: Stage {
        .problem(title: "Camera access is off",
                 message: "Allow camera access for Page in Settings to scan the code, or enter the pairing code manually.",
                 retry: nil, openSettings: true)
    }

    private func attemptManualPair() {
        switch PairingValidator.validate(manualText) {
        case .success(let p):
            showingManualEntry = false
            manualText = ""
            startProbe(p)
        case .failure(let err):
            manualError = err.message
        }
    }

    private func startProbe(_ p: ValidatedPairing) {
        probeTask?.cancel()
        stage = .checking(p)
        probeTask = Task {
            let result = await api.probe(p)
            guard !Task.isCancelled, stage == .checking(p) else { return }
            switch result {
            case .ok(let snapshot):
                stage = .confirm(p, macOnline: snapshot?.macConnected, unused: snapshot?.looksUnused ?? false)
            case .unreachable(let why):
                stage = .problem(title: "Can't reach the relay",
                                 message: "\(why) Check your iPhone's connection, and that relayURL in your Mac's Page settings is your deployed Worker (\(p.relayHost)).",
                                 retry: p, openSettings: false)
            case .notPageRelay:
                stage = .problem(title: "That's not a Page relay",
                                 message: "\(p.relayHost) didn't answer like a Page relay. Check relayURL in your Mac's Page settings, then show the pairing code again.",
                                 retry: p, openSettings: false)
            case .unauthorized:
                stage = .problem(title: "The relay rejected this code",
                                 message: "Show the pairing code on your Mac again and scan the new one.",
                                 retry: nil, openSettings: false)
            case .retired(let why):
                stage = .problem(title: "This code was replaced",
                                 message: "\(TokenRetirement.sentence(why)) On your Mac, open Page → Pair phone… and scan the code shown there now.",
                                 retry: nil, openSettings: false)
            }
        }
    }

    private func cancelProbe() {
        probeTask?.cancel()
        probeTask = nil
        stage = .idle
    }

    private func confirm(_ p: ValidatedPairing) {
        if pairing.adopt(p) {
            onPaired?()
        } else {
            stage = .problem(title: "Couldn't save the pairing",
                             message: "iOS refused to store the pairing in the Keychain. Unlock your iPhone and try again.",
                             retry: p, openSettings: false)
        }
    }
}

// MARK: - Manual pair sheet

private struct ManualPairSheet: View {
    @Binding var text: String
    @Binding var error: String?
    let onPair: () -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Colour.surface.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Space.l) {
                        Text("On your Mac, click the Page menu-bar icon → Pair phone… → Copy pairing JSON, then paste it here.")
                            .font(Theme.Font.body15)
                            .foregroundStyle(Theme.Colour.textMuted)

                        TextEditor(text: $text)
                            .font(Theme.Font.mono13)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .scrollContentBackground(.hidden)
                            .padding(8)
                            .frame(minHeight: 160)
                            .background(Theme.Colour.surfaceRaised)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.Colour.hairline, lineWidth: 1))
                            .accessibilityLabel("Pairing code")

                        Button {
                            if let pasted = UIPasteboard.general.string { text = pasted }
                            error = nil
                        } label: {
                            Label("Paste from clipboard", systemImage: "doc.on.clipboard")
                                .font(Theme.Font.bodyEm)
                                .frame(minHeight: 44)
                        }

                        if let error {
                            Text(error)
                                .foregroundStyle(Theme.Colour.destructiveText)
                                .font(Theme.Font.caption12)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(Theme.Space.xxl)
                }
            }
            .navigationTitle("Enter pairing code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Pair", action: onPair)
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

// MARK: - QR scanner

/// Full-screen scanner with a viewfinder, instructions and Cancel. Codes
/// that aren't Page pairing codes show an inline hint and scanning carries
/// on, instead of closing the sheet and silently doing nothing.
private struct ScannerSheet: View {
    let onValidCode: (ValidatedPairing) -> Void
    let onCancel: () -> Void
    let onCameraFailure: (String) -> Void
    @State private var hint: String?
    @State private var accepted = false

    var body: some View {
        ZStack {
            QRScannerView(onCode: handle, onFailure: onCameraFailure)
                .ignoresSafeArea()
            VStack(spacing: Theme.Space.l) {
                HStack {
                    Spacer()
                    Button("Cancel", action: onCancel)
                        .font(Theme.Font.bodyEm)
                        .foregroundStyle(.white)
                        .padding(.horizontal, Theme.Space.l)
                        .frame(minHeight: 44)
                        .background(.black.opacity(0.4), in: Capsule())
                }
                .padding(Theme.Space.l)
                Spacer()
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(.white.opacity(0.85), lineWidth: 3)
                    .frame(width: 240, height: 240)
                    .accessibilityHidden(true)
                Spacer()
                Text(hint ?? "Point the camera at the QR code in Page on your Mac.")
                    .font(Theme.Font.bodyEm)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(Theme.Space.l)
                    .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .padding(.horizontal, Theme.Space.xl)
                    .padding(.bottom, 40)
                    .accessibilityAddTraits(.updatesFrequently)
            }
        }
        .background(Color.black)
    }

    private func handle(_ text: String) {
        guard !accepted else { return }
        switch PairingValidator.validate(text) {
        case .success(let p):
            accepted = true
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            onValidCode(p)
        case .failure(let err):
            hint = err.message
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
        }
    }
}

private struct QRScannerView: UIViewControllerRepresentable {
    let onCode: (String) -> Void
    let onFailure: (String) -> Void

    func makeUIViewController(context: Context) -> QRScannerVC {
        let vc = QRScannerVC()
        vc.onCode = onCode
        vc.onFailure = onFailure
        return vc
    }

    func updateUIViewController(_ vc: QRScannerVC, context: Context) {
        vc.onCode = onCode
        vc.onFailure = onFailure
    }
}

private final class QRScannerVC: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onCode: ((String) -> Void)?
    var onFailure: ((String) -> Void)?

    // All AVCaptureSession work happens on sessionQueue (startRunning /
    // stopRunning block for hundreds of milliseconds). The session is only
    // configured, started and stopped there; the main thread just hands it
    // to the preview layer, which AVFoundation allows.
    nonisolated(unsafe) private let session = AVCaptureSession()
    nonisolated private let sessionQueue = DispatchQueue(label: "page.qr-scanner")
    private var preview: AVCaptureVideoPreviewLayer?
    private var lastCode: String?
    private var lastCodeAt = Date.distantPast

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        let pv = AVCaptureVideoPreviewLayer(session: session)
        pv.videoGravity = .resizeAspectFill
        pv.frame = view.bounds
        view.layer.addSublayer(pv)
        preview = pv
        sessionQueue.async { [weak self] in self?.configureSession() }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        preview?.frame = view.bounds
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        let session = self.session
        sessionQueue.async { if session.isRunning { session.stopRunning() } }
    }

    /// Runs on sessionQueue.
    nonisolated private func configureSession() {
        guard let device = AVCaptureDevice.default(for: .video) else {
            fail("This device has no camera. Enter the pairing code manually instead.")
            return
        }
        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch {
            fail("The camera couldn't be started (\(error.localizedDescription)). Check camera access for Page in Settings, or enter the code manually.")
            return
        }
        session.beginConfiguration()
        guard session.canAddInput(input) else {
            session.commitConfiguration()
            fail("The camera is in use by something else. Try again in a moment.")
            return
        }
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            fail("QR scanning isn't supported on this device. Enter the code manually instead.")
            return
        }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: sessionQueue)
        output.metadataObjectTypes = output.availableMetadataObjectTypes.contains(.qr) ? [.qr] : []
        session.commitConfiguration()
        session.startRunning()
    }

    nonisolated private func fail(_ message: String) {
        Task { @MainActor [weak self] in self?.onFailure?(message) }
    }

    /// Delivered on sessionQueue; hops to main and drops repeats of the same
    /// code (the camera reports it many times a second).
    nonisolated func metadataOutput(_ output: AVCaptureMetadataOutput,
                        didOutput metadataObjects: [AVMetadataObject],
                        from connection: AVCaptureConnection) {
        guard let obj = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              let code = obj.stringValue else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let now = Date()
            if code == self.lastCode, now.timeIntervalSince(self.lastCodeAt) < 2 { return }
            self.lastCode = code
            self.lastCodeAt = now
            self.onCode?(code)
        }
    }
}
