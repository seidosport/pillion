import Foundation

/// The dash's image-panel geometry.
///
/// Width is always 480, but the height depends on the CCU generation — see "Vehicle Model Detection"
/// in docs/PROTOCOL.md. StreetCross derives the model from the software part number the CCU sends
/// with `AUTH_REQUEST_SEC_DATA` (service 83) and lays the map out accordingly:
///
///   * `MODEL_IXWW22` (`006-B3952`)              → base LinkCard layout, 480 × 234
///   * `MODEL_IMWW23` (`006-B4160` / `006-B4920`) → `layout_imww23_map`, 480 × 240
///
/// The image channel has also been observed carrying 480 × 236. Sending the wrong height risks the
/// dash never decoding a frame — and since the sender waits for `IMAGE_ACK` before the next frame,
/// that stalls the stream at zero fps rather than failing loudly. Hence: trust the part number when
/// it names a known model, otherwise probe the candidates until one ACKs.
enum DashPanel {
    static let width = 480

    /// Heights to try when the part number doesn't identify the model, most likely first.
    /// 240 leads because it's the only height confirmed on real hardware (MT-07 2025 / MY23 CCU).
    static let candidateHeights = [240, 234, 236]

    static var defaultHeight: Int { candidateHeights[0] }

    /// The height implied by the CCU's software part number, or nil if it names no known model.
    static func height(forPartNumber partNumber: String) -> Int? {
        if partNumber.contains("006-B4160") || partNumber.contains("006-B4920") { return 240 }
        if partNumber.contains("006-B3952") { return 234 }
        return nil
    }

    /// The next height to probe after `height` failed to draw an ACK.
    static func nextCandidate(after height: Int) -> Int {
        guard let i = candidateHeights.firstIndex(of: height) else { return defaultHeight }
        return candidateHeights[(i + 1) % candidateHeights.count]
    }
}
