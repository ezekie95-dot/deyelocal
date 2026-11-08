import Foundation

enum SolarmanError: LocalizedError, Equatable {
    case timeout
    case connection(String)
    case closed
    case notConnected
    case invalidFrame(String)
    case wrongSerial(UInt32)
    case noInverterResponse

    var errorDescription: String? {
        switch self {
        case .timeout:
            return "Tiempo de espera agotado. Revisa la IP del logger y que el iPhone esté en la misma WiFi."
        case .connection(let msg):
            return "No se pudo conectar con el logger: \(msg)"
        case .closed:
            return "El logger cerró la conexión."
        case .notConnected:
            return "No hay conexión con el logger."
        case .invalidFrame(let why):
            return "Trama Solarman no válida: \(why)"
        case .wrongSerial(let s):
            return "El logger responde con otro número de serie (\(s)). Revisa el nº de serie configurado."
        case .noInverterResponse:
            return "El logger responde pero el micro no (¿es de noche o está sin paneles conectados?)."
        }
    }
}

/// Codificación / decodificación de tramas del protocolo Solarman V5
/// (el mismo que usa pysolarmanv5).
///
/// Petición:  A5 | len(2,LE) | 0x4510(LE) | seq(2) | serial logger(4,LE) |
///            02 | 0000 | 00000000 ×3 | trama Modbus RTU | checksum | 15
/// Respuesta: igual con control 0x1510 y 14 bytes de cabecera de payload,
///            la trama Modbus empieza en el byte 25.
struct SolarmanV5Codec {
    let loggerSerial: UInt32

    static let start: UInt8 = 0xA5
    static let end: UInt8 = 0x15
    static let requestControl: UInt16 = 0x4510
    static let responseControl: UInt16 = 0x1510
    static let counterControl: UInt16 = 0x4710

    static func checksum(_ frame: [UInt8]) -> UInt8 {
        guard frame.count >= 3 else { return 0 }
        var sum: UInt32 = 0
        for b in frame[1..<(frame.count - 2)] { sum &+= UInt32(b) }
        return UInt8(sum & 0xFF)
    }

    private static func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8)] }
    private static func le32(_ v: UInt32) -> [UInt8] {
        [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8(v >> 24)]
    }

    func encode(modbus: [UInt8], sequence: UInt8) -> [UInt8] {
        var frame: [UInt8] = [Self.start]
        frame += Self.le16(UInt16(15 + modbus.count))
        frame += Self.le16(Self.requestControl)
        frame += [sequence, 0x00]
        frame += Self.le32(loggerSerial)
        frame += [0x02, 0x00, 0x00]                // tipo de trama, tipo de sensor
        frame += [UInt8](repeating: 0, count: 12)  // delivery, power-on, offset time
        frame += modbus
        frame += [0x00, Self.end]
        frame[frame.count - 2] = Self.checksum(frame)
        return frame
    }

    /// Saca una trama completa del buffer de recepción (TCP puede partir o juntar tramas).
    static func extractFrame(from buffer: inout [UInt8]) -> [UInt8]? {
        while true {
            guard let idx = buffer.firstIndex(of: start) else {
                buffer.removeAll()
                return nil
            }
            if idx > 0 { buffer.removeFirst(idx) }
            guard buffer.count >= 3 else { return nil }
            let len = Int(buffer[1]) | Int(buffer[2]) << 8
            if len > 2048 {           // basura: descartamos este 0xA5 y seguimos buscando
                buffer.removeFirst()
                continue
            }
            let total = 13 + len
            guard buffer.count >= total else { return nil }
            let frame = Array(buffer[0..<total])
            buffer.removeFirst(total)
            return frame
        }
    }

    /// Devuelve la trama Modbus contenida, o 'nil' si es una trama que hay que ignorar
    /// (contador/heartbeat del logger o respuesta a otra petición).
    func decode(_ frame: [UInt8], expectedSequence: UInt8) throws -> [UInt8]? {
        guard frame.count >= 13 else { throw SolarmanError.invalidFrame("demasiado corta") }
        let control = UInt16(frame[3]) | UInt16(frame[4]) << 8
        if control == Self.counterControl { return nil }
        if frame[5] != expectedSequence { return nil }

        guard frame[0] == Self.start, frame[frame.count - 1] == Self.end else {
            throw SolarmanError.invalidFrame("inicio/fin incorrectos")
        }
        guard frame[frame.count - 2] == Self.checksum(frame) else {
            throw SolarmanError.invalidFrame("checksum incorrecto")
        }
        let serial = UInt32(frame[7]) | UInt32(frame[8]) << 8 | UInt32(frame[9]) << 16 | UInt32(frame[10]) << 24
        guard serial == loggerSerial else { throw SolarmanError.wrongSerial(serial) }
        guard control == Self.responseControl else {
            throw SolarmanError.invalidFrame(String(format: "código de control 0x%04X", control))
        }
        guard frame[11] == 0x02 else { throw SolarmanError.invalidFrame("tipo de trama \(frame[11])") }

        guard frame.count > 27 else { throw SolarmanError.noInverterResponse }
        let modbus = Array(frame[25..<(frame.count - 2)])
        guard modbus.count >= 5 else { throw SolarmanError.noInverterResponse }
        return modbus
    }
}
