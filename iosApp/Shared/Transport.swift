import Foundation

/// A NaviLite frame read off the wire.
struct NaviFrame { let svc: Int; let payload: [UInt8] }

/// A bidirectional NaviLite byte link the broadcast extension streams over — implemented by the bike
/// (`EAConn`, External Accessory) and the dev emulator (`TCPConn`, plain TCP). The extension is
/// transport-agnostic, exactly like the shared engine on the app side.
protocol DashConn: AnyObject {
    var logger: ((String) -> Void)? { get set }
    func connect() throws
    func write(_ bytes: [UInt8])
    func readFrame(timeout: TimeInterval) throws -> NaviFrame
    func close()
}

/// Where the extension streams. The bike is preferred when present; otherwise the dev emulator.
enum BroadcastConfig {
    static let dashProtocol = "com.garmin.navilite.data"
    /// Dev fallback: the NaviLite receiver's TCP dash. Used when no bike accessory is connected.
    /// Set this to your emulator host's IP when testing without a bike.
    static let emulatorHost = "127.0.0.1"
    static let emulatorPort: UInt16 = 7220
    /// Fallback frame-rate cap when no live setting is available (see [liveMaxFps]).
    static let maxFps: Int = 15

    /// App Group the container app would share its live Settings through (the extension is a
    /// separate process and can't see the app's own UserDefaults).
    ///
    /// No target requests the entitlement any more: a free Apple ID can't create App Groups, and an
    /// entitlement the provisioning profile doesn't grant gets the extension killed at launch — the
    /// broadcast never starts and the dash stays blank, with no red recording bar to hint why. Since
    /// sideloading with a free Apple ID *is* this project's distribution path (docs/IOS-SIDELOAD.md),
    /// the group could never have worked there. Kept as a lookup so a properly-provisioned build
    /// still picks the settings up; otherwise the readers below fall back to their defaults.
    static let appGroup = "group.app.pillion"
    private static var shared: UserDefaults? { UserDefaults(suiteName: appGroup) }

    // Each reader falls back to a safe default if the group is unavailable (e.g. a re-signer that
    // didn't carry the entitlement) — so the stream still works, just not slider-driven.
    static func liveMaxFps() -> Int {
        let v = shared?.integer(forKey: "stream.maxFps") ?? 0
        return (5...30).contains(v) ? v : maxFps
    }
    /// App stores JPEG quality as 10…80; map to CoreImage's 0…1.
    static func liveJpegQuality() -> Double {
        let v = shared?.integer(forKey: "stream.quality") ?? 0
        return (10...80).contains(v) ? Double(v) / 100.0 : 0.4
    }
}
