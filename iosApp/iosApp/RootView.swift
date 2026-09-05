import SwiftUI

/// The iOS app: the shared Pillion Compose UI, with "Start mirroring" wired to the system screen
/// broadcast (the upload extension does the capture + streaming). A hidden picker host sits off-screen
/// so the Compose button can trigger it.
struct RootView: View {
    @StateObject private var bridge = BroadcastBridge()
    @State private var showDiagnostics = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ComposeScreen { bridge.makeViewController() }
                .ignoresSafeArea()
            BroadcastPickerHost(bridge: bridge)
                .frame(width: 44, height: 44)
                .position(x: -200, y: -200)   // kept in the hierarchy but off-screen
                .allowsHitTesting(false)
            // Deliberately a plain overlay rather than a Compose screen: the accessory list has to
            // stay reachable even when the shared UI is mid-connection or wedged, since "nothing
            // happens when I press the dash's nav button" is precisely when it's needed.
            Button { showDiagnostics = true } label: {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 34, height: 34)
                    .background(Color.black.opacity(0.45))
                    .clipShape(Circle())
            }
            .padding(.top, 8)
            .padding(.trailing, 12)
            .accessibilityLabel("Diagnóstico MFi")
        }
        .sheet(isPresented: $showDiagnostics) { AccessoryDiagnostics() }
    }
}
