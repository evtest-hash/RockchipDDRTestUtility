import DDRCore
import XCTest

final class ChipIdentityTests: XCTestCase {

    /// Captured from a real RK3576 in maskrom. The board was then flashed and
    /// reported 2aacddcd9cd362b3 as its device tree serial-number, /proc/cpuinfo
    /// Serial, USB gadget serial and adb serial.
    private let rk3576Capture = """
        OTP_BEGIN
        00000000
        00000000
        GATE_OK
        00000000
        OTP_ALIVE
        594e0101
        00484b36
        00000000
        0c000000
        0000241e
        OTP_END
        """

    func testParsesCpuidFromProbeOutput() throws {
        let cpuid = try XCTUnwrap(ChipIdentity.parseOtpProbeOutput(rk3576Capture, cpuidByteOffset: 2))
        XCTAssertEqual(ChipIdentity.hex(cpuid), "4e59364b4800000000000000000c1e24")
    }

    func testDerivesSerialMatchingUBoot() throws {
        let cpuid = try XCTUnwrap(ChipIdentity.parseOtpProbeOutput(rk3576Capture, cpuidByteOffset: 2))
        XCTAssertEqual(ChipIdentity.serial(fromCpuid: cpuid), "2aacddcd9cd362b3")
    }

    func testDiagnosticWordsBeforeAliveAreNotCpuid() throws {
        // Offset 2 into the three pre-OTP_ALIVE zero words would give an all-zero
        // CPUID; anchoring on the marker is what keeps them out.
        let cpuid = try XCTUnwrap(ChipIdentity.parseOtpProbeOutput(rk3576Capture, cpuidByteOffset: 2))
        XCTAssertNotEqual(cpuid, [UInt8](repeating: 0, count: 16))
    }

    /// RK3566 via the SBPI controller: reads are 2 bytes wide and the probe packs
    /// each pair into one word, so a byte-order slip here changes the serial.
    /// Captured in maskrom; the flashed board reported 587dc6a514453616.
    private let rk3566Capture = """
        OTP_BEGIN
        00000000
        00000000
        00000000
        00000000
        00000000
        00000000
        GATE_OK
        00000001
        OTP_ALIVE
        374e344d
        00003331
        00000000
        191b0e00
        OTP_END
        """

    func testSbpiControllerCaptureDerivesSerial() throws {
        let cpuid = try XCTUnwrap(ChipIdentity.parseOtpProbeOutput(rk3566Capture, cpuidByteOffset: 0))
        XCTAssertEqual(ChipIdentity.hex(cpuid), "4d344e373133000000000000000e1b19")
        XCTAssertEqual(ChipIdentity.serial(fromCpuid: cpuid), "587dc6a514453616")
    }

    /// RK3588 reads the CPUID at CFG_CPUID_OFFSET 0x7 rather than the 0xa the
    /// other SoCs override it to. Its flashed board reported 34376b2c031e323e.
    func testRK3588CpuidDerivesSerial() {
        let cpuid: [UInt8] = [0x41, 0x33, 0x31, 0x59, 0x58, 0, 0, 0,
                              0, 0, 0, 0, 0, 0x14, 0x02, 0x0f]
        XCTAssertEqual(ChipIdentity.hex(cpuid), "4133315958000000000000000014020f")
        XCTAssertEqual(ChipIdentity.serial(fromCpuid: cpuid), "34376b2c031e323e")
    }

    func testTimeoutYieldsNoIdentity() {
        let text = "OTP_BEGIN\n00000000\nGATE_OK\n00000000\nOTP_ALIVE\nOTP_TIMEOUT\n"
        XCTAssertNil(ChipIdentity.parseOtpProbeOutput(text, cpuidByteOffset: 2))
    }

    func testTruncatedCaptureYieldsNoIdentity() {
        let text = "OTP_BEGIN\n00000000\nGATE_OK\n00000000\nOTP_ALIVE\n594e0101\n"
        XCTAssertNil(ChipIdentity.parseOtpProbeOutput(text, cpuidByteOffset: 2))
    }

    func testMissingMarkerYieldsNoIdentity() {
        XCTAssertNil(ChipIdentity.parseOtpProbeOutput("594e0101 00484b36", cpuidByteOffset: 2))
    }

    func testSerialRejectsWrongLength() {
        XCTAssertNil(ChipIdentity.serial(fromCpuid: [1, 2, 3]))
    }
}
