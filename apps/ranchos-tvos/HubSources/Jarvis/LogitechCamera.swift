#if os(macOS)
import SwiftUI
@preconcurrency import AVFoundation

// All capture configuration and start/stop operations run on this serial queue.
private final class CameraPipeline: @unchecked Sendable {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "JarvisDEV.camera")
    func start(completion: @escaping @Sendable (Bool) -> Void) {
        queue.async { [self] in
            let devices = AVCaptureDevice.DiscoverySession(deviceTypes: [.external], mediaType: .video, position: .unspecified).devices
            guard let device = devices.first(where: { $0.localizedName == "HD Pro Webcam C920" }) else {
                completion(false); return
            }
            do {
                session.beginConfiguration()
                defer { session.commitConfiguration() }
                for input in session.inputs { session.removeInput(input) }
                let input = try AVCaptureDeviceInput(device: device)
                guard session.canAddInput(input) else { completion(false); return }
                session.addInput(input)
            } catch { completion(false); return }
            session.startRunning()
            completion(session.isRunning)
        }
    }
    func stop() { queue.async { [self] in session.stopRunning() } }
}

@MainActor private final class CameraPreviewView: NSView {
    let preview: AVCaptureVideoPreviewLayer
    init(session: AVCaptureSession) {
        preview = AVCaptureVideoPreviewLayer(session: session)
        super.init(frame: .zero)
        wantsLayer = true
        preview.videoGravity = .resizeAspect
        layer?.addSublayer(preview)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    override func layout() { super.layout(); preview.frame = bounds }
}
private struct CameraSurface: NSViewRepresentable {
    let session: AVCaptureSession
    func makeNSView(context: Context) -> CameraPreviewView { CameraPreviewView(session: session) }
    func updateNSView(_ view: CameraPreviewView, context: Context) {}
}

@MainActor struct LogitechCamera: View {
    @State private var pipeline = CameraPipeline()
    @State private var active = false
    @State private var token: UUID?
    @State private var status = "Logitech C920 · Local preview only"
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button(active ? "Stop camera" : "Start Logitech camera") {
                    if active { stop() } else { start() }
                }
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
            if active {
                CameraSurface(session: pipeline.session)
                    .frame(height: 220)
                    .accessibilityLabel("Local Logitech C920 camera preview")
            }
        }
        .onDisappear { stop() }
        .onChange(of: scenePhase) { _, phase in if phase != .active { stop() } }
    }
    private func start() {
        let id = UUID()
        token = id
        active = true
        status = "Checking camera permission…"
        Task {
            let allowed = await AVCaptureDevice.requestAccess(for: .video)
            guard token == id else { return }
            guard allowed else { stop(); status = "Camera permission unavailable."; return }
            pipeline.start { running in
                Task { @MainActor in
                    guard token == id else { return }
                    active = running
                    status = running ? "C920 preview · No recording or upload" : "C920 unavailable. Reconnect and retry."
                }
            }
        }
    }
    private func stop() {
        token = nil
        pipeline.stop()
        active = false
        status = "Logitech C920 · Camera off"
    }
}
#endif
