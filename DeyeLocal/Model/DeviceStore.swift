import Foundation
import Observation
import SwiftUI  // remove(atOffsets:) y move(fromOffsets:toOffset:)

/// Lista de micros guardada en el dispositivo.
@Observable
final class DeviceStore {
    private static let key = "devices.v1"
    private let defaults: UserDefaults

    private(set) var devices: [MicroDevice] = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key),
           let list = try? JSONDecoder().decode([MicroDevice].self, from: data) {
            devices = list
        }
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
        devices.remove(atOffsets: offsets)
        save()
    }

    func move(from source: IndexSet, to destination: Int) {
        devices.move(fromOffsets: source, toOffset: destination)
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(devices) {
            defaults.set(data, forKey: Self.key)
        }
    }
}
