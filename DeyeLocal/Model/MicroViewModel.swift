import Foundation
import Observation

@MainActor
@Observable
final class MicroViewModel {
    private(set) var device: MicroDevice
    private(set) var snapshot: MicroSnapshot?
    private(set) var isLoading = false
    private(set) var isWriting = false
    var errorMessage: String?
    var infoMessage: String?

    init(device: MicroDevice) {
        self.device = device
    }

    func update(device: MicroDevice) {
        self.device = device
    }

    private var service: MicroService { MicroService(device: device) }

    func refresh() async {
        guard !isWriting, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            snapshot = try await service.read()
            errorMessage = nil
        } catch is CancellationError {
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Bucle de refresco automático mientras la vista está visible.
    func poll(every seconds: Double = 10) async {
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
    }

    func setPower(on: Bool) async {
        await write(success: on ? "Micro encendido" : "Micro apagado") {
            try await $0.setPower(on: on)
        }
    }

    func setPowerLimit(percent: Double) async {
        let scale = snapshot?.effectiveScale(device.limitScale) ?? (device.limitScale == .auto ? .tenths : device.limitScale)
        let raw = MicroSnapshot.rawLimit(percent: percent, scale: scale)
        await write(success: "Límite fijado al \(Int(percent.rounded())) %") {
            try await $0.setPowerLimit(raw: raw)
        }
    }

    private func write(success: String, _ op: (MicroService) async throws -> Void) async {
        // Espera a que termine una lectura en curso para no abrir dos conexiones.
        while isLoading { try? await Task.sleep(nanoseconds: 100_000_000) }
        isWriting = true
        do {
            try await op(service)
            infoMessage = success
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        isWriting = false
        try? await Task.sleep(nanoseconds: 800_000_000)
        await refresh()
    }
}
