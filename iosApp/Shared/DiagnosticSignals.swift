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

/// Live safe-area control, app → extension.
///
/// The dash paints its own translucent chrome over whatever image it is given: a navigation banner
/// along the bottom (top edge measured near y≈170 of 234 on a LinkCard/IXWW22) and zoom arrows down
/// the left edge. Content under them is dimmed and cluttered rather than erased, so how much to
/// give up is a judgement call — one that can only be made by a rider looking at the dash.
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

/// The extension's live view of the safe area. Written from the notification callback, read once
/// per encoded frame on the sender thread.
final class DashInsetState {
    static let shared = DashInsetState()

    private let lock = NSLock()
    private var _bottom = DashInset.defaultBottom
    private var _left = DashInset.defaultLeft

    var bottom: Int { lock.lock(); defer { lock.unlock() }; return _bottom }
    var left: Int { lock.lock(); defer { lock.unlock() }; return _left }

    func observe() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let me = Unmanaged.passUnretained(self).toOpaque()
        let callback: CFNotificationCallback = { _, observer, name, _, _ in
            guard let observer = observer, let name = name else { return }
            let state = Unmanaged<DashInsetState>.fromOpaque(observer).takeUnretainedValue()
            state.apply(name.rawValue as String)
        }
        for v in DashInset.bottomChoices {
            CFNotificationCenterAddObserver(center, me, callback,
                                            DashInset.bottomName(v) as CFString, nil, .deliverImmediately)
        }
        for v in DashInset.leftChoices {
            CFNotificationCenterAddObserver(center, me, callback,
                                            DashInset.leftName(v) as CFString, nil, .deliverImmediately)
        }
    }

    private func apply(_ name: String) {
        lock.lock(); defer { lock.unlock() }
        for v in DashInset.bottomChoices where name == DashInset.bottomName(v) { _bottom = v; return }
        for v in DashInset.leftChoices where name == DashInset.leftName(v) { _left = v; return }
    }
}
