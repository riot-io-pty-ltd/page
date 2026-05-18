import SwiftUI
import AVFoundation

struct PairMacView: View {
    @EnvironmentObject var pairing: PairingStore
    @EnvironmentObject var api: APIClient
    @State private var showingScanner = false
    @State private var showingManualEntry = false
    @State private var manualToken: String = ""
    @State private var manualError: String?

    var body: some View {
        ZStack {
            Theme.Colour.surface.ignoresSafeArea()
            VStack(spacing: Theme.Space.xxl) {
                Spacer().frame(height: 40)
                PulseMark(size: 96)
                Text("Pair your Mac")
                    .font(Theme.Font.display22)
                    .foregroundStyle(Theme.Colour.text)
                Text("Open ClaudePowerMode on your Mac, click the menu-bar icon → Pair phone…, and scan the QR code shown there.")
                    .font(Theme.Font.body15)
                    .foregroundStyle(Theme.Colour.textMuted)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, Theme.Space.l)

                Spacer()

                Button(action: { showingScanner = true }) {
                    Text("Open camera")
                        .font(.system(size: 17, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .background(Theme.Colour.pulseGradient(.light))
                        .foregroundStyle(Color(hex: "#15171A"))
                        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                }
                .buttonStyle(.plain)

                Button("Enter pairing code manually") {
                    manualError = nil
                    showingManualEntry = true
                }
                .font(Theme.Font.body15)
                .foregroundStyle(Theme.Colour.textMuted)

                #if DEBUG
                Button("Skip pairing (DEV)") {
                    pairing.adopt(payload: DevBypass.fakePairingPayload())
                    api.seedDevInbox(DevBypass.fakeInterventions())
                }
                .font(Theme.Font.caption12)
                .foregroundStyle(Theme.Colour.textMuted)
                #endif
            }
            .padding(.horizontal, Theme.Space.xxl)
            .padding(.bottom, 34)
        }
        .sheet(isPresented: $showingScanner) {
            QRScannerView { result in
                showingScanner = false
                handleScan(result)
            }
        }
        .sheet(isPresented: $showingManualEntry) {
            ManualPairSheet(
                manualToken: $manualToken,
                manualError: $manualError,
                onPair: attemptManualPair,
                onCancel: { showingManualEntry = false }
            )
            .environmentObject(pairing)
        }
    }

    private func attemptManualPair() {
        let trimmed = manualToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if let payload = pairing.parse(qrText: trimmed) {
            pairing.adopt(payload: payload)
            api.connectWebSocket()
            showingManualEntry = false
        } else {
            manualError = "Couldn't parse that. Paste the full JSON shown on your Mac (it should start with { and end with })."
        }
    }

    private func handleScan(_ result: Result<String, Error>) {
        switch result {
        case .success(let text):
            if let payload = pairing.parse(qrText: text) {
                pairing.adopt(payload: payload)
                api.connectWebSocket()
            }
        case .failure:
            break
        }
    }
}

// MARK: - Manual pair sheet

private struct ManualPairSheet: View {
    @Binding var manualToken: String
    @Binding var manualError: String?
    let onPair: () -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Colour.surface.ignoresSafeArea()
                VStack(alignment: .leading, spacing: Theme.Space.l) {
                    Text("Paste the pairing JSON from your Mac. On your Mac, click the menu-bar icon → Pair phone… → Copy pairing JSON, then paste it here.")
                        .font(Theme.Font.body15)
                        .foregroundStyle(Theme.Colour.textMuted)

                    TextEditor(text: $manualToken)
                        .font(Theme.Font.mono13)
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .frame(minHeight: 180)
                        .background(Theme.Colour.surfaceRaised)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .strokeBorder(Theme.Colour.hairline, lineWidth: 1)
                        )

                    if let err = manualError {
                        Text(err)
                            .foregroundStyle(Theme.Colour.destructive)
                            .font(Theme.Font.caption12)
                    }

                    Button(action: onPair) {
                        Text("Pair")
                            .font(.system(size: 17, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .frame(height: 52)
                            .background(Theme.Colour.pulseGradient(.light))
                            .foregroundStyle(Color(hex: "#15171A"))
                            .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(manualToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    Spacer()
                }
                .padding(Theme.Space.xxl)
            }
            .navigationTitle("Manual pair")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel", action: onCancel)
                }
            }
        }
    }
}

// MARK: - QR scanner

struct QRScannerView: UIViewControllerRepresentable {
    let completion: (Result<String, Error>) -> Void

    func makeUIViewController(context: Context) -> QRScannerVC {
        QRScannerVC(completion: completion)
    }
    func updateUIViewController(_ uiViewController: QRScannerVC, context: Context) {}
}

final class QRScannerVC: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    enum ScanError: Error { case noCamera, denied }
    private let completion: (Result<String, Error>) -> Void
    private let session = AVCaptureSession()
    private var preview: AVCaptureVideoPreviewLayer?

    init(completion: @escaping (Result<String, Error>) -> Void) {
        self.completion = completion
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            completion(.failure(ScanError.noCamera)); dismiss(animated: true); return
        }
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        if session.canAddOutput(output) {
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            output.metadataObjectTypes = [.qr]
        }
        let pv = AVCaptureVideoPreviewLayer(session: session)
        pv.videoGravity = .resizeAspectFill
        pv.frame = view.bounds
        view.layer.addSublayer(pv)
        preview = pv
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.session.startRunning()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        preview?.frame = view.bounds
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput,
                        didOutput metadataObjects: [AVMetadataObject],
                        from connection: AVCaptureConnection) {
        guard let obj = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              let str = obj.stringValue else { return }
        session.stopRunning()
        completion(.success(str))
        dismiss(animated: true)
    }
}
