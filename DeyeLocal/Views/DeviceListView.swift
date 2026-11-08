import SwiftUI

struct DeviceListView: View {
    @Environment(DeviceStore.self) private var store
    @State private var editing: MicroDevice?
    @State private var showingNew = false
    @State private var showingSetup = false
    @State private var showingDashboard = false
    @State private var startAfterSetup = false
    /// Solo se abre automáticamente una vez por arranque de la app.
    private static var didAutoStart = false

    var body: some View {
        NavigationStack {
            Group {
                if store.devices.isEmpty {
                    ContentUnavailableView {
                        Label("Sin micros", systemImage: "sun.max")
                    } description: {
                        Text("Añade el logger de tu microinversor Deye con su IP y su número de serie.")
                    } actions: {
                        Button("Añadir micro") { showingNew = true }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    List {
                        ForEach(store.devices) { device in
                            NavigationLink(value: device.id) {
                                DeviceRow(device: device)
                            }
                            .swipeActions(edge: .leading) {
                                Button("Editar") { editing = device }.tint(.blue)
                            }
                        }
                        .onDelete(perform: store.delete)
                        .onMove(perform: store.move)
                    }
                }
            }
            .navigationTitle("Micros Deye")
            .navigationDestination(for: UUID.self) { id in
                if let device = store.devices.first(where: { $0.id == id }) {
                    DeviceDetailView(device: device)
                }
            }
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if !store.devices.isEmpty {
                        Button { showingSetup = true } label: { Image(systemName: "rectangle.grid.2x2") }
                            .accessibilityLabel("Modo tablet")
                    }
                    Button { showingNew = true } label: { Image(systemName: "plus") }
                        .accessibilityLabel("Añadir micro")
                }
                if !store.devices.isEmpty {
                    ToolbarItem(placement: .topBarLeading) { EditButton() }
                }
            }
            .sheet(isPresented: $showingNew) {
                DeviceEditView(device: nil) { store.upsert($0) }
            }
            .sheet(item: $editing) { device in
                DeviceEditView(device: device) { store.upsert($0) }
            }
            .sheet(isPresented: $showingSetup, onDismiss: {
                if startAfterSetup {
                    startAfterSetup = false
                    showingDashboard = true
                }
            }) {
                DashboardSetupView { startAfterSetup = true }
            }
        }
        .fullScreenCover(isPresented: $showingDashboard) {
            TabletDashboardView(devices: store.dashboardDevices)
        }
        .onAppear {
            if !Self.didAutoStart, store.autoStartDashboard, !store.dashboardDevices.isEmpty {
                Self.didAutoStart = true
                showingDashboard = true
            }
        }
    }
}

private struct DeviceRow: View {
    let device: MicroDevice

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "sun.max.fill")
                .font(.title2)
                .foregroundStyle(.orange)
                .frame(width: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(device.name).font(.headline)
                Text("\(device.host):\(device.port) · SN \(device.loggerSerial)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}
