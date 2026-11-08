import SwiftUI

struct DeviceDetailView: View {
    let device: MicroDevice
    @State private var model: MicroViewModel
    @State private var limitPercent: Double = 100
    @State private var limitEdited = false
    @State private var confirmPower: Bool?
    @State private var confirmLimit = false

    init(device: MicroDevice) {
        self.device = device
        _model = State(initialValue: MicroViewModel(device: device))
    }

    var body: some View {
        List {
            if let error = model.errorMessage {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.callout)
                }
            }

            if let s = model.snapshot {
                summary(s)
                pvSection(s)
                controlSection(s)
                gridSection(s)
                if !s.activeFaults.isEmpty || !s.activeAlarms.isEmpty {
                    problemsSection(s)
                }
                infoSection(s)
            } else if model.isLoading {
                Section {
                    HStack { Spacer(); ProgressView("Conectando con el logger…"); Spacer() }
                        .padding(.vertical, 30)
                }
            }
        }
        .navigationTitle(device.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if model.isLoading || model.isWriting {
                    ProgressView()
                } else {
                    Button { Task { await model.refresh() } } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel("Actualizar")
                }
            }
        }
        .refreshable { await model.refresh() }
        .task { await model.poll() }
        .onChange(of: device) { _, new in model.update(device: new) }
        .onChange(of: model.snapshot?.powerLimitRaw) { _, _ in
            if !limitEdited, let s = model.snapshot {
                limitPercent = min(100, s.powerLimitPercent(device.limitScale))
            }
        }
        .alert(confirmPower == true ? "¿Encender el micro?" : "¿Apagar el micro?",
               isPresented: Binding(get: { confirmPower != nil }, set: { if !$0 { confirmPower = nil } })) {
            Button("Cancelar", role: .cancel) {}
            Button(confirmPower == true ? "Encender" : "Apagar", role: confirmPower == true ? nil : .destructive) {
                let on = confirmPower == true
                Task { await model.setPower(on: on) }
            }
        } message: {
            Text(confirmPower == true ? "El micro volverá a inyectar a red." : "El micro dejará de producir hasta que lo vuelvas a encender.")
        }
        .alert("¿Aplicar límite del \(Int(limitPercent)) %?", isPresented: $confirmLimit) {
            Button("Cancelar", role: .cancel) {}
            Button("Aplicar") {
                limitEdited = false
                Task { await model.setPowerLimit(percent: limitPercent) }
            }
        } message: {
            Text("Equivale a unos \(Int((model.snapshot?.ratedPower ?? 0) * limitPercent / 100)) W máximo.")
        }
        .overlay(alignment: .bottom) {
            if let info = model.infoMessage {
                Text(info)
                    .font(.callout.weight(.semibold))
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.thinMaterial, in: Capsule())
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .task(id: info) {
                        try? await Task.sleep(nanoseconds: 2_500_000_000)
                        withAnimation { model.infoMessage = nil }
                    }
            }
        }
        .animation(.default, value: model.infoMessage)
    }

    // MARK: - Secciones

    private func summary(_ s: MicroSnapshot) -> some View {
        Section {
            VStack(spacing: 14) {
                HStack {
                    StateBadge(state: s.state, isOn: s.isOn)
                    Spacer()
                    Text(s.timestamp, style: .time)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                VStack(spacing: 2) {
                    Text(Fmt.power(s.acPower))
                        .font(.system(size: 48, weight: .bold, design: .rounded))
                        .contentTransition(.numericText())
                    Text("potencia AC").font(.caption).foregroundStyle(.secondary)
                }
                if s.ratedPower > 0 {
                    ProgressView(value: min(s.acPower, s.ratedPower), total: s.ratedPower)
                        .tint(.orange)
                }
                HStack {
                    Metric(title: "Hoy", value: Fmt.energy(s.todayEnergy))
                    Divider().frame(height: 30)
                    Metric(title: "Total", value: Fmt.energy(s.totalEnergy))
                    Divider().frame(height: 30)
                    Metric(title: "DC", value: Fmt.power(s.dcPower))
                }
            }
            .padding(.vertical, 6)
        }
    }

    private func pvSection(_ s: MicroSnapshot) -> some View {
        Section("Paneles") {
            ForEach(s.pv) { ch in
                HStack {
                    Text("PV\(ch.id)")
                        .font(.headline.monospacedDigit())
                        .frame(width: 44, alignment: .leading)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(Fmt.num(ch.voltage, 1)) V · \(Fmt.num(ch.current, 1)) A")
                            .font(.subheadline.monospacedDigit())
                        Text("Hoy \(Fmt.energy(ch.todayEnergy)) · Total \(Fmt.energy(ch.totalEnergy))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(Fmt.power(ch.power))
                        .font(.headline.monospacedDigit())
                        .foregroundStyle(ch.power > 1 ? .primary : .secondary)
                }
            }
        }
    }

    private func controlSection(_ s: MicroSnapshot) -> some View {
        Section {
            Toggle(isOn: Binding(get: { s.isOn }, set: { confirmPower = $0 })) {
                Label("Micro encendido", systemImage: "power")
            }
            .disabled(model.isWriting)

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Límite de potencia", systemImage: "gauge.with.dots.needle.33percent")
                    Spacer()
                    Text("\(Int(limitPercent)) %")
                        .font(.headline.monospacedDigit())
                }
                Slider(value: $limitPercent, in: 0...100, step: 1, onEditingChanged: { editing in
                    if editing { limitEdited = true }
                })
                HStack {
                    Text("Actual: \(Fmt.num(s.powerLimitPercent(device.limitScale), 1)) %")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Aplicar") { confirmLimit = true }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.isWriting || !limitEdited)
                }
            }
            .padding(.vertical, 4)
        } header: {
            Text("Control")
        } footer: {
            Text("Las órdenes se envían directamente al micro por la red local.")
        }
    }

    private func gridSection(_ s: MicroSnapshot) -> some View {
        Section("Red y equipo") {
            LabeledContent("Tensión", value: "\(Fmt.num(s.gridVoltage, 1)) V")
            LabeledContent("Corriente", value: "\(Fmt.num(s.gridCurrent, 1)) A")
            LabeledContent("Frecuencia", value: "\(Fmt.num(s.gridFrequency, 2)) Hz")
            LabeledContent("Temperatura", value: "\(Fmt.num(s.temperature, 1)) °C")
        }
    }

    private func problemsSection(_ s: MicroSnapshot) -> some View {
        Section("Avisos") {
            ForEach(s.activeFaults, id: \.self) { f in
                Label(f, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
            }
            ForEach(s.activeAlarms, id: \.self) { a in
                Label(a, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
        }
    }

    private func infoSection(_ s: MicroSnapshot) -> some View {
        Section("Información") {
            LabeledContent("Nº serie micro", value: s.inverterSerial.isEmpty ? "—" : s.inverterSerial)
            LabeledContent("Potencia nominal", value: Fmt.power(s.ratedPower))
            LabeledContent("Entradas MPPT", value: "\(s.mpptCount)")
            LabeledContent("Logger", value: "\(device.host) · \(device.loggerSerial)")
            LabeledContent("Reg. 40 (bruto)", value: "\(s.powerLimitRaw) · \(s.effectiveScale(device.limitScale).label)")
        }
        .font(.callout)
    }
}

// MARK: - Componentes

private struct StateBadge: View {
    let state: DeviceState
    let isOn: Bool

    private var color: Color {
        if !isOn { return .gray }
        switch state {
        case .normal: return .green
        case .standby, .selfTest: return .blue
        case .alarm: return .orange
        case .fault: return .red
        case .unknown: return .gray
        }
    }

    var body: some View {
        Label(isOn ? state.label : "Apagado", systemImage: "circle.fill")
            .font(.caption.weight(.semibold))
            .labelStyle(BadgeLabelStyle())
            .foregroundStyle(color)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(color.opacity(0.15), in: Capsule())
    }
}

private struct BadgeLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon.font(.system(size: 7))
            configuration.title
        }
    }
}

private struct Metric: View {
    let title: String
    let value: String
    var body: some View {
        VStack(spacing: 2) {
            Text(value).font(.headline.monospacedDigit())
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

enum Fmt {
    static func num(_ v: Double, _ digits: Int) -> String {
        v.formatted(.number.precision(.fractionLength(digits)))
    }
    static func power(_ w: Double) -> String {
        w >= 1000 ? "\(num(w / 1000, 2)) kW" : "\(num(w, 0)) W"
    }
    static func energy(_ kwh: Double) -> String {
        kwh >= 1000 ? "\(num(kwh / 1000, 2)) MWh" : "\(num(kwh, 1)) kWh"
    }
}
