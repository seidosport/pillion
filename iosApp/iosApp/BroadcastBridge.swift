import SwiftUI
import ReplayKit
import ComposeApp

/// The app's copy of everything the extension can be told, and the one place that sends it.
///
/// Kept together because it is only ever used as a set: a single change is posted the moment the
/// rider makes it, and the whole lot is replayed when the extension asks for it — it starts with no
/// way to read these itself (see DashInset). Keys match the `@AppStorage` names in the diagnostics
/// screen, which is the only writer.
enum DashSettings {
    static func bottom() -> Int { int("dash.inset.bottom", DashInset.defaultBottom) }
    static func left() -> Int { int("dash.inset.left", DashInset.defaultLeft) }
    static func crop(_ side: DashCropSide) -> Int { int(cropKey(side), side.defaultPercent) }
    static func fill() -> String { UserDefaults.standard.string(forKey: "dash.fill") ?? DashFill.fallback.rawValue }
    static func banner() -> String { UserDefaults.standard.string(forKey: "dash.banner") ?? "" }

    static func cropKey(_ side: DashCropSide) -> String { "dash.crop.\(side.rawValue)" }

    /// Unset is not zero: someone who never opens the settings screen still gets the measured
    /// defaults, and `UserDefaults.integer` would hand back 0 for every one of them.
    private static func int(_ key: String, _ fallback: Int) -> Int {
        UserDefaults.standard.object(forKey: key) == nil
            ? fallback : UserDefaults.standard.integer(forKey: key)
    }

    static func pushAll() {
        postDarwinNotification(DashInset.bottomName(bottom()))
        postDarwinNotification(DashInset.leftName(left()))
        postDarwinNotification(fill())
        for side in DashCropSide.allCases { postDarwinNotification(DashCrop.name(side, crop(side))) }
        DashBanner.post(banner())
    }
}

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
        MainViewControllerKt.MainViewController(naviliteController: controller, sdlController: sdlController)
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
