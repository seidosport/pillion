import Foundation
import ReplayKit
import CoreImage
import CoreMedia
import ImageIO
import ExternalAccessory
import Metal
import os.log

/// Extension logging that survives `log collect`: NSLog content is privacy-redacted (<private>) in
/// collected archives, so use os_log with %{public} to keep the FPS/ack stats readable.
private let extOSLog = OSLog(subsystem: "app.pillion.ext", category: "stream")
func extLog(_ s: String) { os_log("%{public}@", log: extOSLog, type: .default, s) }

/// Darwin notification names the app observes to reflect broadcast state (no App Group needed).
enum BroadcastSignal {
    static let started = "app.pillion.broadcast.started"
    static let stopped = "app.pillion.broadcast.stopped"
    static func post(_ name: String) {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(name as CFString), nil, nil, true)
    }
}

/// Broadcast Upload Extension: captures the whole screen system-wide and streams it to the dash as
/// NaviLite. Because it runs as a broadcast it keeps going while the phone is in Waze/Maps. Ported
/// from rickdash-ios; picks the bike (External Accessory) when present, else the dev emulator (TCP).
class SampleHandler: RPBroadcastSampleHandler {
    private var conn: DashConn!
    // Force an explicit Metal-backed context so the downscale runs on the GPU. The capture thread only
    // stashes the freshest pixel buffer; JPEG encode happens on the sender thread at send time so we
    // encode exactly the ~maxFps frames we ship (not every captured frame) and each one is the freshest.
    private let ci: CIContext = {
        if let dev = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: dev, options: [.cacheIntermediates: false])
        }
        return CIContext(options: [.cacheIntermediates: false])
    }()
    private let lock = NSLock()
    private var latestPixels: CVPixelBuffer?          // freshest captured frame; retained until next capture
    private var latestOrient = CGImagePropertyOrientation.up
    private var running = false
    private var seq = 1
    // Live settings, read from the App Group at broadcastStarted (default until then).
    private var sendInterval = 1.0 / Double(BroadcastConfig.maxFps)
    private var jpegQuality = 0.4
    // Panel height on the wire (width is always 480). Set from the CCU's part number at handshake;
    // when that names no known model we probe the candidates until one ACKs. Both are written and
    // read on the sender thread only (handshake and pushLoop run on the same detached thread).
    private var panelH = DashPanel.defaultHeight
    private var panelKnown = false

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        running = true
        // Pull the user's live Settings (fps / quality) from the App Group.
        sendInterval = 1.0 / Double(BroadcastConfig.liveMaxFps())
        jpegQuality = BroadcastConfig.liveJpegQuality()
        extLog("PillionExt: settings — fps=\(BroadcastConfig.liveMaxFps()) quality=\(jpegQuality)")
        BroadcastSignal.post(BroadcastSignal.started)
        DiagBeacon.shared.start()
        // Enumerate EVERY connected MFi accessory up front so a bike test is diagnosable even when the
        // protocol string doesn't match (otherwise we silently fall back to TCP and learn nothing about
        // what the CCU actually advertises). iOS only exposes MFi accessories here — if the bike isn't
        // listed at all, it isn't pairing as an External Accessory and the EA path can't work.
        let accs = EAAccessoryManager.shared().connectedAccessories
        extLog("PillionExt: \(accs.count) connected accessory(ies)")
        for a in accs { extLog("PillionExt:  • \(a.name) — protocols=\(a.protocolStrings)") }
        let hasBike = accs.contains { $0.protocolStrings.contains(BroadcastConfig.dashProtocol) }
        // Report the enumeration itself, not just its conclusion. The app can see the CCU from its
        // own process; whether this one can is a separate question, and the answer decides whether
        // the problem is the bike link or the extension's sandbox.
        DiagBeacon.shared.set(accs.isEmpty ? .noAccessories : (hasBike ? .usingBike : .accessoryNoProto))
        let c: DashConn = hasBike ? EAConn()
                                  : TCPConn(host: BroadcastConfig.emulatorHost, port: BroadcastConfig.emulatorPort)
        c.logger = { s in extLog("PillionExt: \(s)") }
        conn = c
        extLog("PillionExt: transport = \(hasBike ? "bike (External Accessory)" : "emulator (TCP)")")
        if !hasBike { DiagBeacon.shared.set(.usingEmulator) }
        Thread.detachNewThread { [weak self] in
            guard let self = self else { return }
            do {
                try self.conn.connect()
            } catch {
                DiagBeacon.shared.set(.connectFailed)
                extLog("PillionExt connect err: \((error as NSError).localizedDescription)")
                return
            }
            do {
                try self.handshake()
            } catch {
                DiagBeacon.shared.set(.handshakeFailed)
                extLog("PillionExt handshake err: \((error as NSError).localizedDescription)")
                return
            }
            self.pushLoop()
        }
    }

    private func handshake() throws {
        DiagBeacon.shared.set(.waitingEsn)
        var f = try conn.readFrame(timeout: 12); while f.svc != 66 { f = try conn.readFrame(timeout: 12) }
        conn.write(NaviLite.frame(6, 81, 0, [1, 0]))
        conn.write(NaviLite.frame(6, 33, 1, NaviLite.hexB("1c07000100000000")))
        DiagBeacon.shared.set(.waitingSecData)
        f = try conn.readFrame(timeout: 12); while f.svc != 83 { f = try conn.readFrame(timeout: 12) }
        // SEC_DATA carries the CCU's software part number ahead of the nonce — the only identification
        // of the dash generation we get, and what decides the panel height (see DashPanel). Log it
        // verbatim either way: an unrecognised part number is exactly what a new bike report needs.
        let partNumber = NaviLite.partNumber(f.payload)
        if let h = DashPanel.height(forPartNumber: partNumber) {
            panelH = h; panelKnown = true
            extLog("PillionExt: CCU part=\(partNumber) → panel \(DashPanel.width)×\(h)")
        } else {
            panelH = DashPanel.defaultHeight; panelKnown = false
            extLog("PillionExt: CCU part=\(partNumber) unrecognised → probing \(DashPanel.candidateHeights)")
        }
        conn.write(NaviLite.frame(6, 84, 1, NaviLite.secDataAckPayload(f.payload)))
        let setup: [(UInt8, UInt8, [UInt8])] = [
            (2, 0, [0, 0]), (31, 0, [1, 0]), (10, 0, [0, 0]), (11, 0, [0, 0]), (13, 0, [1, 0]), (12, 0, [0, 0]),
            (14, 1, NaviLite.hexB("07190600302e32206d69")), (3, 1, []), (17, 1, NaviLite.hexB("00000000036d7068")),
            (13, 0, [1, 0]), (12, 0, [1, 0])]
        for (s, p, pl) in setup { conn.write(NaviLite.frame(6, s, p, pl)) }
        DiagBeacon.shared.setPanel(height: panelH)
        DiagBeacon.shared.set(.streamingNoAck)
        extLog("PillionExt: auth + setup done")
    }

    /// Reads frames until an IMAGE_ACK (svc 80) or timeout. True = ACK seen.
    private func awaitAck(_ timeout: TimeInterval) -> Bool {
        while running {
            guard let f = try? conn.readFrame(timeout: timeout) else { return false }
            if f.svc == 80 { return true }
        }
        return false
    }

    /// Sender: 2-in-flight window over the iAP2 link. Stop-and-wait left the link idle for the
    /// ~55ms fixed dash-decode + ACK-return leg of every frame; sending the next frame into that
    /// dead air buys ~40% more fps for at most one transmit-time (~80ms) of extra latency. The
    /// original pipeline's lag problem was *stale pre-encoded* frames — gone now that each frame
    /// is encoded from the freshest pixels at send time, overlapping the previous frame's ACK wait.
    /// ACKs carry no sequence number, so in-flight sends are matched FIFO; a timeout drains strays
    /// and resets the window so a late ACK can't be mis-attributed forever.
    private func pushLoop() {
        var lastSend = Date(timeIntervalSince1970: 0)
        var acks = 0; var t0 = Date(); var ackTotal = 0.0
        // Adaptive quality: a busy map at the user's quality (16-18 KB/frame) can cost 400-900ms
        // per frame on a choked link. Steer quality by measured ACK time, never above the setting.
        var q = jpegQuality
        // Second knob past the quality floor: soften the image (Lanczos down/up, still full panel size
        // on the wire) so busy-map frames drop to ~4-6KB — the only way to hold 10+fps on this link.
        var detail: CGFloat = 1.0
        var lastSentPB: CVPixelBuffer?
        var inFlight: [Date] = []   // send timestamps of un-ACKed frames (FIFO, ≤2)
        var everAcked = false       // has the dash ever decoded one of our frames? (panel probe)
        // Applies one measured ACK time to the two-stage controller: shed JPEG quality first; once
        // at the floor, shed detail (soft beats blocky on a map). Recover in reverse. Thresholds
        // are wider than stop-and-wait's because a windowed ACK includes overlap with the previous
        // frame's transmit.
        func steer(_ ackS: TimeInterval) {
            if ackS > 0.25 {
                if q > 0.12 { q = max(0.12, q - 0.05) } else { detail = 0.6 }
            } else if ackS < 0.14 {
                if detail < 1.0 { detail = 1.0 } else { q = min(jpegQuality, q + 0.02) }
            }
            acks += 1
            ackTotal += ackS
        }
        while running {
            let wait = sendInterval - Date().timeIntervalSince(lastSend)
            if wait > 0 { usleep(UInt32(wait * 1_000_000)) }
            lock.lock(); let pb = latestPixels; let o = latestOrient; lock.unlock()
            guard let pb = pb else { usleep(15000); continue }
            // Static screen: ReplayKit stops delivering buffers, so the same one lingers. Don't
            // re-encode/re-send it — an idle link ships the next real change with zero queueing.
            // Still refresh ~1/s so the dash image never goes stale.
            if pb === lastSentPB && Date().timeIntervalSince(lastSend) < 1.0 { usleep(15000); continue }
            // Encode now — while the previous frame's ACK is still in flight (encode overlaps I/O).
            guard let jpg = encode(pb, o, quality: q, detail: detail) else { continue }
            // Window gate: block only when 2 frames are already un-ACKed.
            while running && inFlight.count >= 2 {
                if awaitAck(1.0) {
                    if !everAcked { DiagBeacon.shared.set(.streamingAcked) }
                    everAcked = true
                    steer(Date().timeIntervalSince(inFlight.removeFirst()))
                } else {
                    // Timeout: dash silent or ACK lost. Drain any stragglers and reset the window
                    // so FIFO matching stays honest, and shed quality as congestion signal.
                    var drained = false
                    while awaitAck(0.05) { drained = true }
                    if drained {
                        if !everAcked { DiagBeacon.shared.set(.streamingAcked) }
                        everAcked = true
                    }
                    inFlight.removeAll()
                    steer(1.0)
                    // Not one ACK since the handshake? A dash that can't decode the frame at all
                    // stays silent in exactly this way — frames go out, nothing comes back, 0 fps —
                    // and a wrong panel height is the likeliest cause. Step to the next candidate.
                    // Skipped when the part number already named the model: then the geometry is
                    // settled and silence means something else (link, HMI state, another app).
                    if !everAcked && !panelKnown {
                        panelH = DashPanel.nextCandidate(after: panelH)
                        DiagBeacon.shared.setPanel(height: panelH)
                        extLog("PillionExt: no ACK yet — retrying at \(DashPanel.width)×\(panelH)")
                    }
                }
            }
            if !running { break }
            lastSend = Date()
            lastSentPB = pb
            var pl: [UInt8] = [3, UInt8(seq & 0xff), UInt8((seq >> 8) & 0xff)]; pl.append(contentsOf: jpg); seq += 1
            conn.write(NaviLite.frame(6, 0, 1, pl))
            inFlight.append(Date())
            let dt = Date().timeIntervalSince(t0)
            if dt >= 1 {
                extLog(String(format: "PillionExt: FPS %.1f  %dKB  ack %.0fms  q%.2f d%.1f",
                              Double(acks) / dt, jpg.count / 1024, ackTotal / Double(max(acks, 1)) * 1000, q, detail))
                acks = 0; ackTotal = 0; t0 = Date()
            }
        }
    }

    override func processSampleBuffer(_ sb: CMSampleBuffer, with type: RPSampleBufferType) {
        guard type == .video, running, let pb = CMSampleBufferGetImageBuffer(sb) else { return }
        // Just stash the freshest pixel buffer (cheap CFRetain — keeps its memory valid past this
        // callback); the sender thread encodes it at send time. No encode on the capture thread.
        var orient = CGImagePropertyOrientation.up
        if let n = CMGetAttachment(sb, key: RPVideoSampleOrientationKey as CFString, attachmentModeOut: nil) as? NSNumber,
           let o = CGImagePropertyOrientation(rawValue: n.uint32Value) { orient = o }
        let fix: CGImagePropertyOrientation
        switch orient {
        case .left: fix = .right
        case .right: fix = .left
        case .leftMirrored: fix = .rightMirrored
        case .rightMirrored: fix = .leftMirrored
        default: fix = orient   // up/down are self-inverse
        }
        lock.lock(); latestPixels = pb; latestOrient = fix; lock.unlock()
    }

    /// Downscale + letterbox to the dash panel (480 × [panelH]) and JPEG-encode. Runs on the sender
    /// thread once per sent frame. Broadcast extensions are killed past ~50 MB, so each encode gets
    /// its own pool. Baseline JPEG allows any dimensions — 234/236 pad internally to the MCU grid —
    /// so an odd panel height costs nothing here.
    private func encode(_ pb: CVPixelBuffer, _ orient: CGImagePropertyOrientation,
                        quality: Double, detail: CGFloat = 1.0) -> [UInt8]? {
        autoreleasepool {
            let W = CGFloat(DashPanel.width), H = CGFloat(panelH)
            let img = CIImage(cvPixelBuffer: pb).oriented(orient)
            let e = img.extent
            // Aspect-FIT (letterbox): whole screen centred on the panel with black bars.
            let scale = min(W / e.width, H / e.height)
            let s = img.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            let se = s.extent
            let tx = (W - se.width) / 2 - se.origin.x
            let ty = (H - se.height) / 2 - se.origin.y
            let centered = s.transformed(by: CGAffineTransform(translationX: tx, y: ty))
            let canvas = CGRect(x: 0, y: 0, width: W, height: H)
            var cropped = centered.composited(over: CIImage(color: .black).cropped(to: canvas)).cropped(to: canvas)
            if detail < 1.0 {
                // Soften via Lanczos down + up on the final panel: kills the high-frequency map
                // detail that dominates JPEG size (~detail² smaller frames). Wire size is unchanged.
                cropped = cropped
                    .applyingFilter("CILanczosScaleTransform",
                                    parameters: [kCIInputScaleKey: detail, kCIInputAspectRatioKey: 1.0])
                    .applyingFilter("CILanczosScaleTransform",
                                    parameters: [kCIInputScaleKey: 1.0 / detail, kCIInputAspectRatioKey: 1.0])
                    .cropped(to: canvas)
            }
            let opts: [CIImageRepresentationOption: Any] =
                [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): quality]
            guard let data = ci.jpegRepresentation(of: cropped, colorSpace: CGColorSpaceCreateDeviceRGB(), options: opts) else { return nil }
            return [UInt8](data)
        }
    }

    override func broadcastFinished() {
        running = false
        DiagBeacon.shared.stop()
        BroadcastSignal.post(BroadcastSignal.stopped)
        lock.lock(); latestPixels = nil; lock.unlock()   // release the last retained pixel buffer
        conn?.close()
    }
}
