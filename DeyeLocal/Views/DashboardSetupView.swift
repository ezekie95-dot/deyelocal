import SwiftUI

/// Elegir qué micros salen en el modo tablet y en qué orden.
struct DashboardSetupView: View {
    @Environment(DeviceStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let onStart: () -> Void

    @State private var selected: [UUID] = []
    @State private var autoStart = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(store.devices) { device in
                        Button {
                            toggle(device.id)
                        } label: {
                            HStack {
                                Image(systemName: selected.contains(device.id) ? "checkmark.circle.fill" : "circle")
                                    .font(.title3)
                                    .foregroundStyle(selected.contains(device.id) ? Color.orange : Color.secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(device.name).foregroundStyle(.primary)
                                    Text(device.host).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if let i = selected.firstIndex(of: device.id) {
                                    Text("\(i + 1)")
                                        .font(.caption.weight(.bold))
                                        .frame(width: 24, height: 24)
                                        .background(Color.orange.opacity(0.2), in: Circle())
                                        .foregroundStyle(.orange)
                                }
                            }
                        }
                    }
                } header: {
                    Text("Micros a mostrar")
                } footer: {
                    Text("Aparecen en el orden en que los marques. El modo tablet solo muestra datos: no se puede encender, apagar ni limitar desde él.")
                }

                Section {
                    Toggle("Abrir en modo tablet al iniciar", isOn: $autoStart)
                } footer: {
                    Text("Útil para un iPad fijo en la pared. La pantalla no se apaga mientras el modo tablet está abierto; deja el iPad cargando.")
                }
            }
            .navigationTitle("Modo tablet")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cerrar") { save(); dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Abrir") {
                        save()
                        onStart()
                        dismiss()
                    }
                    .disabled(selected.isEmpty)
                }
            }
            .onAppear {
                selected = store.dashboardIDs.filter { id in store.devices.contains { $0.id == id } }
                autoStart = store.autoStartDashboard
            }
        }
    }

    private func toggle(_ id: UUID) {
        if let i = selected.firstIndex(of: id) {
            selected.remove(at: i)
        } else {
            selected.append(id)
        }
    }

    private func save() {
        store.setDashboard(selected)
        store.setAutoStartDashboard(autoStart)
    }
}
