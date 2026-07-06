import XCTest
@testable import DDRCore

final class DetectCfgTests: XCTestCase {
    /// The detect cfg is a self-contained PACKAGING container: it carries all
    /// four payloads the detect flow needs — Boot + ddrbin + osregdump + reboot.
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
        XCTAssertTrue(names.contains("reboot"))
        XCTAssertEqual(names.count, 4)
    }

    /// Every packaged payload must round-trip out of the cfg non-empty (Boot raw,
    /// the rest RC4-decrypted by the parser). The rkbin DDR bin is the largest.
    func testDetectCfgPayloadsNonEmpty() throws {
        let path = FileManager.default.currentDirectoryPath + "/DDRTestFiles/RK3568&RK3566/DDR自动探测.cfg"
        try XCTSkipUnless(FileManager.default.fileExists(atPath: path))
        let plan = try CfgBinaryParser().parse(url: URL(fileURLWithPath: path))
        for name in ["Boot", "ddrbin", "osregdump", "reboot"] {
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
        XCTAssertEqual(names.count, 4)
        for name in ["Boot", "ddrbin", "osregdump", "reboot"] {
            let bin = plan.embeddedBins.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
            XCTAssertGreaterThan(bin?.count ?? 0, 0, "empty/missing payload \(name)")
        }
    }

    /// RK3576 detect cfg: same 4-payload packaging, item download base 0x3FF84000.
    func testRK3576DetectCfgPackagesAllPayloads() throws {
        let path = FileManager.default.currentDirectoryPath + "/DDRTestFiles/RK3576/DDR自动探测.cfg"
        try XCTSkipUnless(FileManager.default.fileExists(atPath: path))
        let plan = try CfgBinaryParser().parse(url: URL(fileURLWithPath: path))
        XCTAssertEqual(plan.downloadBaseAddress, 0x3FF8_4000)
        let names = plan.items.map { $0.name.lowercased() }
        XCTAssertEqual(names.count, 4)
        for name in ["Boot", "ddrbin", "osregdump", "reboot"] {
            let bin = plan.embeddedBins.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
            XCTAssertGreaterThan(bin?.count ?? 0, 0, "empty/missing payload \(name)")
        }
    }
}
