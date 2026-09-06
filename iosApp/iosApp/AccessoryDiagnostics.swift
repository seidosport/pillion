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
    @ObservedObject var trace: BroadcastTrace
    @StateObject private var probe = DashProbe()
    @Environment(\.dismiss) private var dismiss
    @State private var accessories: [EAAccessory] = []
    @State private var copied = false
    @State private var setup = SetupChoice()
    /// Read-only here: it is edited in the shared Settings screen. The probe sends it so a test
    /// card and a live mirror put the same words on the dash.
    @AppStorage("dash.banner") private var banner = ""

    private static let navProtocol = "com.garmin.navilite.data"

    /// Spelled out once, as a stored string: the rider reads a colour off the dash and reports it,
    /// so the mapping from colour to position has to be on screen next to the button.
    private static let bandLegend =
        "Franjas de color, de fuera hacia dentro: " + DashProbe.bandNames.joined(separator: ", ")
        + ". Cada una mide " + String(Int(DashProbe.band)) + " px. Dime la primera que se lee entera."

    var body: some View {
        NavigationView {
            List {
                // First, because it answers the question the accessory list can't: this screen runs
                // in the app, and the app seeing the CCU says nothing about whether the extension —
                // a different process, with a different sandbox — sees it too.
                Section("Capturador de pantalla") {
                    if let phase = trace.phase {
                        Text(phase.label)
                            .font(.callout)
                            .foregroundStyle(trace.isLive ? .primary : .secondary)
                        if let panel = trace.panel {
                            row("Enviando a", panel.label)
                        }
                        row("Estado", trace.isLive ? "en marcha" : "sin señal (detenido)")
                        if trace.history.count > 1 {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Recorrido").font(.caption).foregroundStyle(.secondary)
                                ForEach(Array(trace.history.enumerated()), id: \.offset) { i, p in
                                    Text("\(i + 1). \(p.label)").font(.caption2)
                                }
                            }
                        }
                    } else {
                        Text("El capturador no ha dicho nada todavía.")
                            .font(.callout)
                        Text("Inicia la transmisión y quédate en Pillion. Si sigue en blanco pasados "
                             + "unos segundos, el capturador no está arrancando.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                // Which of the optional setup messages to send. Each is a suspect for a piece of the
                // dash's own chrome; only the bike can say which, so they are switches rather than a
                // guess baked into a build that costs App IDs to reinstall.
                Section("Mensajes del saludo") {
                    Text("Ya probado en la moto: ninguno quita la franja de abajo, la dibuja el "
                         + "tablero. Quedan aquí por si alguno sí quita las flechas de zoom de la "
                         + "izquierda. Si el tablero se queda en negro, ese mensaje hacía falta — "
                         + "vuelve a encenderlo.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Toggle("Zoom — flechas de la izquierda", isOn: $setup.zoom)
                    Toggle("Carretera — franja de abajo", isOn: $setup.road)
                    Toggle("Límite de velocidad", isOn: $setup.speedLimit)
                    Toggle("Interruptor final", isOn: $setup.appSettingPost)
                    Toggle("Estado de navegación", isOn: $setup.navStatus)
                    Toggle("Día / noche", isOn: $setup.dayNight)
                    Toggle("Casa y oficina", isOn: $setup.homeOffice)
                    Toggle("GPS", isOn: $setup.gps)
                }
                // Reaches the dash from this process, bypassing the extension entirely — it puts an
                // exact, known test card on the dash instead of whatever the phone is showing, which
                // is what makes the overlay measurable. Only one EASession exists per protocol, so
                // this and a live broadcast are mutually exclusive.
                Section("Prueba directa con la moto") {
                    Text("Para la transmisión antes: solo cabe una conexión a la vez.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Text(Self.bandLegend)
                        .font(.footnote).foregroundStyle(.secondary)
                    Button {
                        if probe.running {
                            probe.stop()
                        } else {
                            var s = setup
                            s.roadText = banner
                            setup = s
                            probe.start(s)
                        }
                    } label: {
                        HStack {
                            Text(probe.running ? "Detener prueba" : "Probar conexión con la moto")
                            Spacer()
                            if probe.running { ProgressView() }
                        }
                    }
                    .disabled(!hasNavProtocol && !probe.running)
                    if let h = probe.acceptedHeight {
                        Text("El tablero aceptó 480 × \(h)")
                            .font(.callout)
                            .foregroundStyle(.green)
                    }
                    if !probe.lines.isEmpty {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(Array(probe.lines.enumerated()), id: \.offset) { _, l in
                                Text(l).font(.system(.caption, design: .monospaced))
                            }
                        }
                    }
                }
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
        var s = ""
        if let phase = trace.phase {
            s += "CAPTURADOR: \(phase.label)\n"
            s += "  estado: \(trace.isLive ? "en marcha" : "sin señal")\n"
            if let panel = trace.panel { s += "  enviando a: \(panel.label)\n" }
            if trace.history.count > 1 {
                s += "  recorrido: " + trace.history.map { $0.label }.joined(separator: " → ") + "\n"
            }
        } else {
            s += "CAPTURADOR: sin señal — no dijo nada.\n"
        }
        s += "FRANJA: \(banner.isEmpty ? "(vacía — el tablero pone «Carretera»)" : banner)\n"
        s += "SALUDO: [\(setup.tags)]\n"
        if !probe.lines.isEmpty {
            s += "\nPRUEBA DIRECTA:\n" + probe.lines.map { "  \($0)" }.joined(separator: "\n") + "\n"
        }
        s += "\n\(verdict)\n"
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
