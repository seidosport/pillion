import Foundation

/// A one-way trace from the broadcast extension to the app.
///
/// The extension is a separate process, and every obvious channel is closed to a sideloaded build:
/// an App Group needs an entitlement a free Apple ID can't grant (asking for it got the extension
/// SIGKILLed — see Transport.swift), and reading its os_log needs a Mac, which is exactly what the
/// people sideloading this don't have. Darwin notifications need no entitlement, but carry no
/// payload — so the state travels in the *name*: one name per checkpoint.
///
/// Notifications are also not queued: an app that isn't running when one is posted never learns it
/// happened. That's the normal case here, since starting a broadcast takes the user through the
/// system picker. So the extension doesn't announce transitions — it re-posts its *current* phase
/// on a beat, and whoever is listening learns the state within one beat of looking.
enum DiagPhase: String, CaseIterable {
    case launched         = "app.pillion.diag.launched"
    case noAccessories    = "app.pillion.diag.acc.none"
    case accessoryNoProto = "app.pillion.diag.acc.noproto"
    case usingBike        = "app.pillion.diag.transport.bike"
    case usingEmulator    = "app.pillion.diag.transport.tcp"
    case connectFailed    = "app.pillion.diag.connect.fail"
    case waitingEsn       = "app.pillion.diag.hs.esn"
    case waitingSecData   = "app.pillion.diag.hs.secdata"
    case handshakeFailed  = "app.pillion.diag.hs.fail"
    case streamingNoAck   = "app.pillion.diag.stream.noack"
    case streamingAcked   = "app.pillion.diag.stream.ack"

    /// Shown verbatim in the app's diagnostics screen.
    var label: String {
        switch self {
        case .launched:         return "El capturador arrancó."
        case .noAccessories:    return "No ve ningún accesorio MFi. (La app sí lo ve — el capturador no.)"
        case .accessoryNoProto: return "Ve un accesorio, pero sin el canal de navegación."
        case .usingBike:        return "Encontró la moto. Conectando…"
        case .usingEmulator:    return "No encontró la moto — está transmitiendo al emulador (al vacío)."
        // Reached from either transport, so it must not name one: without a bike the extension
        // falls back to the TCP emulator, whose absence fails here too. The preceding phase in the
        // history already says which link was being opened.
        case .connectFailed:    return "No pudo abrir la conexión. (Mira el paso anterior para saber con qué.)"
        case .waitingEsn:       return "Conectado. Esperando el saludo del tablero…"
        case .waitingSecData:   return "El tablero saludó. Autenticando…"
        case .handshakeFailed:  return "La autenticación no se completó."
        case .streamingNoAck:   return "Enviando imágenes, pero el tablero no responde."
        case .streamingAcked:   return "El tablero está recibiendo las imágenes."
        }
    }
}

/// The panel size actually being sent, reported alongside the phase.
enum DiagPanel: String, CaseIterable {
    case h234 = "app.pillion.diag.panel.234"
    case h236 = "app.pillion.diag.panel.236"
    case h240 = "app.pillion.diag.panel.240"

    var label: String {
        switch self {
        case .h234: return "480 × 234"
        case .h236: return "480 × 236"
        case .h240: return "480 × 240"
        }
    }

    static func forHeight(_ h: Int) -> DiagPanel? {
        switch h {
        case 234: return .h234
        case 236: return .h236
        case 240: return .h240
        default:  return nil
        }
    }
}

func postDarwinNotification(_ name: String) {
    CFNotificationCenterPostNotification(
        CFNotificationCenterGetDarwinNotifyCenter(),
        CFNotificationName(name as CFString), nil, nil, true)
}

/// Re-posts the extension's current phase every couple of seconds so a listener that starts late
/// still sees it. Cheap enough for a process with a ~50 MB ceiling: one timer, two notifications.
final class DiagBeacon {
    static let shared = DiagBeacon()

    private let queue = DispatchQueue(label: "app.pillion.diag")
    private var timer: DispatchSourceTimer?
    private var phase: DiagPhase = .launched
    private var panel: DiagPanel?

    func start() {
        queue.async {
            guard self.timer == nil else { return }
            let t = DispatchSource.makeTimerSource(queue: self.queue)
            t.schedule(deadline: .now(), repeating: 2.0, leeway: .milliseconds(200))
            t.setEventHandler { [weak self] in self?.emit() }
            t.resume()
            self.timer = t
        }
    }

    func stop() {
        queue.async {
            self.timer?.cancel()
            self.timer = nil
        }
    }

    func set(_ phase: DiagPhase) {
        queue.async {
            self.phase = phase
            self.emit()
        }
    }

    func setPanel(height: Int) {
        queue.async {
            self.panel = DiagPanel.forHeight(height)
            self.emit()
        }
    }

    private func emit() {
        postDarwinNotification(phase.rawValue)
        if let panel = self.panel { postDarwinNotification(panel.rawValue) }
    }
}

/// Live control, app -> extension.
///
/// The extension can't read the app's settings: an App Group needs an entitlement a free Apple ID
/// can't grant, and asking for one gets the extension killed at launch. Darwin notifications carry
/// no payload but need no entitlement, so - mirroring the diagnostic beacon going the other way -
/// what the rider chooses travels in the notification *name*. It reaches the mirror while it is
/// running, which matters when a reinstall costs two of a free Apple ID's ten weekly App IDs.
///
/// Geometry used to be steered from here too - trimming the phone's edges, holding the image clear
/// of the dash's chrome. Tried on the bike, both made the image worse than sending it whole, and
/// the code is gone. What survives is the one thing that did work: the banner text.

/// A short line of the rider's own text, for the dash's bottom banner.
///
/// The banner is the dash's own and can't be switched off, so the useful move is to fill it rather
/// than fight it. It is the road-name field (`CUR_ROAD_NAME_UPDATE`: raw UTF-8, no length prefix,
/// 64 bytes max), which the stock setup burst sends *empty* — and an empty road name is exactly
/// what leaves the dash showing its own default label, "Carretera".
///
/// Text can't travel the way the other settings do: the name channel needs one name per possible
/// value, and there is no enumerating every sentence someone might type. So the text is *spelled*
/// down the channel — one notification per nibble of its UTF-8, between a begin and an end marker —
/// which covers any message with 34 names. Nibbles alternate between two namespaces by position so
/// the same name is never posted twice in a row: two identical consecutive posts are the one case
/// Darwin notifications are allowed to coalesce into one, and that would silently drop a character.
enum DashBanner {
    /// Comfortably under the wire's 64 so multi-byte characters can't overrun it, and short enough
    /// that spelling it out is a handful of notifications.
    static let maxBytes = 40
    static let begin = "app.pillion.cfg.banner.begin"
    static let end   = "app.pillion.cfg.banner.end"

    static func nibbleName(_ v: UInt8, at index: Int) -> String {
        "app.pillion.cfg.banner.\(index % 2 == 0 ? "a" : "b").\(v)"
    }

    /// Truncated on a character boundary — half a multi-byte character decodes to junk.
    static func bytes(of text: String) -> [UInt8] {
        var out: [UInt8] = []
        for ch in text {
            let b = Array(String(ch).utf8)
            if out.count + b.count > maxBytes { break }
            out.append(contentsOf: b)
        }
        return out
    }

    static func post(_ text: String) {
        postDarwinNotification(begin)
        var i = 0
        for byte in bytes(of: text) {
            postDarwinNotification(nibbleName(byte >> 4, at: i)); i += 1
            postDarwinNotification(nibbleName(byte & 0x0f, at: i)); i += 1
        }
        postDarwinNotification(end)
    }
}

enum DashConfig {
    /// Posted by the extension once its observers exist, asking the app to send the banner again.
    /// Darwin notifications aren't queued, so text typed while no broadcast was running would
    /// otherwise be invisible to the mirror that starts afterwards.
    static let request = "app.pillion.cfg.request"
}

/// The extension's live view of the rider's banner text. Written from the notification callback,
/// read on the sender thread.
final class DashBannerState {
    static let shared = DashBannerState()

    private let lock = NSLock()
    private var _banner = ""
    /// Bumped on every completed banner; the sender thread watches it to know when to re-send the
    /// road-name frame, so the text reaches the dash without a second writer touching the link.
    private var _bannerSeq = 0
    private var _rx: [UInt8] = []
    private var _receiving = false

    var banner: String { lock.lock(); defer { lock.unlock() }; return _banner }
    var bannerSeq: Int { lock.lock(); defer { lock.unlock() }; return _bannerSeq }

    func observe() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let me = Unmanaged.passUnretained(self).toOpaque()
        let callback: CFNotificationCallback = { _, observer, name, _, _ in
            guard let observer = observer, let name = name else { return }
            let state = Unmanaged<DashBannerState>.fromOpaque(observer).takeUnretainedValue()
            state.apply(name.rawValue as String)
        }
        func watch(_ name: String) {
            CFNotificationCenterAddObserver(center, me, callback, name as CFString, nil, .deliverImmediately)
        }
        watch(DashBanner.begin)
        watch(DashBanner.end)
        for n in UInt8(0)...UInt8(15) {
            watch(DashBanner.nibbleName(n, at: 0))
            watch(DashBanner.nibbleName(n, at: 1))
        }
    }

    private func apply(_ name: String) {
        lock.lock(); defer { lock.unlock() }
        if name == DashBanner.begin { _rx = []; _receiving = true; return }
        if name == DashBanner.end {
            guard _receiving else { return }
            _receiving = false
            var bytes: [UInt8] = []
            var i = 0
            // A dropped notification leaves an odd nibble; pairing stops before it rather than
            // shifting every following character by half a byte.
            while i + 1 < _rx.count { bytes.append(_rx[i] << 4 | _rx[i + 1]); i += 2 }
            _rx = []
            _banner = String(decoding: bytes, as: UTF8.self)
            _bannerSeq &+= 1
            return
        }
        guard _receiving, name.hasPrefix("app.pillion.cfg.banner."),
              let tail = name.split(separator: ".").last, let v = UInt8(tail), v < 16 else { return }
        _rx.append(v)
    }
}
