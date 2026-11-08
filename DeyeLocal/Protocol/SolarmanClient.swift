import Foundation
import Network

/// Asegura que una continuación solo se reanuda una vez.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func run(_ block: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !done else { return }
        done = true
        block()
    }
}

/// Ejecuta 'operation' con límite de tiempo. Si vence, llama a 'onTimeout' (que debe
/// desbloquear la operación, p. ej. cancelando la conexión) y lanza '.timeout'.
/// Ojo: un task group espera siempre a todas sus tareas hijas, por eso 'onTimeout' es necesario.
func withTimeout<T: Sendable>(_ seconds: TimeInterval,
                              onTimeout: @escaping @Sendable () -> Void,
                              _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    // Si la tarea que llama se cancela (p. ej. se cierra la pantalla) también hay que
    // desbloquear la operación, o el task group se quedaría esperando para siempre.
    try await withTaskCancellationHandler {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                onTimeout()
                throw SolarmanError.timeout
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw SolarmanError.timeout }
            return result
        }
    } onCancel: {
        onTimeout()
    }
}

/// Cliente TCP Solarman V5 (equivalente a PySolarmanV5) usando Network.framework.
actor SolarmanClient {
    let host: String
    let port: UInt16
    let slave: UInt8
    let timeout: TimeInterval
    private let codec: SolarmanV5Codec

    private var connection: NWConnection?
    private var buffer: [UInt8] = []
    private var sequence: UInt8 = UInt8.random(in: 1...254)

    init(host: String, port: UInt16 = 8899, loggerSerial: UInt32, slave: UInt8 = 1, timeout: TimeInterval = 6) {
        self.host = host
        self.port = port
        self.slave = slave
        self.timeout = timeout
        self.codec = SolarmanV5Codec(loggerSerial: loggerSerial)
    }

    // MARK: - Conexión

    func connect() async throws {
        if connection != nil { return }
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw SolarmanError.connection("puerto no válido")
        }
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = Int(timeout)
        let conn = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: NWParameters(tls: nil, tcp: tcp))
        let once = ResumeOnce()
        do {
            try await withTimeout(timeout, onTimeout: { conn.cancel() }) {
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                    conn.stateUpdateHandler = { state in
                        switch state {
                        case .ready:
                            once.run { cont.resume() }
                        case .failed(let error):
                            once.run { cont.resume(throwing: SolarmanError.connection(error.localizedDescription)) }
                        case .cancelled:
                            once.run { cont.resume(throwing: SolarmanError.timeout) }
                        default:
                            break
                        }
                    }
                    conn.start(queue: .global(qos: .userInitiated))
                }
            }
        } catch {
            conn.cancel()
            throw error
        }
        buffer.removeAll()
        connection = conn
    }

    func close() {
        connection?.cancel()
        connection = nil
        buffer.removeAll()
    }

    // MARK: - Modbus

    func readHoldingRegisters(address: UInt16, count: UInt16) async throws -> [UInt16] {
        precondition(count >= 1 && count <= 125, "Modbus permite 1-125 registros por lectura")
        let request = ModbusRTU.readHoldingRequest(slave: slave, address: address, count: count)
        let response = try await transact(request)
        return try ModbusRTU.parseReadResponse(response, count: Int(count))
    }

    /// Escritura con función 0x10 (la que aceptan los Deye; 0x06 la rechazan muchos firmwares).
    func writeMultipleRegisters(address: UInt16, values: [UInt16]) async throws {
        let request = ModbusRTU.writeMultipleRequest(slave: slave, address: address, values: values)
        let response = try await transact(request)
        try ModbusRTU.parseWriteResponse(response, function: ModbusRTU.writeMultiple, address: address)
    }

    func writeSingleRegister(address: UInt16, value: UInt16) async throws {
        let request = ModbusRTU.writeSingleRequest(slave: slave, address: address, value: value)
        let response = try await transact(request)
        try ModbusRTU.parseWriteResponse(response, function: ModbusRTU.writeSingle, address: address)
    }

    // MARK: - Transporte

    private func nextSequence() -> UInt8 {
        sequence = sequence >= 254 ? 1 : sequence + 1
        return sequence
    }

    private func transact(_ modbus: [UInt8]) async throws -> [UInt8] {
        guard let conn = connection else { throw SolarmanError.notConnected }
        let seq = nextSequence()
        buffer.removeAll()
        do {
            try await send(conn, codec.encode(modbus: modbus, sequence: seq))
            return try await withTimeout(timeout, onTimeout: { conn.cancel() }) { [self] in
                try await self.awaitResponse(conn, sequence: seq)
            }
        } catch {
            // Tras un error la conexión queda en estado dudoso: se cierra y se reabre en la siguiente.
            close()
            throw error
        }
    }

    private func awaitResponse(_ conn: NWConnection, sequence seq: UInt8) async throws -> [UInt8] {
        while true {
            while let frame = SolarmanV5Codec.extractFrame(from: &buffer) {
                if let modbus = try codec.decode(frame, expectedSequence: seq) {
                    return modbus
                }
            }
            let chunk = try await receive(conn)
            buffer.append(contentsOf: chunk)
        }
    }

    private nonisolated func send(_ conn: NWConnection, _ bytes: [UInt8]) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.send(content: Data(bytes), completion: .contentProcessed { error in
                if let error {
                    cont.resume(throwing: SolarmanError.connection(error.localizedDescription))
                } else {
                    cont.resume()
                }
            })
        }
    }

    private nonisolated func receive(_ conn: NWConnection) async throws -> [UInt8] {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[UInt8], Error>) in
            conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, isComplete, error in
                if let error {
                    cont.resume(throwing: SolarmanError.connection(error.localizedDescription))
                } else if let data, !data.isEmpty {
                    cont.resume(returning: [UInt8](data))
                } else if isComplete {
                    cont.resume(throwing: SolarmanError.closed)
                } else {
                    cont.resume(returning: [])
                }
            }
        }
    }
}
