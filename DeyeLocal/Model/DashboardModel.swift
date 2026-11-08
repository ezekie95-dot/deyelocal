import Foundation
import Observation

/// Punto de la gráfica de producción del día.
struct PowerSample: Codable, Identifiable, Sendable {
    var date: Date
    var watts: Double
    var id: Date { date }
}

/// Estado del modo tablet: lee todos los micros seleccionados a la vez y guarda
/// la curva de potencia del día (un punto por minuto).
@MainActor
@Observable
final class DashboardModel {
    struct Entry {
        var snapshot: MicroSnapshot?
        var error: String?
        /// La última lectura falló: el dato mostrado es antiguo.
        var isStale: Bool { error != nil }
    }

    private static let historyKey = "dashboard.history.v1"
    private static let sampleEvery: TimeInterval = 60

    var devices: [MicroDevice]
    private(set) var entries: [UUID: Entry] = [:]
    private(set) var history: [PowerSample] = []
    private(set) var lastUpdate: Date?
    private(set) var isRefreshing = false

    init(devices: [MicroDevice]) {
        self.devices = devices
        loadHistory()
    }

    // MARK: - Totales

    private var fresh: [MicroSnapshot] {
        devices.compactMap { d in
            guard let e = entries[d.id], !e.isStale else { return nil }
            return e.snapshot
        }
    }

    private var all: [MicroSnapshot] {
        devices.compactMap { entries[$0.id]?.snapshot }
    }

    var totalPower: Double { fresh.reduce(0) { $0 + $1.acPower } }
    var totalRated: Double { all.reduce(0) { $0 + $1.ratedPower } }
    var todayEnergy: Double { all.reduce(0) { $0 + $1.todayEnergy } }
    var totalEnergy: Double { all.reduce(0) { $0 + $1.totalEnergy } }
    var onlineCount: Int { fresh.count }
    var peakToday: Double { history.map(\.watts).max() ?? 0 }

    // MARK: - Lectura

    func poll(every seconds: Double = 10) async {
        while !Task.isCancelled {
            await refreshAll()
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
    }

    func refreshAll() async {
        guard !isRefreshing, !devices.isEmpty else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        typealias Outcome = (id: UUID, result: Result<MicroSnapshot, Error>)
        let list = devices
        await withTaskGroup(of: Outcome.self) { group in
            for device in list {
                group.addTask {
                    do {
                        return (device.id, .success(try await MicroService(device: device).read()))
                    } catch {
                        return (device.id, .failure(error))
                    }
                }
            }
            for await outcome in group {
                let id = outcome.id, result = outcome.result
                var entry = entries[id] ?? Entry()
                switch result {
                case .success(let snap):
                    entry.snapshot = snap
                    entry.error = nil
                case .failure(let error):
                    if error is CancellationError { continue }
                    entry.error = error.localizedDescription
                }
                entries[id] = entry
            }
        }
        lastUpdate = Date()
        record()
    }

    // MARK: - Historial del día

    private func record() {
        let now = Date()
        let cal = Calendar.current
        if let first = history.first, !cal.isDate(first.date, inSameDayAs: now) {
            history.removeAll()
        }
        if let last = history.last, now.timeIntervalSince(last.date) < Self.sampleEvery {
            // Dentro del mismo minuto: el punto guarda el valor máximo de ese minuto.
            history[history.count - 1].watts = max(history[history.count - 1].watts, totalPower)
        } else {
            history.append(PowerSample(date: now, watts: totalPower))
        }
        saveHistory()
    }

    private func loadHistory() {
        guard let data = UserDefaults.standard.data(forKey: Self.historyKey),
              let list = try? JSONDecoder().decode([PowerSample].self, from: data),
              let first = list.first,
              Calendar.current.isDateInToday(first.date) else { return }
        history = list
    }

    private func saveHistory() {
        if let data = try? JSONEncoder().encode(history) {
            UserDefaults.standard.set(data, forKey: Self.historyKey)
        }
    }
}
