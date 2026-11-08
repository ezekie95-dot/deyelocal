import Foundation

/// Operaciones de alto nivel sobre un micro. Abre conexión, hace la operación y cierra
/// (los loggers Solarman admiten muy pocas conexiones simultáneas).
struct MicroService: Sendable {
    let device: MicroDevice

    private func client() -> SolarmanClient {
        SolarmanClient(host: device.host, port: device.port,
                       loggerSerial: device.loggerSerial, slave: device.slaveID)
    }

    /// Reintenta una vez: es habitual que el logger ignore la primera petición tras conectar.
    private func run<T>(_ body: (SolarmanClient) async throws -> T) async throws -> T {
        var lastError: Error = SolarmanError.timeout
        for attempt in 0..<2 {
            let c = client()
            do {
                try await c.connect()
                let result = try await body(c)
                await c.close()
                return result
            } catch {
                await c.close()
                lastError = error
                // Una excepción Modbus es una respuesta real del micro: no tiene sentido reintentar.
                if error is ModbusError { throw error }
                if attempt == 0 { try? await Task.sleep(nanoseconds: 400_000_000) }
            }
        }
        throw lastError
    }

    func read() async throws -> MicroSnapshot {
        try await run { c in
            var regs: [UInt16: UInt16] = [:]
            for block in DeyeMicroG4.readBlocks {
                let values = try await c.readHoldingRegisters(address: block.start, count: block.count)
                for (i, v) in values.enumerated() { regs[block.start + UInt16(i)] = v }
            }
            return MicroSnapshot(registers: regs)
        }
    }

    func setPower(on: Bool) async throws {
        try await run { c in
            try await c.writeMultipleRegisters(address: DeyeMicroG4.Reg.onOff,
                                               values: [on ? DeyeMicroG4.onValue : DeyeMicroG4.offValue])
        }
    }

    func setPowerLimit(raw: UInt16) async throws {
        try await run { c in
            try await c.writeMultipleRegisters(address: DeyeMicroG4.Reg.powerLimit, values: [raw])
        }
    }

    /// Comprobación rápida: lee el tipo de dispositivo y el nº de serie del micro.
    func test() async throws -> String {
        try await run { c in
            let regs = try await c.readHoldingRegisters(address: 0, count: 8)
            var map: [UInt16: UInt16] = [:]
            for (i, v) in regs.enumerated() { map[UInt16(i)] = v }
            let snap = MicroSnapshot(registers: map)
            let type = regs[0] == 0x0004 || regs[0] == 0x0400 ? "Microinversor" : String(format: "Tipo 0x%04X", regs[0])
            return "\(type) · nº serie \(snap.inverterSerial.isEmpty ? "?" : snap.inverterSerial)"
        }
    }
}
