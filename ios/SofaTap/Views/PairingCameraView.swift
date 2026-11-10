import SwiftUI
import UIKit
import AVFoundation

struct ScannerSheet: View {
    var accepts: (String) -> Bool = { (try? Pairing.parse($0)) != nil }
    let onScan: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var error: String?
    var body: some View {
        SofaNavigationStack {
            ZStack {
                Color.black
                QRScanner(isActive: scenePhase == .active, accepts: accepts, onScan: onScan, onError: { error = $0 })
                VStack {
                    Text(String(localized: "将 Sofatap 配对二维码放入画面"))
                        .font(.system(size: 15, weight: .medium))
                        .padding(14).background(.black.opacity(0.65), in: Capsule())
                    Spacer()
                    if let error {
                        Text(error).font(.system(size: 15)).multilineTextAlignment(.center)
                            .padding(20).background(Palette.panel, in: RoundedRectangle(cornerRadius: 18))
                        Button(String(localized: "返回粘贴配对链接")) { dismiss() }
                            .padding(15).tint(Palette.mint)
                    }
                }.padding(24)
            }
            .navigationTitle(String(localized: "扫描二维码"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button(String(localized: "取消")) { dismiss() } } }
        }
    }
}

struct QRScanner: UIViewControllerRepresentable {
    var isActive = true
    let accepts: (String) -> Bool
    let onScan: (String) -> Void
    let onError: (String) -> Void
    func makeUIViewController(context: Context) -> ScannerController {
        ScannerController(isActive: isActive, accepts: accepts, onScan: onScan, onError: onError)
    }
    func updateUIViewController(_ controller: ScannerController, context: Context) { controller.setActive(isActive) }
    static func dismantleUIViewController(_ controller: ScannerController, coordinator: ()) { controller.stop() }
}

final class ScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    private let capture = AVCaptureSession()
    private let cameraQueue = DispatchQueue(label: "com.chekusu.sofatap.camera")
    private let accepts: (String) -> Bool
    private let onScan: (String) -> Void
    private let onError: (String) -> Void
    private var preview: AVCaptureVideoPreviewLayer?
    private var previewAngleBinder: AnyObject?
    private var orientationObserver: NSObjectProtocol?
    private var scanned = false
    private var stopped = false
    private var wantsActive: Bool
    private var configured = false
    private var requestingPermission = false
    private var lastInvalidCodeAt = Date.distantPast
    init(isActive: Bool, accepts: @escaping (String) -> Bool, onScan: @escaping (String) -> Void, onError: @escaping (String) -> Void) {
        self.wantsActive = isActive
        self.accepts = accepts; self.onScan = onScan; self.onError = onError
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        authorizeCamera()
    }
    private func authorizeCamera() {
        guard wantsActive, !stopped, !configured, !requestingPermission else { return }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: configure()
        case .notDetermined:
            requestingPermission = true
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self, !self.stopped else { return }
                    self.requestingPermission = false
                    if granted { self.configure() }
                    else { self.onError(String(localized: "相机权限未开启。可在设置中开启，或粘贴接收器中的完整配对链接。")) }
                }
            }
        default: onError(String(localized: "相机权限未开启。可在设置中开启，或粘贴接收器中的完整配对链接。"))
        }
    }
    private func configure() {
        guard wantsActive, !stopped, !configured else { return }
        guard let camera = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: camera) else {
            onError(String(localized: "这台设备没有可用相机。请返回并粘贴接收器中的完整配对链接。"))
            return
        }
        let output = AVCaptureMetadataOutput()
        guard capture.canAddInput(input), capture.canAddOutput(output) else {
            onError(String(localized: "无法打开相机，请尝试粘贴配对链接。"))
            return
        }
        capture.addInput(input)
        capture.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]
        let layer = AVCaptureVideoPreviewLayer(session: capture)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.bounds
        view.layer.addSublayer(layer)
        preview = layer
        // iOS 17 follows the preview angle. iOS 15 uses the interface orientation.
        if #available(iOS 17, *) {
            let binder = PreviewAngleBinder()
            binder.bind(camera: camera, layer: layer) { [weak self] in self?.stopped == true }
            previewAngleBinder = binder
        } else {
            applyLegacyVideoOrientation()
            UIDevice.current.beginGeneratingDeviceOrientationNotifications()
            orientationObserver = NotificationCenter.default.addObserver(
                forName: UIDevice.orientationDidChangeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                self?.applyLegacyVideoOrientation()
            }
        }
        configured = true
        updateCaptureRunning()
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        preview?.frame = view.bounds
        if #unavailable(iOS 17) { applyLegacyVideoOrientation() }
    }
    private func applyLegacyVideoOrientation() {
        guard let connection = preview?.connection, connection.isVideoOrientationSupported else { return }
        let interface = view.window?.windowScene?.interfaceOrientation ?? .portrait
        let orientation: AVCaptureVideoOrientation
        switch interface {
        case .portraitUpsideDown: orientation = .portraitUpsideDown
        case .landscapeLeft: orientation = .landscapeLeft
        case .landscapeRight: orientation = .landscapeRight
        default: orientation = .portrait
        }
        connection.videoOrientation = orientation
    }
    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard wantsActive, !stopped, !scanned, let value = (metadataObjects.first as? AVMetadataMachineReadableCodeObject)?.stringValue else { return }
        // Invalid or unrelated QRs stay in the scanner with actionable feedback.
        guard accepts(value) else {
            if Date().timeIntervalSince(lastInvalidCodeAt) > 1 {
                lastInvalidCodeAt = Date()
                onError(String(localized: "这不是有效的 Sofatap 配对二维码或链接。请在接收器中重新生成。"))
            }
            return
        }
        scanned = true
        stop()
        onScan(value)
    }
    func setActive(_ active: Bool) {
        guard !stopped else { return }
        let changed = wantsActive != active
        wantsActive = active
        if !configured && active && isViewLoaded { authorizeCamera() }
        if changed { updateCaptureRunning() }
    }
    private func updateCaptureRunning() {
        let shouldRun = wantsActive && configured && !stopped && !scanned
        cameraQueue.async { [capture] in
            if shouldRun { if !capture.isRunning { capture.startRunning() } }
            else if capture.isRunning { capture.stopRunning() }
        }
    }
    func stop() {
        stopped = true
        previewAngleBinder = nil
        if let orientationObserver {
            NotificationCenter.default.removeObserver(orientationObserver)
            self.orientationObserver = nil
        }
        updateCaptureRunning()
    }
}

@available(iOS 17, *)
private final class PreviewAngleBinder {
    private var coordinator: AVCaptureDevice.RotationCoordinator?
    private var observation: NSKeyValueObservation?

    func bind(camera: AVCaptureDevice, layer: AVCaptureVideoPreviewLayer, isStopped: @escaping () -> Bool) {
        let rotation = AVCaptureDevice.RotationCoordinator(device: camera, previewLayer: layer)
        coordinator = rotation
        observation = rotation.observe(\.videoRotationAngleForHorizonLevelPreview, options: [.initial, .new]) { rotation, _ in
            let angle = rotation.videoRotationAngleForHorizonLevelPreview
            guard !isStopped(), let connection = layer.connection,
                  connection.isVideoRotationAngleSupported(angle) else { return }
            connection.videoRotationAngle = angle
        }
    }
}
