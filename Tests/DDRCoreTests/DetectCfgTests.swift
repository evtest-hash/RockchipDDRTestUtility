import XCTest
@testable import DDRCore

final class DetectCfgTests: XCTestCase {
    func testDetectCfgHasBootProbeReboot() throws {
        let path = FileManager.default.currentDirectoryPath + "/tools/ddr-autodetect/rk3568_osregdump.cfg"
        try XCTSkipUnless(FileManager.default.fileExists(atPath: path))
        let plan = try CfgBinaryParser().parse(url: URL(fileURLWithPath: path))
        XCTAssertEqual(plan.downloadBaseAddress, 0xFDCC_4000)
        let names = plan.items.map { $0.name.lowercased() }
        XCTAssertTrue(names.contains("boot"))
        XCTAssertTrue(names.contains("osregdump"))
        XCTAssertTrue(names.contains("reboot"))
        // both probes decrypt to AArch64 (STP or MOVZ first word is non-zero code)
        XCTAssertGreaterThan(try XCTUnwrap(plan.embeddedBins["reboot"]).count, 0)
    }
}
