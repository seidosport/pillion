import SwiftUI
import UIKit
import ExternalAccessory

/// Which optional messages of the post-auth setup burst to send.
///
/// The dash draws its own chrome over the image — a translucent navigation banner along the bottom
/// (turn arrow + road name) and zoom arrows down the left edge — and it does so because this burst
/// tells it navigation is active. `ROAD` in particular is sent with an *empty* string, which is
/// what puts the dash's default road label ("Carretera" on a Spanish dash) on screen; `ZOOM` is the
/// likeliest source of the zoom arrows, since the dash answers them with zoom in/out requests.
/// Whether any of these can be dropped without also losing the image is unknown and can only be
/// settled against real hardware, so each is a switch the rider flips at the bike rather than a
/// guess baked into a build. A sideload costs two of a free Apple ID's ten weekly App IDs, which
/// makes "one build, many experiments" the only affordable shape for this.
struct SetupChoice: Equatable {
    var navStatus = true       // svc 2
    var dayNight = true        // svc 31
    var homeOffice = true      // svc 10 + 11
    var gps = true             // svc 13
    var zoom = true            // svc 14 — suspected source of the left-edge zoom arrows
    var road = true            // svc 3  — suspected source of the bottom "Carretera" banner
    var speedLimit = true      // svc 17
    var appSettingPost = true  // closing svc 12 = 01 00

    /// The burst in the order StreetCross sends it (mirrors Handshake.kt); omitted options are just
    /// dropped, leaving every other frame in its original position.
    var burst: [(UInt8, UInt8, [UInt8])] {
        var b: [(UInt8, UInt8, [UInt8])] = []
        if navStatus { b.append((2, 0, [0, 0])) }
        if dayNight { b.append((31, 0, [1, 0])) }
        if homeOffice { b.append((10, 0, [0, 0])); b.append((11, 0, [0, 0])) }
        if gps { b.append((13, 0, [1, 0])) }
        b.append((12, 0, [0, 0]))
        if zoom { b.append((14, 1, NaviLite.hexB("07190600302e32206d69"))) }
        if road { b.append((3, 1, [])) }
        if speedLimit { b.append((17, 1, NaviLite.hexB("00000000036d7068"))) }
        if gps { b.append((13, 0, [1, 0])) }
        if appSettingPost { b.append((12, 0, [1, 0])) }
        return b
    }

    /// Printed on the card so a photo of the dash says which combination produced it.
    var tags: String {
        var t: [String] = []
        if navStatus { t.append("N") }
        if dayNight { t.append("D") }
        if homeOffice { t.append("H") }
        if gps { t.append("G") }
        if zoom { t.append("Z") }
        if road { t.append("C") }
        if speedLimit { t.append("V") }
        if appSettingPost { t.append("A") }
        return t.isEmpty ? "-" : t.joined()
    }
}

/// Talks to the dash from the *app* process instead of the broadcast extension.
///
/// Originally the only way to reach the dash at all, while the extension couldn't be signed into
/// launching. That's fixed (iloader signs app extensions correctly) and mirroring works — but this
/// stays the measurement tool, because it puts an exact, known image on the dash instead of
/// whatever the phone happens to be showing. Only one EASession per protocol exists at a time, so
/// this and a live broadcast are mutually exclusive.
final class DashProbe: ObservableObject {
    @Published private(set) var lines: [String] = []
    @Published private(set) var running = false
    @Published private(set) var succeeded: Bool?
    @Published private(set) var acceptedHeight: Int?

    private var conn: EAConn?
    private var cancelled = false

    func start(_ choice: SetupChoice) {
        guard !running else { return }
        lines = []
        succeeded = nil
        acceptedHeight = nil
        running = true
        cancelled = false
        let t = Thread { [weak self] in self?.run(choice) }
        t.name = "dash-probe"
        t.start()
    }

    func stop() { cancelled = true }

    private func log(_ s: String) {
        DispatchQueue.main.async { self.lines.append(s) }
    }

    private func finish(_ ok: Bool, height: Int? = nil) {
        conn?.close()
        conn = nil
        DispatchQueue.main.async {
            self.running = false
            self.succeeded = ok
            self.acceptedHeight = height
        }
    }

    private func run(_ choice: SetupChoice) {
        let accs = EAAccessoryManager.shared().connectedAccessories
        log("Accesorios visibles: \(accs.count)")
        guard let acc = accs.first(where: { $0.protocolStrings.contains(BroadcastConfig.dashProtocol) }) else {
            log("✗ Ninguno ofrece el canal de navegación. ¿Moto encendida?")
            finish(false)
            return
        }
        log("✓ \(acc.name) — firmware \(acc.firmwareRevision)")

        let c = EAConn()
        c.logger = { [weak self] s in self?.log("· \(s)") }
        conn = c
        do {
            try c.connect()
            log("✓ Conexión abierta")
        } catch {
            log("✗ No se pudo abrir la conexión: \((error as NSError).localizedDescription)")
            finish(false)
            return
        }

        var partNumber = ""
        do {
            log("Esperando el saludo del tablero…")
            var f = try c.readFrame(timeout: 15)
            while f.svc != 66 { f = try c.readFrame(timeout: 15) }
            log("✓ El tablero saludó")
            c.write(NaviLite.frame(6, 81, 0, [1, 0]))
            c.write(NaviLite.frame(6, 33, 1, NaviLite.hexB("1c07000100000000")))
            log("Autenticando…")
            f = try c.readFrame(timeout: 15)
            while f.svc != 83 { f = try c.readFrame(timeout: 15) }
            partNumber = NaviLite.partNumber(f.payload)
            c.write(NaviLite.frame(6, 84, 1, NaviLite.secDataAckPayload(f.payload)))
            log("✓ Autenticado — pieza: \(partNumber)")
            for (s, p, pl) in choice.burst { c.write(NaviLite.frame(6, s, p, pl)) }
            log("✓ Configuración enviada [\(choice.tags)]")
        } catch {
            log("✗ El saludo no se completó: \((error as NSError).localizedDescription)")
            finish(false)
            return
        }

        // Try the size the part number implies first, then the rest. An ACK is the dash saying it
        // decoded the frame, which is the only honest confirmation of the geometry.
        var order = DashPanel.candidateHeights
        if let known = DashPanel.height(forPartNumber: partNumber) {
            log("La pieza indica 480×\(known)")
            order = [known] + order.filter { $0 != known }
        } else {
            log("Pieza no reconocida — se prueban todos los tamaños")
        }

        var seq = 1
        for h in order {
            if cancelled { break }
            log("Probando 480×\(h)…")
            guard let jpeg = Self.testCard(height: h, tags: choice.tags) else { continue }
            var acked = false
            for _ in 0..<6 {
                if cancelled { break }
                var payload: [UInt8] = [3, UInt8(seq & 0xff), UInt8((seq >> 8) & 0xff)]
                payload.append(contentsOf: jpeg)
                seq += 1
                c.write(NaviLite.frame(6, 0, 1, payload))
                if let f = try? c.readFrame(timeout: 3), f.svc == 80 { acked = true; break }
            }
            if acked {
                log("✓✓ EL TABLERO ACEPTÓ 480×\(h)")
                log("Imagen fija 3 min. Mira qué franjas de color tapa el tablero. Pulsa Detener para probar otra combinación.")
                let deadline = Date().addingTimeInterval(180)
                while !cancelled && Date() < deadline {
                    var payload: [UInt8] = [3, UInt8(seq & 0xff), UInt8((seq >> 8) & 0xff)]
                    payload.append(contentsOf: jpeg)
                    seq += 1
                    c.write(NaviLite.frame(6, 0, 1, payload))
                    _ = try? c.readFrame(timeout: 2)
                }
                log("Prueba terminada.")
                finish(true, height: h)
                return
            }
            log("✗ Sin respuesta a 480×\(h)")
        }
        log("El tablero no respondió a ningún tamaño.")
        finish(false)
    }

    /// The band colours, outermost first, and their Spanish names. Named in the UI because a rider
    /// squinting at a dash in daylight can report a colour far more reliably than a two-digit label.
    static let bandColors: [UIColor] = [.red, .orange, .yellow, .green, .cyan, .magenta]
    static let bandNames = ["rojo", "naranja", "amarillo", "verde", "cian", "magenta"]
    static let band: CGFloat = 10

    /// A test card built to measure the dash's own overlay, not the panel.
    ///
    /// The panel turned out not to be the problem: 480×234 arrives whole — every column label and
    /// both bottom corners were readable on the bike, through a *translucent* banner. What's lost
    /// is whatever the dash paints on top: a navigation banner along the bottom (top edge measured
    /// near y≈170) and zoom arrows down the left edge. So the card stops hunting for the edge of
    /// the image and tiles the two suspect margins with 10px colour bands instead: the outermost
    /// band still legible marks where the chrome ends.
    ///
    /// Numbers stay in the middle for confirmation, with the lowest labels drawn *above* their rule
    /// — the previous card printed the last one below and clipped it against the canvas, which read
    /// on the bike as the dash cropping a row it was in fact showing.
    private static func testCard(height: Int, tags: String) -> [UInt8]? {
        let w = CGFloat(DashPanel.width), h = CGFloat(height)
        let margin = band * CGFloat(bandColors.count)      // 60px of bands on each measured edge
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1          // the renderer defaults to screen scale; the dash wants 1:1 pixels
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: CGSize(width: w, height: h), format: format).image { ctx in
            UIColor.black.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))

            // Bottom bands, full width: red hugs the bottom edge, magenta sits 60px up. The lowest
            // band still legible is where the navigation banner's top edge falls.
            for (i, c) in bandColors.enumerated() {
                c.setFill()
                ctx.fill(CGRect(x: 0, y: h - band * CGFloat(i + 1), width: w, height: band))
            }
            // Left bands, from the top down to the bottom bands: red hugs the left edge.
            for (i, c) in bandColors.enumerated() {
                c.setFill()
                ctx.fill(CGRect(x: band * CGFloat(i), y: 0, width: band, height: h - margin))
            }

            let ruled = CGRect(x: margin, y: 0, width: w - margin, height: h - margin)
            let label: [NSAttributedString.Key: Any] = [
                .font: UIFont.boldSystemFont(ofSize: 14), .foregroundColor: UIColor.white]
            let xLabel: [NSAttributedString.Key: Any] = [
                .font: UIFont.boldSystemFont(ofSize: 12), .foregroundColor: UIColor.systemOrange]

            // Horizontal rules every 20px inside the ruled area, numbered on both sides. Labels sit
            // above the rule near the bottom so the canvas can never clip one.
            UIColor(white: 0.55, alpha: 1).setFill()
            var y: CGFloat = 20
            while y < ruled.maxY {
                ctx.fill(CGRect(x: ruled.minX, y: y, width: ruled.width, height: 1))
                let s = "\(Int(y))" as NSString
                let sz = s.size(withAttributes: label)
                let ty = (y + 2 + sz.height > ruled.maxY) ? y - sz.height - 1 : y + 2
                s.draw(at: CGPoint(x: ruled.minX + 3, y: ty), withAttributes: label)
                s.draw(at: CGPoint(x: w - 3 - sz.width, y: ty), withAttributes: label)
                y += 20
            }
            // Vertical rules every 60px, numbered along the very top.
            UIColor(white: 0.35, alpha: 1).setFill()
            var x: CGFloat = margin + 60
            while x < w {
                ctx.fill(CGRect(x: x, y: 0, width: 1, height: ruled.height))
                ("\(Int(x))" as NSString).draw(at: CGPoint(x: x + 3, y: 2), withAttributes: xLabel)
                x += 60
            }

            // Which switches were on, so a photo of the dash is self-documenting.
            let title = "PILLION \(Int(w))x\(height)  [\(tags)]" as NSString
            let titleAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.boldSystemFont(ofSize: 22), .foregroundColor: UIColor.white]
            let tsz = title.size(withAttributes: titleAttrs)
            title.draw(at: CGPoint(x: ruled.minX + (ruled.width - tsz.width) / 2,
                                   y: ruled.midY - tsz.height / 2), withAttributes: titleAttrs)
        }
        guard let data = image.jpegData(compressionQuality: 0.7) else { return nil }
        return [UInt8](data)
    }
}
