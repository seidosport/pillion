import SwiftUI
import ReplayKit
import ComposeApp

/// Connects the shared Compose UI to iOS screen broadcasting:
/// - the Pillion "Start mirroring" button → triggers the system broadcast picker,
/// - the extension's broadcast start/stop Darwin notifications → the shared `MirrorState`.
final class BroadcastBridge: ObservableObject {
    let controller: BroadcastMirrorController        // NaviLite (Bluetooth / MFi via ReplayKit)
    let sdlController: SdlBroadcastController         // SDL (USB / iAP2)
    private let sdlSession: SdlSession
    private weak var picker: RPSystemBroadcastPickerView?

    init() {
        controller = BroadcastMirrorController()
        sdlController = SdlBroadcastController()
        // Build the SDL session first, then connect the Kotlin controller's state in (the closure has to
        // be assigned after sdlController exists), and route start/stop from the UI down to the session.
        let sdlController = self.sdlController
        sdlSession = SdlSession(onState: { state in
            DispatchQueue.main.async {
                switch state {
                case .idle: sdlController.setIdle()
                case .connecting: sdlController.setConnecting()
                case .streaming: sdlController.setStreaming()
                case .error(let message): sdlController.setError(message: message)
                }
            }
        })
        controller.onToggle = { [weak self] in self?.triggerPicker() }
        self.sdlController.onStart = { [weak self] in self?.sdlSession.start() }
        self.sdlController.onStop = { [weak self] in self?.sdlSession.stop() }
        observeBroadcastState()
    }

    func makeViewController() -> UIViewController {
        MainViewControllerKt.MainViewController(
            naviliteController: controller,
            sdlController: sdlController,
            onShareDiagnostics: { [weak self] in self?.shareDiagnostics() })
    }

    /// Settings → "Share diagnostics": hand the extension's App Group log(s) to the iOS share sheet so a
    /// remote tester (no Mac/Xcode) can send them to us. The broadcast extension writes sdl_ext_log.txt
    /// (and any other *.txt/*.log) into the shared container; the main app reads the same container.
    private func shareDiagnostics() {
        guard let container = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: "group.app.pillion") else { return }
        let files = ((try? FileManager.default.contentsOfDirectory(
            at: container, includingPropertiesForKeys: nil)) ?? [])
            .filter { ["txt", "log"].contains($0.pathExtension.lowercased()) }
        guard let top = Self.topViewController() else { return }
        guard !files.isEmpty else {
            let a = UIAlertController(title: "No diagnostics yet",
                                      message: "Run a mirroring session first, then share the log.",
                                      preferredStyle: .alert)
            a.addAction(UIAlertAction(title: "OK", style: .default))
            top.present(a, animated: true)
            return
        }
        let share = UIActivityViewController(activityItems: files, applicationActivities: nil)
        share.popoverPresentationController?.sourceView = top.view   // iPad needs an anchor
        share.popoverPresentationController?.sourceRect =
            CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 0, height: 0)
        top.present(share, animated: true)
    }

    private static func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes.first { $0.activationState == .foregroundActive } as? UIWindowScene
        var vc = (scene?.windows.first { $0.isKeyWindow } ?? scene?.windows.first)?.rootViewController
        while let presented = vc?.presentedViewController { vc = presented }
        return vc
    }

    /// Called by `BroadcastPickerHost` once the (hidden) picker view exists.
    func register(_ picker: RPSystemBroadcastPickerView) { self.picker = picker }

    private func triggerPicker() {
        // RPSystemBroadcastPickerView has no programmatic trigger, so tap its embedded button.
        // Its view tree differs across iOS versions, so search recursively.
        guard let picker = picker, let button = Self.firstButton(in: picker) else { return }
        button.sendActions(for: .touchUpInside)
    }

    private static func firstButton(in view: UIView) -> UIButton? {
        if let button = view as? UIButton { return button }
        for sub in view.subviews { if let b = firstButton(in: sub) { return b } }
        return nil
    }

    private func observeBroadcastState() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let me = Unmanaged.passUnretained(self).toOpaque()
        let callback: CFNotificationCallback = { _, observer, name, _, _ in
            guard let observer = observer, let name = name else { return }
            let bridge = Unmanaged<BroadcastBridge>.fromOpaque(observer).takeUnretainedValue()
            let active = (name.rawValue as String) == "app.pillion.broadcast.started"
            DispatchQueue.main.async { bridge.controller.setActive(active: active) }
        }
        for name in ["app.pillion.broadcast.started", "app.pillion.broadcast.stopped"] {
            CFNotificationCenterAddObserver(center, me, callback, name as CFString, nil, .deliverImmediately)
        }
    }
}
