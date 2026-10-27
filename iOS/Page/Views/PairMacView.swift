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
    @EnvironmentObject var router: AppRouter
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
        stageScreen
            .preferredColorScheme(.dark)
            .sheet(isPresented: $showingScanner) {
                ScannerSheet(onValidCode: { pairing in
                    showingScanner = false
                    startProbe(pairing)
                }, onCancel: { showingScanner = false }, onCameraFailure: { message in
                    showingScanner = false
                    stage = .problem(title: "Camera unavailable", message: message, retry: nil, openSettings: false)
                }, onPaste: {
                    showingScanner = false
                    manualError = nil
                    // The scanner has to finish leaving before the next sheet can come up.
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 450_000_000)
                        showingManualEntry = true
                    }
                })
                .presentationBackground(NightWatch.Palette.backgroundDeep.color)
            }
            .sheet(isPresented: $showingManualEntry) {
                ManualPairSheet(text: $manualText, error: $manualError, onPair: attemptManualPair,
                                onCancel: { showingManualEntry = false })
                    .presentationBackground(NightWatch.Palette.backgroundDeep.color)
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
                // Opened a moment later, once the root view has settled (it resets the router on first activation).
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    if let i = args.firstIndex(of: "-PageDevOpen"), i + 1 < args.count {
                        AppRouter.shared.open(interventionId: args[i + 1])
                    }
                    // `-PageDevSheet tower|tower-budget|dispatch|history` opens that sheet, and
                    // `-PageDevDestination lanes` starts on Lanes (mock data only, for screenshots).
                    if let i = args.firstIndex(of: "-PageDevSheet"), i + 1 < args.count {
                        switch args[i + 1] {
                        case "tower": AppRouter.shared.openTower()
                        case "tower-budget": AppRouter.shared.openTower(.budget)
                        case "dispatch": AppRouter.shared.openDispatch()
                        case "history": AppRouter.shared.openHistory()
                        default: break
                        }
                    }
                    if let i = args.firstIndex(of: "-PageDevDestination"), i + 1 < args.count, ["lanes", "sky"].contains(args[i + 1]) {
                        AppRouter.shared.destination = .lanes
                    }
                    // `-PageDevSession <id|active>` opens a mock session's detail.
                    if let i = args.firstIndex(of: "-PageDevSession"), i + 1 < args.count {
                        AppRouter.shared.openSession(args[i + 1] == "active" ? DevBypass.activeSessionId : args[i + 1])
                    }
                }
            }
        }
        #endif
    }

    // MARK: Stage UI

    /// Each stage is one Night Watch screen: Welcome, then (behind the
    /// scanner sheet) the relay check, the confirmation and any problem.
    @ViewBuilder
    private var stageScreen: some View {
        switch stage {
        case .idle:
            NWWelcomeScreen(notice: retirementNotice, onPair: { Task { await openScanner() } },
                            onDismissNotice: { pairing.dismissRetirementNotice() }, onSkipDev: devSkip)
        case .checking(let p):
            NWPairStep(content: .checking(host: p.relayHost), onSecondary: { cancelProbe() }, secondaryTitle: "Cancel")
        case .confirm(let p, let macOnline, let unused):
            NWPairStep(content: .confirm(mac: p.macName, host: p.relayHost, online: macOnline, unused: unused),
                       onPrimary: { confirm(p) }, primaryTitle: "Pair", onSecondary: { stage = .idle }, secondaryTitle: "Cancel")
        case .problem(let title, let message, let retry, let openSettings):
            NWPairStep(content: .problem(title: title, message: message),
                       onPrimary: problemPrimary(retry: retry, openSettings: openSettings),
                       primaryTitle: openSettings ? "Open Settings" : "Try again",
                       onSecondary: { stage = .idle }, secondaryTitle: "Start over")
        }
    }

    private var retirementNotice: (title: String, message: String)? {
        pairing.retirementNotice.map { ("Pair again", "\(TokenRetirement.sentence($0)) Your old inbox and history were cleared.") }
    }

    private var devSkip: (() -> Void)? {
        #if DEBUG
        return { DevBypass.start(pairing: pairing, api: api) }
        #else
        return nil
        #endif
    }

    private func problemPrimary(retry: ValidatedPairing?, openSettings: Bool) -> (() -> Void)? {
        if openSettings {
            return { if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } }
        }
        if let retry { return { startProbe(retry) } }
        return nil
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
        // A first pairing ends on the Paired screen, so Page must not ask for notifications before it.
        let firstMac = onPaired == nil && pairing.savedMacs.isEmpty
        if firstMac { router.pairedWelcome = true }
        if pairing.adopt(p) {
            onPaired?()
        } else {
            if firstMac { router.pairedWelcome = false }
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

    private var empty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        ZStack {
            NWBackdrop()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack {
                        Button("Cancel", action: onCancel).font(NightWatch.Typo.bodyStrong)
                            .foregroundColor(NightWatch.Palette.textSecondary.color).frame(minHeight: 44)
                        Spacer()
                        Button("Pair", action: onPair).font(NightWatch.Typo.bodyStrong)
                            .foregroundColor((empty ? NightWatch.Palette.textQuiet : NightWatch.Palette.teal).color)
                            .frame(minHeight: 44).disabled(empty)
                    }
                    Text("Enter pairing code").font(.system(size: 30, weight: .bold)).kerning(-0.8)
                        .foregroundColor(NightWatch.Palette.textPrimary.color).accessibilityAddTraits(.isHeader)
                    Text("On your Mac, click the Page menu-bar icon → Pair phone… → Copy pairing JSON, then paste it here.")
                        .font(NightWatch.Typo.body).foregroundColor(NightWatch.Palette.textSecondary.color)
                    TextEditor(text: $text)
                        .font(NightWatch.Typo.monoBody)
                        .foregroundColor(NightWatch.Palette.textPrimary.color)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .scrollContentBackground(.hidden)
                        .padding(10)
                        .frame(minHeight: 170)
                        .background(NWGlassBackground(radius: 18, fill: NightWatch.Palette.surface.opacity(0.95)))
                        .accessibilityLabel("Pairing code")
                    Button {
                        if let pasted = UIPasteboard.general.string { text = pasted }
                        error = nil
                    } label: {
                        HStack(spacing: 10) { Image(systemName: "doc.on.clipboard"); Text("Paste from clipboard") }
                    }
                    .buttonStyle(NWButtonStyle(kind: .quiet))
                    if let error {
                        Text(error).foregroundColor(NightWatch.Palette.amber.color).font(NightWatch.Typo.caption)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(24)
            }
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - QR scanner

/// The scanner: the camera sits in the viewfinder window. Codes that aren't
/// Page pairing codes show an inline hint and scanning carries on, instead of
/// closing the sheet and silently doing nothing.
private struct ScannerSheet: View {
    let onValidCode: (ValidatedPairing) -> Void
    let onCancel: () -> Void
    let onCameraFailure: (String) -> Void
    let onPaste: () -> Void
    @State private var hint: String?
    @State private var accepted = false

    var body: some View {
        NWScanScreen(hint: hint, onPaste: onPaste, onCancel: onCancel) {
            QRScannerView(onCode: handle, onFailure: onCameraFailure)
        }
        .preferredColorScheme(.dark)
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
