import Foundation

/// Cómo interpreta el micro el registro 40 (límite de potencia activa).
/// Según firmware se guarda en % (0-120) o en décimas de % (0-1200).
enum PowerLimitScale: String, Codable, CaseIterable, Identifiable, Sendable {
    case auto, percent, tenths
    var id: String { rawValue }
    var label: String {
        switch self {
        case .auto: return "Automático"
        case .percent: return "% (0-120)"
        case .tenths: return "Décimas de % (0-1200)"
        }
    }
}

/// Un logger Solarman con su microinversor Deye.
struct MicroDevice: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var name: String
    var host: String
    var port: UInt16 = 8899
    var loggerSerial: UInt32
    var slaveID: UInt8 = 1
    var limitScale: PowerLimitScale = .auto

    static let example = MicroDevice(name: "Micro tejado", host: "192.168.1.50", loggerSerial: 2712345678)
}
