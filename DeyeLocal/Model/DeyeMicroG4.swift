import Foundation

/// Mapa de registros (holding, función 0x03) de los microinversores Deye SUN-M G4.
/// Fuente: definición 'deye_micro.yaml' de ha-solarman (davidrapan).
/// Los valores de 32/64 bits van con la palabra BAJA primero.
enum DeyeMicroG4 {
    enum Reg {
        static let deviceType: UInt16 = 0
        static let serial: UInt16 = 3          // 3..7, 10 caracteres ASCII
        static let ratedPower: UInt16 = 16     // 16-17, x0.1 W
        static let mpptPhases: UInt16 = 18     // nº MPPT en 0x0F00, fases en 0x000F
        static let powerLimit: UInt16 = 40     // límite potencia activa (%)
        static let onOff: UInt16 = 43          // 1 = encendido, 2 = apagado
        static let state: UInt16 = 59
        static let todayEnergy: UInt16 = 60    // x0.1 kWh
        static let totalEnergy: UInt16 = 63    // 63-64, x0.1 kWh
        static let todayPV: [UInt16] = [65, 66, 67, 68]
        static let totalPV: [UInt16] = [69, 71, 74, 77]   // cada uno 2 registros
        static let gridVoltage: UInt16 = 73    // x0.1 V
        static let gridCurrent: UInt16 = 76    // con signo, x0.1 A
        static let gridFrequency: UInt16 = 79  // x0.01 Hz
        static let acPower: UInt16 = 86        // 86-87, x0.1 W
        static let temperature: UInt16 = 90    // (raw - 1000) x 0.01 °C
        static let alarms: UInt16 = 101        // 101-102
        static let faults: UInt16 = 103        // 103-106
        static let pvVoltage: [UInt16] = [109, 111, 113, 115]  // x0.1 V
        static let pvCurrent: [UInt16] = [110, 112, 114, 116]  // x0.1 A
    }

    static let onValue: UInt16 = 1
    static let offValue: UInt16 = 2

    /// Bloques que se leen en cada refresco (máx. 125 registros por petición).
    static let readBlocks: [(start: UInt16, count: UInt16)] = [(0, 91), (101, 16)]

    static let faultNames: [Int: String] = [
        0: "Sobretensión DC",
        1: "Sobretensión bus DC",
        2: "Bus DC desequilibrado",
        3: "Subtensión bus DC",
        4: "Bus DC2 desequilibrado",
        5: "Sobrecorriente DC rama A",
        6: "Sobrecorriente DC rama B",
        7: "Perturbación entrada DC",
        8: "Sobrecorriente red",
        9: "Sobrecorriente IGBT",
        10: "Perturbación de red",
        11: "Protección autotest de arco",
        12: "Fallo de arco",
        13: "Muestreo corriente de red anómalo",
        16: "Fallo fase de red / relé",
        17: "Fallo fase de red / relé",
        20: "Fallo fase de red / relé",
        23: "Fallo fase de red / relé",
        24: "Fallo fase de red / relé",
        25: "Fallo fase de red / relé",
    ]

    static let alarmNames: [Int: String] = [
        1: "Fallo de ventilador",
        2: "Fallo de fase de red",
        3: "Fallo comunicación contador",
        30: "Pérdida de batería",
        31: "Calidad comunicación paralelo",
    ]
}

enum DeviceState: Int, Sendable {
    case standby = 0, selfTest = 1, normal = 2, alarm = 3, fault = 4
    case unknown = -1

    var label: String {
        switch self {
        case .standby: return "En espera"
        case .selfTest: return "Autotest"
        case .normal: return "Produciendo"
        case .alarm: return "Alarma"
        case .fault: return "Fallo"
        case .unknown: return "Desconocido"
        }
    }
}

struct PVChannel: Identifiable, Sendable {
    let id: Int          // 1...4
    let voltage: Double
    let current: Double
    var power: Double { voltage * current }
    let todayEnergy: Double
    let totalEnergy: Double
}

/// Lectura completa del micro en un instante.
struct MicroSnapshot: Sendable {
    var timestamp = Date()
    var inverterSerial: String
    var ratedPower: Double
    var mpptCount: Int
    var state: DeviceState
    var isOn: Bool
    var powerLimitRaw: UInt16
    var acPower: Double
    var gridVoltage: Double
    var gridCurrent: Double
    var gridFrequency: Double
    var temperature: Double
    var todayEnergy: Double
    var totalEnergy: Double
    var pv: [PVChannel]
    var alarmBits: UInt32
    var faultBits: UInt64

    var dcPower: Double { pv.reduce(0) { $0 + $1.power } }

    var activeAlarms: [String] {
        (0..<32).filter { alarmBits & (1 << UInt32($0)) != 0 }
            .map { DeyeMicroG4.alarmNames[$0] ?? "Alarma bit \($0)" }
    }

    var activeFaults: [String] {
        var seen = Set<String>()
        return (0..<64).filter { faultBits & (1 << UInt64($0)) != 0 }
            .map { DeyeMicroG4.faultNames[$0] ?? "Fallo bit \($0)" }
            .filter { seen.insert($0).inserted }
    }

    /// Escala efectiva del registro 40 para este micro.
    func effectiveScale(_ setting: PowerLimitScale) -> PowerLimitScale {
        guard setting == .auto else { return setting }
        return powerLimitRaw > 120 ? .tenths : .percent
    }

    func powerLimitPercent(_ setting: PowerLimitScale) -> Double {
        effectiveScale(setting) == .tenths ? Double(powerLimitRaw) / 10 : Double(powerLimitRaw)
    }

    static func rawLimit(percent: Double, scale: PowerLimitScale) -> UInt16 {
        let p = min(max(percent, 0), 120)
        return UInt16((scale == .tenths ? p * 10 : p).rounded())
    }

    /// Construye la lectura a partir de los registros leídos (dirección -> valor).
    init(registers r: [UInt16: UInt16]) {
        func u16(_ a: UInt16) -> UInt16 { r[a] ?? 0 }
        func s16(_ a: UInt16) -> Int16 { Int16(bitPattern: u16(a)) }
        func u32(_ a: UInt16) -> UInt32 { UInt32(u16(a)) | UInt32(u16(a + 1)) << 16 }
        func s32(_ a: UInt16) -> Int32 { Int32(bitPattern: u32(a)) }
        typealias R = DeyeMicroG4.Reg

        var serialBytes: [UInt8] = []
        for i in 0..<5 {
            let v = u16(R.serial + UInt16(i))
            serialBytes += [UInt8(v >> 8), UInt8(v & 0xFF)]
        }
        inverterSerial = String(decoding: serialBytes.filter { $0 >= 0x20 && $0 < 0x7F }, as: UTF8.self)
            .trimmingCharacters(in: .whitespaces)

        ratedPower = Double(s32(R.ratedPower)) * 0.1
        let rawMppt = Int((u16(R.mpptPhases) & 0x0F00) >> 8)
        let mppt = (1...4).contains(rawMppt) ? rawMppt : 4
        mpptCount = mppt
        state = DeviceState(rawValue: Int(u16(R.state))) ?? .unknown
        isOn = u16(R.onOff) != DeyeMicroG4.offValue
        powerLimitRaw = u16(R.powerLimit)

        acPower = Double(u32(R.acPower)) * 0.1
        gridVoltage = Double(u16(R.gridVoltage)) * 0.1
        gridCurrent = Double(s16(R.gridCurrent)) * 0.1
        gridFrequency = Double(u16(R.gridFrequency)) * 0.01
        temperature = (Double(u16(R.temperature)) - 1000) * 0.01
        todayEnergy = Double(u16(R.todayEnergy)) * 0.1
        totalEnergy = Double(u32(R.totalEnergy)) * 0.1

        var channels: [PVChannel] = []
        for i in 0..<mppt {
            channels.append(PVChannel(
                id: i + 1,
                voltage: Double(u16(R.pvVoltage[i])) * 0.1,
                current: Double(u16(R.pvCurrent[i])) * 0.1,
                todayEnergy: Double(u16(R.todayPV[i])) * 0.1,
                totalEnergy: Double(u32(R.totalPV[i])) * 0.1
            ))
        }
        pv = channels

        alarmBits = u32(R.alarms)
        faultBits = UInt64(u32(R.faults)) | UInt64(u32(R.faults + 2)) << 32
    }
}
