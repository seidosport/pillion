import SwiftUI
import UIKit
import ExternalAccessory

/// Talks to the dash from the *app* process instead of the broadcast extension.
///
/// Mirroring other apps is only possible from the extension — but the extension also has to be
/// code-signed correctly to launch at all, and a sideloaded build currently can't be (see the
/// CODESIGNING notes in build-ipa.sh). The app has no such problem: it installs, runs, and can see
/// the CCU. So the protocol questions — does this bike speak NaviLite to this phone, does the auth
/// pass, which panel size does the dash actually accept — get asked from here, and answered without
/// waiting on the signing ones. It puts a test card on the dash rather than the phone's screen.
final class DashProbe: ObservableObject {
    @Published private(set) var lines: [String] = []
    @Published private(set) var running = false
    @Published private(set) var succeeded: Bool?
    @Published private(set) var acceptedHeight: Int?

    private var conn: EAConn?
    private var cancelled = false

    /// Post-auth state burst the dash expects before it renders images (mirrors Handshake.kt).
    private static let setupBurst: [(UInt8, UInt8, [UInt8])] = [
        (2, 0, [0, 0]), (31, 0, [1, 0]), (10, 0, [0, 0]), (11, 0, [0, 0]), (13, 0, [1, 0]), (12, 0, [0, 0]),
        (14, 1, NaviLite.hexB("07190600302e32206d69")), (3, 1, []), (17, 1, NaviLite.hexB("00000000036d7068")),
        (13, 0, [1, 0]), (12, 0, [1, 0])]

    func start() {
        guard !running else { return }
        lines = []
        succeeded = nil
        acceptedHeight = nil
        running = true
        cancelled = false
        let t = Thread { [weak self] in self?.run() }
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

    private func run() {
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
            for (s, p, pl) in Self.setupBurst { c.write(NaviLite.frame(6, s, p, pl)) }
            log("✓ Configuración enviada")
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
            guard let jpeg = Self.testCard(height: h) else { continue }
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
                log("Manteniendo la imagen 30 s — mira el tablero.")
                let deadline = Date().addingTimeInterval(30)
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

    /// A test card at exactly the wire size: corner blocks so a mis-sized or cropped frame is
    /// obvious at a glance on the dash, and the size printed on it so a photo is self-documenting.
    private static func testCard(height: Int) -> [UInt8]? {
        let size = CGSize(width: CGFloat(DashPanel.width), height: CGFloat(height))
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1          // the renderer defaults to screen scale; the dash wants 1:1 pixels
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIColor.black.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            UIColor.systemGreen.setFill()
            let m: CGFloat = 18
            for p in [CGPoint(x: 0, y: 0),
                      CGPoint(x: size.width - m, y: 0),
                      CGPoint(x: 0, y: size.height - m),
                      CGPoint(x: size.width - m, y: size.height - m)] {
                ctx.fill(CGRect(x: p.x, y: p.y, width: m, height: m))
            }
            let title = "PILLION"
            let subtitle = "480 x \(height)"
            let titleAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.boldSystemFont(ofSize: 56), .foregroundColor: UIColor.white]
            let subAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.boldSystemFont(ofSize: 36), .foregroundColor: UIColor.systemYellow]
            let tw = (title as NSString).size(withAttributes: titleAttrs).width
            let sw = (subtitle as NSString).size(withAttributes: subAttrs).width
            (title as NSString).draw(at: CGPoint(x: (size.width - tw) / 2, y: size.height * 0.18),
                                     withAttributes: titleAttrs)
            (subtitle as NSString).draw(at: CGPoint(x: (size.width - sw) / 2, y: size.height * 0.58),
                                        withAttributes: subAttrs)
        }
        guard let data = image.jpegData(compressionQuality: 0.6) else { return nil }
        return [UInt8](data)
    }
}
