import Foundation

/// Errores de la capa Modbus RTU.
enum ModbusError: LocalizedError, Equatable {
    case exception(function: UInt8, code: UInt8)
    case invalidResponse(String)
    case crcMismatch

    var errorDescription: String? {
        switch self {
        case .exception(_, let code):
            let text: String
            switch code {
            case 1: text = "función no soportada"
            case 2: text = "dirección de registro no válida"
            case 3: text = "valor no válido"
            case 4: text = "fallo del dispositivo"
            default: text = "código \(code)"
            }
            return "El micro rechazó la orden (\(text))."
        case .invalidResponse(let why):
            return "Respuesta Modbus no válida: \(why)"
        case .crcMismatch:
            return "Respuesta Modbus con CRC incorrecto."
        }
    }
}

/// Construcción y análisis de tramas Modbus RTU (las que van dentro de la trama Solarman V5).
enum ModbusRTU {
    static let readHolding: UInt8 = 0x03
    static let writeSingle: UInt8 = 0x06
    static let writeMultiple: UInt8 = 0x10

    /// CRC-16/MODBUS (polinomio 0xA001, inicial 0xFFFF).
    static func crc16<C: Collection>(_ data: C) -> UInt16 where C.Element == UInt8 {
        var crc: UInt16 = 0xFFFF
        for byte in data {
            crc ^= UInt16(byte)
            for _ in 0..<8 {
                crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xA001 : crc >> 1
            }
        }
        return crc
    }

    private static func withCRC(_ frame: [UInt8]) -> [UInt8] {
        let crc = crc16(frame)
        return frame + [UInt8(crc & 0xFF), UInt8(crc >> 8)]
    }

    private static func be(_ v: UInt16) -> [UInt8] { [UInt8(v >> 8), UInt8(v & 0xFF)] }

    static func readHoldingRequest(slave: UInt8, address: UInt16, count: UInt16) -> [UInt8] {
        withCRC([slave, readHolding] + be(address) + be(count))
    }

    static func writeSingleRequest(slave: UInt8, address: UInt16, value: UInt16) -> [UInt8] {
        withCRC([slave, writeSingle] + be(address) + be(value))
    }

    static func writeMultipleRequest(slave: UInt8, address: UInt16, values: [UInt16]) -> [UInt8] {
        var f: [UInt8] = [slave, writeMultiple] + be(address) + be(UInt16(values.count))
        f.append(UInt8(values.count * 2))
        for v in values { f += be(v) }
        return withCRC(f)
    }

    /// Comprueba excepción y CRC. Devuelve solo los bytes útiles (sin bytes extra al final,
    /// algunos loggers añaden un segundo CRC o ceros).
    private static func validated(_ frame: [UInt8], function: UInt8, expectedLength: (([UInt8]) -> Int)) throws -> [UInt8] {
        guard frame.count >= 5 else { throw ModbusError.invalidResponse("trama demasiado corta") }
        if frame[1] == function | 0x80 {
            throw ModbusError.exception(function: function, code: frame[2])
        }
        guard frame[1] == function else {
            throw ModbusError.invalidResponse("función \(frame[1]) inesperada")
        }
        let len = expectedLength(frame)
        guard frame.count >= len else { throw ModbusError.invalidResponse("faltan bytes") }
        let body = Array(frame[0..<(len - 2)])
        let crc = crc16(body)
        guard frame[len - 2] == UInt8(crc & 0xFF), frame[len - 1] == UInt8(crc >> 8) else {
            throw ModbusError.crcMismatch
        }
        return body
    }

    static func parseReadResponse(_ frame: [UInt8], count: Int) throws -> [UInt16] {
        let body = try validated(frame, function: readHolding) { 3 + Int($0[2]) + 2 }
        let byteCount = Int(body[2])
        guard byteCount == count * 2 else {
            throw ModbusError.invalidResponse("se esperaban \(count) registros y llegaron \(byteCount / 2)")
        }
        var out: [UInt16] = []
        out.reserveCapacity(count)
        for i in 0..<count {
            out.append(UInt16(body[3 + 2 * i]) << 8 | UInt16(body[4 + 2 * i]))
        }
        return out
    }

    static func parseWriteResponse(_ frame: [UInt8], function: UInt8, address: UInt16) throws {
        let body = try validated(frame, function: function) { _ in 8 }
        let addr = UInt16(body[2]) << 8 | UInt16(body[3])
        guard addr == address else {
            throw ModbusError.invalidResponse("dirección \(addr) en la confirmación")
        }
    }
}
