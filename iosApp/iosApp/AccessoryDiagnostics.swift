import SwiftUI
import ExternalAccessory

/// What the phone can actually see over MFi, shown on screen.
///
/// The broadcast extension already logs this enumeration every time it starts, but reading os_log
/// needs a Mac with Console.app — out of reach for exactly the person most likely to need it: a
/// sideloading user on Windows staring at a dash that stays blank. The app process filters
/// `connectedAccessories` by the same `UISupportedExternalAccessoryProtocols` the extension does, so
/// what this screen lists is what the extension will find too.
///
/// The distinction it exists to make: *no accessory at all* (the CCU isn't pairing as an External
/// Accessory to this build) vs *an accessory that doesn't offer* `com.garmin.navilite.data` (it's
/// there, but not handing us the navigation protocol). Those need opposite fixes, and guessing
/// between them costs a trip to the bike each time.
struct AccessoryDiagnostics: View {
    @Environment(\.dismiss) private var dismiss
    @State private var accessories: [EAAccessory] = []
    @State private var copied = false

    private static let navProtocol = "com.garmin.navilite.data"

    var body: some View {
        NavigationView {
            List {
                Section {
                    Text(verdict)
                        .font(.callout)
                        .foregroundStyle(hasNavProtocol ? .green : .orange)
                }
                if accessories.isEmpty {
                    Section {
                        Text("El iPhone no ve ningún accesorio MFi.")
                            .font(.callout)
                        Text("Con la moto encendida y emparejada, esto debería listar la "
                             + "«Communication Control Unit» de Yamaha. Si aparece vacío, la CCU no "
                             + "se está conectando a esta app como accesorio.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                ForEach(Array(accessories.enumerated()), id: \.offset) { _, a in
                    Section(a.name.isEmpty ? "(sin nombre)" : a.name) {
                        row("Fabricante", a.manufacturer)
                        row("Modelo", a.modelNumber)
                        row("Firmware", a.firmwareRevision)
                        row("Hardware", a.hardwareRevision)
                        row("Conectado", a.isConnected ? "sí" : "no")
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Protocolos").font(.caption).foregroundStyle(.secondary)
                            if a.protocolStrings.isEmpty {
                                Text("(ninguno)").font(.system(.caption, design: .monospaced))
                            }
                            ForEach(a.protocolStrings.sorted(), id: \.self) { p in
                                Text(p)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(p == Self.navProtocol ? .green : .primary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Diagnóstico MFi")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cerrar") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(copied ? "Copiado" : "Copiar") {
                        UIPasteboard.general.string = report
                        copied = true
                    }
                }
                ToolbarItem(placement: .bottomBar) {
                    Button("Actualizar", action: refresh)
                }
            }
        }
        .onAppear(perform: refresh)
    }

    @ViewBuilder private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text(value.isEmpty ? "—" : value).font(.system(.caption, design: .monospaced))
        }
    }

    private var hasNavProtocol: Bool {
        accessories.contains { $0.protocolStrings.contains(Self.navProtocol) }
    }

    private var verdict: String {
        if accessories.isEmpty { return "Ningún accesorio MFi conectado." }
        if hasNavProtocol { return "CCU encontrada y ofrece \(Self.navProtocol). La conexión debería funcionar." }
        return "Hay accesorio, pero ninguno ofrece \(Self.navProtocol)."
    }

    /// Plain-text version of the screen, for pasting into a bug report.
    private var report: String {
        var s = "\(verdict)\n"
        for a in accessories {
            s += "\n• \(a.name) — \(a.manufacturer) / \(a.modelNumber) / fw \(a.firmwareRevision)\n"
            s += "  protocolos: \(a.protocolStrings.sorted().joined(separator: ", "))\n"
        }
        return s
    }

    private func refresh() {
        // Only needed for connect/disconnect callbacks, but harmless and it makes the manager's
        // state current before we read it.
        EAAccessoryManager.shared().registerForLocalNotifications()
        accessories = EAAccessoryManager.shared().connectedAccessories
        copied = false
    }
}
