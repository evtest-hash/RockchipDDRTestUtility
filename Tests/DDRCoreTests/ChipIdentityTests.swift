import DDRCore
import XCTest

final class ChipIdentityTests: XCTestCase {

    /// Captured from a real RK3576 in maskrom. The board was then flashed and
    /// reported 2aacddcd9cd362b3 as its device tree serial-number, /proc/cpuinfo
    /// Serial, USB gadget serial and adb serial.
    ///
    /// v1 framing: the words after OTP_ALIVE are the dump itself, and only the
    /// caller knows which OTP byte it starts at (here 0x08).
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
        let dump = try XCTUnwrap(ChipIdentity.parseOtpDump(rk3576Capture, fallbackBaseByte: 0x08))
        let cpuid = try XCTUnwrap(dump.slice(at: 0x0A, count: ChipIdentity.cpuidLength))
        XCTAssertEqual(ChipIdentity.hex(cpuid), "4e59364b4800000000000000000c1e24")
    }

    func testDerivesSerialMatchingUBoot() throws {
        let dump = try XCTUnwrap(ChipIdentity.parseOtpDump(rk3576Capture, fallbackBaseByte: 0x08))
        let cpuid = try XCTUnwrap(dump.slice(at: 0x0A, count: ChipIdentity.cpuidLength))
        XCTAssertEqual(ChipIdentity.serial(fromCpuid: cpuid), "2aacddcd9cd362b3")
    }

    func testDiagnosticWordsBeforeAliveAreNotPartOfTheDump() throws {
        // Starting at the three pre-OTP_ALIVE zero words would give an all-zero
        // CPUID; anchoring on the marker is what keeps them out.
        let dump = try XCTUnwrap(ChipIdentity.parseOtpDump(rk3576Capture, fallbackBaseByte: 0x08))
        XCTAssertEqual(dump.baseByte, 0x08)
        XCTAssertNotEqual(dump.slice(at: 0x0A, count: 16), [UInt8](repeating: 0, count: 16))
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
        let dump = try XCTUnwrap(ChipIdentity.parseOtpDump(rk3566Capture, fallbackBaseByte: 0x0A))
        let cpuid = try XCTUnwrap(dump.slice(at: 0x0A, count: ChipIdentity.cpuidLength))
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

    // MARK: - v2 framing (self-describing base)

    /// v2 probes print OTP_DUMP followed by the OTP byte offset their first data
    /// word starts at. An app paired with a stale cfg then reads the dump at the
    /// offset the payload actually used, instead of the one it assumed.
    private let selfDescribingCapture = """
        OTP_BEGIN
        00000000
        GATE_OK
        00000000
        OTP_ALIVE
        OTP_DUMP
        00000004
        594e0101
        00484b36
        OTP_END
        """

    func testSelfDescribingDumpTakesBaseFromTheProbe() throws {
        let dump = try XCTUnwrap(ChipIdentity.parseOtpDump(selfDescribingCapture, fallbackBaseByte: 0x08))
        XCTAssertEqual(dump.baseByte, 0x04)          // the probe's word wins over the fallback
        XCTAssertEqual(dump.byte(at: 0x04), 0x01)
        XCTAssertEqual(dump.byte(at: 0x0B), 0x00)
        XCTAssertEqual(dump.bytes.count, 8)
    }

    func testSelfDescribingDumpNeedsNoFallback() throws {
        let dump = try XCTUnwrap(ChipIdentity.parseOtpDump(selfDescribingCapture, fallbackBaseByte: nil))
        XCTAssertEqual(dump.baseByte, 0x04)
    }

    func testLegacyDumpWithoutFallbackYieldsNothing() {
        // No self-describing base and no caller-supplied one: refuse rather than
        // guess, because a wrong base silently yields a wrong serial.
        XCTAssertNil(ChipIdentity.parseOtpDump(rk3576Capture, fallbackBaseByte: nil))
    }

    func testBytesOutsideTheDumpAreUnavailable() throws {
        let dump = try XCTUnwrap(ChipIdentity.parseOtpDump(rk3576Capture, fallbackBaseByte: 0x08))
        XCTAssertNil(dump.byte(at: 0x07))            // before the dump
        XCTAssertNil(dump.byte(at: 0x08 + 20))       // past its end
        XCTAssertNil(dump.slice(at: 0x18, count: 16))
    }

    // MARK: - failure modes

    func testTimeoutYieldsNoDump() {
        let text = "OTP_BEGIN\n00000000\nGATE_OK\n00000000\nOTP_ALIVE\nOTP_TIMEOUT\n"
        XCTAssertNil(ChipIdentity.parseOtpDump(text, fallbackBaseByte: 0x08))
    }

    func testTruncatedCaptureYieldsNoCpuid() throws {
        let text = "OTP_BEGIN\n00000000\nGATE_OK\n00000000\nOTP_ALIVE\n594e0101\n"
        let dump = try XCTUnwrap(ChipIdentity.parseOtpDump(text, fallbackBaseByte: 0x08))
        XCTAssertNil(dump.slice(at: 0x0A, count: ChipIdentity.cpuidLength))
    }

    func testMissingMarkerYieldsNoDump() {
        XCTAssertNil(ChipIdentity.parseOtpDump("594e0101 00484b36", fallbackBaseByte: 0x08))
    }

    func testSerialRejectsWrongLength() {
        XCTAssertNil(ChipIdentity.serial(fromCpuid: [1, 2, 3]))
    }
}
