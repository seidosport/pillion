import Foundation
import CoreGraphics

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

/// Live layout control, app → extension.
///
/// Two independent decisions live here, and only a rider looking at the dash can settle either.
///
/// 1. *What to leave clear at the panel's edges.* The dash paints translucent chrome of its own
///    over whatever image it is handed — a navigation banner along the bottom (top edge measured
///    near y≈170 of 234 on a LinkCard/IXWW22) and zoom arrows down the left. Tried on the bike:
///    none of the optional setup messages turn the banner off, so it is the dash's own furniture
///    and the image simply has to stop short of it (see DashBanner for what to do with it instead).
/// 2. *What to give up from the phone's screen.* Fitting a whole phone screen into what is left of
///    a 480×234 panel puts everything on the dash too small to read at a glance — measured on the
///    bike, and the reason this second knob exists. Trimming the screen's own furniture first
///    (status bar and app chrome at the top, buttons down the sides) leaves a smaller region to
///    scale up, so what survives lands bigger.
///
/// The extension can't read the app's settings: an App Group needs an entitlement a free Apple ID
/// can't grant, and asking for one gets the extension killed at launch. Darwin notifications carry
/// no payload but need no entitlement, so — mirroring the diagnostic beacon going the other way —
/// the value travels in the *name*: one name per offered value. The rider steps through them with
/// the broadcast live and stops at the one that looks right. No rebuild, no reinstall, and a
/// sideload costs two of a free Apple ID's ten weekly App IDs.
enum DashInset {
    /// Rows to keep clear at the bottom, under the dash's navigation banner.
    static let bottomChoices = [0, 50, 60, 64, 70, 80]
    /// Columns to keep clear on the left, under the dash's zoom arrows.
    static let leftChoices = [0, 20, 30, 40, 60]

    /// Measured on a 2024 XMAX 300 (LinkCard, part 006-B3952-10): the banner's top edge reads
    /// between the 160 and 180 rules, so 64 rows clears it with a little margin.
    static let defaultBottom = 64
    static let defaultLeft = 0

    static func bottomName(_ v: Int) -> String { "app.pillion.cfg.inset.bottom.\(v)" }
    static func leftName(_ v: Int) -> String { "app.pillion.cfg.inset.left.\(v)" }
}

/// Which edge of the *phone's* screen a trim comes off. Percentages, not pixels: the same setting
/// then means the same thing whatever the phone, and whichever way round it is being held.
enum DashCropSide: String, CaseIterable {
    case top, bottom, left, right

    var label: String {
        switch self {
        case .top:    return "Quitar arriba"
        case .bottom: return "Quitar abajo"
        case .left:   return "Quitar izquierda"
        case .right:  return "Quitar derecha"
        }
    }

    /// Defaults chosen on the bike: the top of a phone screen is status bar and app chrome and the
    /// sides are buttons, none of which a rider reads at a glance — but the *bottom* holds the
    /// next-turn strip in every navigation app, so nothing is taken from there.
    var defaultPercent: Int {
        switch self {
        case .top:    return 15
        case .bottom: return 0
        case .left:   return 15
        case .right:  return 15
        }
    }
}

enum DashCrop {
    static let choices = [0, 5, 10, 15, 20, 25, 30, 40]
    static func name(_ side: DashCropSide, _ v: Int) -> String {
        "app.pillion.cfg.crop.\(side.rawValue).\(v)"
    }
}

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
    /// Posted by the extension once its observers exist, asking the app to send everything again.
    /// Darwin notifications aren't queued, so anything the rider changed while no broadcast was
    /// running would otherwise be invisible to the mirror that starts afterwards — the extension
    /// would silently come up on defaults.
    static let request = "app.pillion.cfg.request"
}

/// How the phone's screen is mapped onto the dash's safe area.
///
/// The panel is roughly 2:1 and a phone held upright is roughly 1:2, so fitting the whole screen
/// into it leaves a sliver of image between two black slabs — legible on a desk, useless at a
/// glance on a moving bike. iOS gives no app a way to force another app into landscape (only the
/// rider can, by turning the phone with rotation lock off), so the other half of the answer has to
/// live here: crop to a band of the screen at full size instead of shrinking all of it.
enum DashFill: String, CaseIterable {
    case fit  = "app.pillion.cfg.fill.fit"
    case crop = "app.pillion.cfg.fill.crop"

    /// Crop, because fitting is what made the mirror unreadable on the bike: no phone screen is
    /// anything like 2.8:1, so fitting one whole always leaves a sliver between black slabs. Losing
    /// part of the image is the price of the rest of it being big enough to read at a glance.
    static let fallback = DashFill.crop

    var label: String {
        switch self {
        case .fit:  return "Encoger (cabe todo, se ve pequeño)"
        case .crop: return "Recortar (llena el tablero)"
        }
    }
}

/// Everything the encoder needs about geometry, read in one go so a frame can't be built from half
/// of an old setting and half of a new one.
struct DashLayout {
    var bottom: Int
    var left: Int
    var crop: [DashCropSide: Int]
    var fill: DashFill

    func percent(_ side: DashCropSide) -> CGFloat { CGFloat(crop[side] ?? 0) / 100 }
}

/// The extension's live view of the layout. Written from the notification callback, read once per
/// encoded frame on the sender thread.
final class DashInsetState {
    static let shared = DashInsetState()

    private let lock = NSLock()
    private var _bottom = DashInset.defaultBottom
    private var _left = DashInset.defaultLeft
    private var _fill = DashFill.fallback
    private var _crop = Dictionary(uniqueKeysWithValues: DashCropSide.allCases.map { ($0, $0.defaultPercent) })
    private var _banner = ""
    /// Bumped on every completed banner; the sender thread watches it to know when to re-send the
    /// road-name frame, so the text reaches the dash without a second writer touching the link.
    private var _bannerSeq = 0
    private var _rx: [UInt8] = []
    private var _receiving = false

    var layout: DashLayout {
        lock.lock(); defer { lock.unlock() }
        return DashLayout(bottom: _bottom, left: _left, crop: _crop, fill: _fill)
    }
    var banner: String { lock.lock(); defer { lock.unlock() }; return _banner }
    var bannerSeq: Int { lock.lock(); defer { lock.unlock() }; return _bannerSeq }

    func observe() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let me = Unmanaged.passUnretained(self).toOpaque()
        let callback: CFNotificationCallback = { _, observer, name, _, _ in
            guard let observer = observer, let name = name else { return }
            let state = Unmanaged<DashInsetState>.fromOpaque(observer).takeUnretainedValue()
            state.apply(name.rawValue as String)
        }
        func watch(_ name: String) {
            CFNotificationCenterAddObserver(center, me, callback, name as CFString, nil, .deliverImmediately)
        }
        for v in DashInset.bottomChoices { watch(DashInset.bottomName(v)) }
        for v in DashInset.leftChoices { watch(DashInset.leftName(v)) }
        for f in DashFill.allCases { watch(f.rawValue) }
        for side in DashCropSide.allCases {
            for v in DashCrop.choices { watch(DashCrop.name(side, v)) }
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
        for v in DashInset.bottomChoices where name == DashInset.bottomName(v) { _bottom = v; return }
        for v in DashInset.leftChoices where name == DashInset.leftName(v) { _left = v; return }
        if let f = DashFill(rawValue: name) { _fill = f; return }
        for side in DashCropSide.allCases {
            for v in DashCrop.choices where name == DashCrop.name(side, v) { _crop[side] = v; return }
        }
        applyBanner(name)
    }

    /// Caller holds the lock.
    private func applyBanner(_ name: String) {
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
