import SwiftUI
import ReplayKit
import ComposeApp

/// The one line of the rider's own text the extension can be told about, and the one place that
/// sends it. The key matches the `@AppStorage` name in the diagnostics screen, its only writer.
enum DashSettings {
    static func banner() -> String { UserDefaults.standard.string(forKey: "dash.banner") ?? "" }
    static func pushAll() { DashBanner.post(banner()) }
}

/// Connects the shared Compose UI to iOS screen broadcasting:
/// - the Pillion "Start mirroring" button → triggers the system broadcast picker,
/// - the extension's broadcast start/stop Darwin notifications → the shared `MirrorState`.
final class BroadcastBridge: ObservableObject {
    let controller: BroadcastMirrorController        // NaviLite (Bluetooth / MFi via ReplayKit)
    let sdlController: SdlBroadcastController         // SDL (USB / iAP2)
    /// Dash-only settings shown in the shared Settings screen. Kotlin remembers the values; putting
    /// the banner on a running mirror is this side's job, since the Darwin channel lives here.
    let dashExtras = IosDashExtras()
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
        dashExtras.onSendBanner = { text in DashBanner.post(text) }
        self.sdlController.onStart = { [weak self] in self?.sdlSession.start() }
        self.sdlController.onStop = { [weak self] in self?.sdlSession.stop() }
        observeBroadcastState()
    }

    func makeViewController() -> UIViewController {
        MainViewControllerKt.MainViewController(naviliteController: controller,
                                                sdlController: sdlController,
                                                dashExtras: dashExtras)
    }

    /// Called by `BroadcastPickerHost` once the (hidden) picker view exists.
    func register(_ picker: RPSystemBroadcastPickerView) { self.picker = picker }

    private func triggerPicker() {
        // RPSystemBroadcastPickerView has no programmatic trigger, so tap its embedded button.
        // Its view tree differs across iOS versions, so search recursively.
        guard let picker = picker, let button = Self.firstButton(in: picker) else { return }
        button.sendActions(for: .touchUpInside)
    }

    /// Hand the rider straight to the navigation app once the mirror is live.
    ///
    /// Only the app can do this — an extension has no `UIApplication` — and only right here: the
    /// broadcast starts with Pillion in the foreground (the system picker was just dismissed over
    /// it), which is the one moment iOS will honour an app-to-app open. A beat's delay lets the
    /// picker finish dismissing first, or the open lands on a view controller that's going away.
    func launchNavAppIfWanted() {
        guard UserDefaults.standard.bool(forKey: "launch.nav.app") else { return }
        guard let url = URL(string: "waze://") else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            guard UIApplication.shared.canOpenURL(url) else { return }
            UIApplication.shared.open(url)
        }
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
            let n = name.rawValue as String
            // The extension has just come up with its observers in place and no way to read the
            // rider's settings; hand it the current ones before it reaches the handshake.
            if n == DashConfig.request {
                DispatchQueue.main.async { DashSettings.pushAll() }
                return
            }
            let active = n == "app.pillion.broadcast.started"
            DispatchQueue.main.async {
                bridge.controller.setActive(active: active)
                if active { bridge.launchNavAppIfWanted() }
            }
        }
        for name in ["app.pillion.broadcast.started", "app.pillion.broadcast.stopped", DashConfig.request] {
            CFNotificationCenterAddObserver(center, me, callback, name as CFString, nil, .deliverImmediately)
        }
    }
}
