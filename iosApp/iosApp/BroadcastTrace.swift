import SwiftUI

/// Listens for the broadcast extension's phase beacon and keeps the latest state.
///
/// See `Shared/DiagnosticSignals.swift` for why the trace is shaped as bare notification names.
/// Created at app launch rather than when the diagnostics sheet opens: the interesting phases happen
/// in the seconds right after Start Broadcast, long before anyone thinks to go looking.
final class BroadcastTrace: ObservableObject {
    @Published private(set) var phase: DiagPhase?
    @Published private(set) var panel: DiagPanel?
    @Published private(set) var lastHeard: Date?
    @Published private(set) var history: [DiagPhase] = []

    init() { observe() }

    /// The beacon beats every 2s, so silence past a few beats means the extension is gone — which is
    /// itself a finding, and one that looks identical to "never started" without a timestamp.
    var isLive: Bool {
        guard let t = lastHeard else { return false }
        return Date().timeIntervalSince(t) < 7
    }

    fileprivate func record(_ name: String) {
        lastHeard = Date()
        if let p = DiagPhase(rawValue: name) {
            if phase != p {
                history.append(p)
                if history.count > 20 { history.removeFirst() }
            }
            phase = p
        } else if let p = DiagPanel(rawValue: name) {
            panel = p
        }
    }

    func reset() {
        phase = nil
        panel = nil
        lastHeard = nil
        history = []
    }

    private func observe() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let me = Unmanaged.passUnretained(self).toOpaque()
        let callback: CFNotificationCallback = { _, observer, name, _, _ in
            guard let observer = observer, let name = name else { return }
            let trace = Unmanaged<BroadcastTrace>.fromOpaque(observer).takeUnretainedValue()
            let raw = name.rawValue as String
            DispatchQueue.main.async { trace.record(raw) }
        }
        let names = DiagPhase.allCases.map { $0.rawValue } + DiagPanel.allCases.map { $0.rawValue }
        for n in names {
            CFNotificationCenterAddObserver(center, me, callback, n as CFString, nil, .deliverImmediately)
        }
    }
}
