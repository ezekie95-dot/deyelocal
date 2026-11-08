import SwiftUI

struct DeviceEditView: View {
    @Environment(\.dismiss) private var dismiss

    let original: MicroDevice?
    let onSave: (MicroDevice) -> Void

    @State private var name: String
    @State private var host: String
    @State private var port: String
    @State private var serial: String
    @State private var slave: String
    @State private var limitScale: PowerLimitScale

    @State private var testing = false
    @State private var testResult: String?
    @State private var testOK = false

    init(device: MicroDevice?, onSave: @escaping (MicroDevice) -> Void) {
        self.original = device
        self.onSave = onSave
        _name = State(initialValue: device?.name ?? "")
        _host = State(initialValue: device?.host ?? "")
        _port = State(initialValue: String(device?.port ?? 8899))
        _serial = State(initialValue: device.map { String($0.loggerSerial) } ?? "")
        _slave = State(initialValue: String(device?.slaveID ?? 1))
        _limitScale = State(initialValue: device?.limitScale ?? .auto)
    }

    private var built: MicroDevice? {
        let h = host.trimmingCharacters(in: .whitespaces)
        guard !h.isEmpty,
              let p = UInt16(port), p > 0,
              let s = UInt32(serial.trimmingCharacters(in: .whitespaces)),
              let sl = UInt8(slave), sl > 0 else { return nil }
        var d = original ?? MicroDevice(name: "", host: h, loggerSerial: s)
        d.name = name.trimmingCharacters(in: .whitespaces).isEmpty ? "Micro \(s)" : name
        d.host = h
        d.port = p
        d.loggerSerial = s
        d.slaveID = sl
        d.limitScale = limitScale
        return d
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Micro") {
                    TextField("Nombre (p. ej. Tejado garaje)", text: $name)
                }
                Section {
                    TextField("IP del logger", text: $host)
                        .keyboardType(.numbersAndPunctuation)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Nº de serie del logger", text: $serial)
                        .keyboardType(.numberPad)
                } header: {
                    Text("Logger Solarman")
                } footer: {
                    Text("El nº de serie es el del logger WiFi (10 dígitos, en la etiqueta del micro o en la app Solarman), no el del inversor.")
                }
                Section("Avanzado") {
                    LabeledContent("Puerto") {
                        TextField("8899", text: $port).keyboardType(.numberPad).multilineTextAlignment(.trailing)
                    }
                    LabeledContent("ID esclavo Modbus") {
                        TextField("1", text: $slave).keyboardType(.numberPad).multilineTextAlignment(.trailing)
                    }
                    Picker("Escala límite potencia", selection: $limitScale) {
                        ForEach(PowerLimitScale.allCases) { Text($0.label).tag($0) }
                    }
                }
                Section {
                    Button {
                        Task { await runTest() }
                    } label: {
                        HStack {
                            Text("Probar conexión")
                            Spacer()
                            if testing { ProgressView() }
                        }
                    }
                    .disabled(built == nil || testing)
                    if let testResult {
                        Label(testResult, systemImage: testOK ? "checkmark.circle.fill" : "xmark.octagon.fill")
                            .foregroundStyle(testOK ? .green : .red)
                            .font(.callout)
                    }
                }
            }
            .navigationTitle(original == nil ? "Nuevo micro" : "Editar micro")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Guardar") {
                        if let d = built { onSave(d); dismiss() }
                    }
                    .disabled(built == nil)
                }
            }
        }
    }

    private func runTest() async {
        guard let d = built else { return }
        testing = true
        testResult = nil
        do {
            testResult = try await MicroService(device: d).test()
            testOK = true
        } catch {
            testResult = error.localizedDescription
            testOK = false
        }
        testing = false
    }
}
