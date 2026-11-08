import XCTest
@testable import DeyeLocal

/// Los vectores de prueba se han generado con pysolarmanv5 3.0.6 (logger 2712345678, secuencia 0x42),
/// así que si estos tests pasan, la app habla exactamente el mismo protocolo que la librería Python.
final class ProtocolTests: XCTestCase {
    private func hex(_ s: String) -> [UInt8] {
        var out: [UInt8] = []
        var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 2)
            out.append(UInt8(s[i..<j], radix: 16)!)
            i = j
        }
        return out
    }

    let codec = SolarmanV5Codec(loggerSerial: 2712345678)

    func testModbusReadRequest() {
        XCTAssertEqual(ModbusRTU.readHoldingRequest(slave: 1, address: 0, count: 91), hex("01030000005b0431"))
    }

    func testModbusWriteMultipleRequest() {
        XCTAssertEqual(ModbusRTU.writeMultipleRequest(slave: 1, address: 40, values: [500]), hex("0110002800010201f4a06f"))
    }

    func testV5ReadFrameMatchesPySolarman() {
        let mb = ModbusRTU.readHoldingRequest(slave: 1, address: 0, count: 91)
        XCTAssertEqual(codec.encode(modbus: mb, sequence: 0x42),
                       hex("a51700104542004e1caba102000000000000000000000000000001030000005b0431fa15"))
    }

    func testV5WriteFrameMatchesPySolarman() {
        let mb = ModbusRTU.writeMultipleRequest(slave: 1, address: 40, values: [500])
        XCTAssertEqual(codec.encode(modbus: mb, sequence: 0x42),
                       hex("a51a00104542004e1caba10200000000000000000000000000000110002800010201f4a06fa915"))
    }

    func testDecodeResponse() throws {
        let frame = hex("a52300101542004e1caba102010000000000000000000000000103100178006801810068017600690180006916040615")
        let mb = try XCTUnwrap(codec.decode(frame, expectedSequence: 0x42))
        let regs = try ModbusRTU.parseReadResponse(mb, count: 8)
        XCTAssertEqual(regs, [376, 104, 385, 104, 374, 105, 384, 105])
    }

    func testIgnoresOtherSequence() throws {
        let frame = hex("a52300101542004e1caba102010000000000000000000000000103100178006801810068017600690180006916040615")
        XCTAssertNil(try codec.decode(frame, expectedSequence: 0x43))
    }

    func testWrongSerialIsReported() {
        let other = SolarmanV5Codec(loggerSerial: 1)
        let frame = hex("a52300101542004e1caba102010000000000000000000000000103100178006801810068017600690180006916040615")
        XCTAssertThrowsError(try other.decode(frame, expectedSequence: 0x42))
    }

    func testExtractFrameFromSplitAndJoinedStream() {
        let f = hex("a52300101542004e1caba102010000000000000000000000000103100178006801810068017600690180006916040615")
        var buffer: [UInt8] = [0x00, 0x11] + Array(f[0..<10])
        XCTAssertNil(SolarmanV5Codec.extractFrame(from: &buffer))
        buffer += Array(f[10...]) + f
        XCTAssertEqual(SolarmanV5Codec.extractFrame(from: &buffer), f)
        XCTAssertEqual(SolarmanV5Codec.extractFrame(from: &buffer), f)
        XCTAssertNil(SolarmanV5Codec.extractFrame(from: &buffer))
    }

    func testModbusExceptionAndDoubleCRC() {
        XCTAssertThrowsError(try ModbusRTU.parseReadResponse([0x01, 0x83, 0x02, 0xC0, 0xF1], count: 1)) { error in
            XCTAssertEqual(error as? ModbusError, .exception(function: 0x03, code: 0x02))
        }
        // Respuesta válida + 2 ceros extra (bug de "doble CRC" de algunos loggers)
        var ok: [UInt8] = [0x01, 0x03, 0x02, 0x03, 0xE8]
        let crc = ModbusRTU.crc16(ok)
        ok += [UInt8(crc & 0xFF), UInt8(crc >> 8), 0x00, 0x00]
        XCTAssertEqual(try ModbusRTU.parseReadResponse(ok, count: 1), [1000])
    }

    func testSnapshotDecoding() {
        var r: [UInt16: UInt16] = [:]
        let sn = Array("2405123456".utf8)
        for i in 0..<5 { r[3 + UInt16(i)] = UInt16(sn[2 * i]) << 8 | UInt16(sn[2 * i + 1]) }
        r[16] = 20000; r[17] = 0
        r[18] = 0x0401
        r[40] = 1000
        r[43] = 1
        r[59] = 2
        r[60] = 52
        r[63] = 0x2345; r[64] = 0x0001        // 74565 -> 7456.5 kWh
        r[73] = 2301
        r[76] = UInt16(bitPattern: -25)       // -2.5 A
        r[79] = 5001
        r[86] = 15234; r[87] = 0              // 1523.4 W
        r[90] = 5150                          // 41.5 °C
        r[103] = 1 << 8                       // sobrecorriente red
        for i in 0..<4 { r[109 + UInt16(2 * i)] = 380; r[110 + UInt16(2 * i)] = 100 }

        let s = MicroSnapshot(registers: r)
        XCTAssertEqual(s.inverterSerial, "2405123456")
        XCTAssertEqual(s.ratedPower, 2000, accuracy: 0.01)
        XCTAssertEqual(s.mpptCount, 4)
        XCTAssertEqual(s.state, .normal)
        XCTAssertTrue(s.isOn)
        XCTAssertEqual(s.totalEnergy, 7456.5, accuracy: 0.01)
        XCTAssertEqual(s.todayEnergy, 5.2, accuracy: 0.01)
        XCTAssertEqual(s.acPower, 1523.4, accuracy: 0.01)
        XCTAssertEqual(s.gridCurrent, -2.5, accuracy: 0.01)
        XCTAssertEqual(s.gridFrequency, 50.01, accuracy: 0.001)
        XCTAssertEqual(s.temperature, 41.5, accuracy: 0.01)
        XCTAssertEqual(s.pv.count, 4)
        XCTAssertEqual(s.dcPower, 4 * 38.0 * 10.0, accuracy: 0.01)
        XCTAssertEqual(s.activeFaults, ["Sobrecorriente red"])
        XCTAssertEqual(s.effectiveScale(.auto), .tenths)
        XCTAssertEqual(s.powerLimitPercent(.auto), 100, accuracy: 0.01)
        XCTAssertEqual(MicroSnapshot.rawLimit(percent: 50, scale: .tenths), 500)
        XCTAssertEqual(MicroSnapshot.rawLimit(percent: 50, scale: .percent), 50)
    }
}
