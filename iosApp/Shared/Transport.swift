import Foundation
import Security

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

    /// App Group shared with the container app so the extension can read the user's live Settings
    /// (the extension is a separate process and can't see the app's own UserDefaults).
    /// Read the *granted* group id from our own entitlement at runtime: SideStore (free Apple ID) may
    /// rewrite "group.app.pillion" to a team-scoped id, and both app + appex must agree on whatever it
    /// became. Falls back to the literal if the entitlement can't be read.
    static let appGroup: String = grantedAppGroup() ?? "group.app.pillion"
    // ponytail: SecTask* is macOS-public but iOS-SPI (not in the iOS SDK's importable headers), so dlsym
    // it from the linked Security.framework. Best-effort — nil → caller uses the literal group id.
    static func grantedAppGroup() -> String? {
        typealias CreateFn = @convention(c) (CFAllocator?) -> Unmanaged<AnyObject>?
        typealias CopyFn = @convention(c) (AnyObject, CFString, UnsafeMutableRawPointer?) -> Unmanaged<AnyObject>?
        let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)
        guard let cSym = dlsym(rtldDefault, "SecTaskCreateFromSelf"),
              let vSym = dlsym(rtldDefault, "SecTaskCopyValueForEntitlement"),
              let task = unsafeBitCast(cSym, to: CreateFn.self)(nil)?.takeRetainedValue(),
              let value = unsafeBitCast(vSym, to: CopyFn.self)(
                task, "com.apple.security.application-groups" as CFString, nil)?.takeRetainedValue()
        else { return nil }
        return (value as? [String])?.first
    }
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

    // MARK: - SDL screen-share mode (spike). Off by default so the NaviLite path is unchanged.

    /// When true, the extension drives an `SDLManager` video stream instead of the NaviLite DashConn.
    /// Written to the App Group when the user picks the Motorize/USB bike (NaviLite is the default).
    static func sdlMode() -> Bool { shared?.bool(forKey: "stream.sdl") ?? false }
    /// SDL transport: TCP (SDL Core / Manticore emulator) when true, else iAP2/USB (the real bike).
    static func sdlUseTCP() -> Bool { shared?.bool(forKey: "sdl.tcp") ?? false }
    static func sdlHost() -> String { shared?.string(forKey: "sdl.host") ?? "127.0.0.1" }
    static func sdlPort() -> UInt16 {
        let v = shared?.integer(forKey: "sdl.port") ?? 0
        return (1...65535).contains(v) ? UInt16(v) : 12345
    }
    /// A file in the shared App Group container (survives the ride, tester can AirDrop it out).
    static func appGroupFile(_ name: String) -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appendingPathComponent(name)
    }
}
