import XCTest
@testable import DDRCore

final class DetectCfgTests: XCTestCase {
    /// The detect cfg is a self-contained PACKAGING container: it carries every
    /// payload the detect flow needs — Boot + ddrbin + osregdump + otpdump + reboot.
    /// DdrDetector pulls each out of embeddedBins and drives the sequence itself
    /// (it never runs the cfg through TestExecutionEngine), so embedding reboot
    /// here is safe: the detector runs it explicitly, after OS_REG capture.
    func testDetectCfgPackagesAllPayloads() throws {
        let path = FileManager.default.currentDirectoryPath + "/DDRTestFiles/RK3568&RK3566/DDR自动探测.cfg"
        try XCTSkipUnless(FileManager.default.fileExists(atPath: path))
        let plan = try CfgBinaryParser().parse(url: URL(fileURLWithPath: path))
        XCTAssertEqual(plan.downloadBaseAddress, 0xFDCC_4000)
        let names = plan.items.map { $0.name.lowercased() }
        XCTAssertTrue(names.contains("boot"))
        XCTAssertTrue(names.contains("ddrbin"))
        XCTAssertTrue(names.contains("osregdump"))
        XCTAssertTrue(names.contains("otpdump"))
        XCTAssertTrue(names.contains("reboot"))
        XCTAssertEqual(names.count, 5)
    }

    /// Every packaged payload must round-trip out of the cfg non-empty (Boot raw,
    /// the rest RC4-decrypted by the parser). The rkbin DDR bin is the largest.
    func testDetectCfgPayloadsNonEmpty() throws {
        let path = FileManager.default.currentDirectoryPath + "/DDRTestFiles/RK3568&RK3566/DDR自动探测.cfg"
        try XCTSkipUnless(FileManager.default.fileExists(atPath: path))
        let plan = try CfgBinaryParser().parse(url: URL(fileURLWithPath: path))
        for name in ["Boot", "ddrbin", "osregdump", "otpdump", "reboot"] {
            let bin = plan.embeddedBins.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
            XCTAssertNotNil(bin, "missing payload \(name)")
            XCTAssertGreaterThan(bin?.count ?? 0, 0, "empty payload \(name)")
        }
        let ddrbin = plan.embeddedBins.first { $0.key.caseInsensitiveCompare("ddrbin") == .orderedSame }?.value
        XCTAssertGreaterThan(ddrbin?.count ?? 0, 10_000)
    }

    /// RK3588's detect cfg is built the same way (build.sh) with RK3588 addresses
    /// and packages all four payloads; its item download base is 0xFF004000.
    func testRK3588DetectCfgPackagesAllPayloads() throws {
        let path = FileManager.default.currentDirectoryPath + "/DDRTestFiles/RK3588/DDR自动探测.cfg"
        try XCTSkipUnless(FileManager.default.fileExists(atPath: path))
        let plan = try CfgBinaryParser().parse(url: URL(fileURLWithPath: path))
        XCTAssertEqual(plan.downloadBaseAddress, 0xFF00_4000)
        let names = plan.items.map { $0.name.lowercased() }
        XCTAssertEqual(names.count, 5)
        for name in ["Boot", "ddrbin", "osregdump", "otpdump", "reboot"] {
            let bin = plan.embeddedBins.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
            XCTAssertGreaterThan(bin?.count ?? 0, 0, "empty/missing payload \(name)")
        }
    }

    /// RK3576 detect cfg: 5 payloads (otpdump for the CPUID), item base 0x3FF84000.
    func testRK3576DetectCfgPackagesAllPayloads() throws {
        let path = FileManager.default.currentDirectoryPath + "/DDRTestFiles/RK3576/DDR自动探测.cfg"
        try XCTSkipUnless(FileManager.default.fileExists(atPath: path))
        let plan = try CfgBinaryParser().parse(url: URL(fileURLWithPath: path))
        XCTAssertEqual(plan.downloadBaseAddress, 0x3FF8_4000)
        let names = plan.items.map { $0.name.lowercased() }
        XCTAssertEqual(names.count, 5)
        for name in ["Boot", "ddrbin", "osregdump", "otpdump", "reboot"] {
            let bin = plan.embeddedBins.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
            XCTAssertGreaterThan(bin?.count ?? 0, 0, "empty/missing payload \(name)")
        }
    }
    /// The shipped otpdump payloads must speak the SELF-DESCRIBING framing: the
    /// probe prints OTP_DUMP + the OTP byte offset its dump starts at, and the app
    /// reads the dump at THAT offset. A cfg rebuilt without the marker would fall
    /// back to `IdProbe.legacyBaseByte`, silently misplacing every OTP field —
    /// including the CPUID, which would still look like a valid serial.
    func testShippedOtpProbesAnnounceTheirDumpBase() throws {
        for soc in ["RK3588", "RK3576", "RK3568&RK3566"] {
            let path = FileManager.default.currentDirectoryPath
                + "/DDRTestFiles/\(soc)/DDR自动探测.cfg"
            try XCTSkipUnless(FileManager.default.fileExists(atPath: path))
            let plan = try CfgBinaryParser().parse(url: URL(fileURLWithPath: path))
            let bin = try XCTUnwrap(plan.embeddedBins.first {
                $0.key.caseInsensitiveCompare("otpdump") == .orderedSame
            }?.value, "\(soc): no otpdump payload")
            // The marker is a literal in the payload's string table.
            XCTAssertNotNil(bin.range(of: Data("OTP_DUMP".utf8)),
                            "\(soc): otpdump payload predates the self-describing framing")
        }
    }

    /// Each SoC's probe must dump far enough to cover the CPUID its profile reads.
    /// This is the arithmetic that a moved read-window gets wrong.
    func testProfileCpuidOffsetsMatchTheDocumentedOtpLayout() {
        XCTAssertEqual(DetectProfiles.all[0x350B]?.idProbe?.cpuidOffset, 0x07)   // RK3588: rockchip-common.h default
        XCTAssertEqual(DetectProfiles.all[0x350E]?.idProbe?.cpuidOffset, 0x0A)   // RK3576: rk3576_common.h
        XCTAssertEqual(DetectProfiles.all[0x350A]?.idProbe?.cpuidOffset, 0x0A)   // RK356x
        XCTAssertEqual(DetectProfiles.all[0x350B]?.family, .rk3588)
        XCTAssertEqual(DetectProfiles.all[0x350E]?.family, .rk3576)
        XCTAssertEqual(DetectProfiles.all[0x350A]?.family, .rk356x)
        XCTAssertNil(DetectProfiles.all[0x320A]?.idProbe)                        // RK3288: no identity probe
    }

}
