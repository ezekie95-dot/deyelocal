import Foundation
import Observation
import SwiftUI  // remove(atOffsets:) y move(fromOffsets:toOffset:)

/// Lista de micros guardada en el dispositivo, más la configuración del modo tablet.
@Observable
final class DeviceStore {
    private static let key = "devices.v1"
    private static let dashboardKey = "dashboard.ids.v1"
    private static let autoStartKey = "dashboard.autostart.v1"
    private let defaults: UserDefaults

    private(set) var devices: [MicroDevice] = []
    /// Micros que se muestran en el modo tablet, en el orden elegido.
    private(set) var dashboardIDs: [UUID] = []
    /// Abrir el modo tablet al arrancar la app (para un iPad fijo en la pared).
    private(set) var autoStartDashboard = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key),
           let list = try? JSONDecoder().decode([MicroDevice].self, from: data) {
            devices = list
        }
        if let data = defaults.data(forKey: Self.dashboardKey),
           let ids = try? JSONDecoder().decode([UUID].self, from: data) {
            dashboardIDs = ids
        }
        autoStartDashboard = defaults.bool(forKey: Self.autoStartKey)
    }

    var dashboardDevices: [MicroDevice] {
        dashboardIDs.compactMap { id in devices.first { $0.id == id } }
    }

    func upsert(_ device: MicroDevice) {
        if let i = devices.firstIndex(where: { $0.id == device.id }) {
            devices[i] = device
        } else {
            devices.append(device)
        }
        save()
    }

    func delete(at offsets: IndexSet) {
        let removed = Set(offsets.map { devices[$0].id })
        devices.remove(atOffsets: offsets)
        dashboardIDs.removeAll { removed.contains($0) }
        save()
    }

    func move(from source: IndexSet, to destination: Int) {
        devices.move(fromOffsets: source, toOffset: destination)
        save()
    }

    func setDashboard(_ ids: [UUID]) {
        dashboardIDs = ids
        save()
    }

    func setAutoStartDashboard(_ value: Bool) {
        autoStartDashboard = value
        defaults.set(value, forKey: Self.autoStartKey)
    }

    private func save() {
        if let data = try? JSONEncoder().encode(devices) {
            defaults.set(data, forKey: Self.key)
        }
        if let data = try? JSONEncoder().encode(dashboardIDs) {
            defaults.set(data, forKey: Self.dashboardKey)
        }
    }
}
