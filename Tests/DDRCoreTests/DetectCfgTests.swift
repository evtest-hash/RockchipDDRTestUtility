import XCTest
@testable import DDRCore

final class DetectCfgTests: XCTestCase {
    /// The detect cfg must carry ONLY Boot + osregdump. reboot must NOT be a
    /// record in this cfg: TestExecutionEngine.run() executes every non-Boot
    /// item in file order, so an embedded "reboot" record would auto-fire
    /// immediately after osregdump — resetting the device to maskrom before
    /// DdrDetector's OS_REG retry loop / explicit rebootToMaskrom() ever runs.
    /// Reboot instead ships as a standalone raw payload (rk3568_reboot.bin)
    /// that the host loads and runs explicitly, after OS_REG capture.
    func testDetectCfgHasOnlyBootAndProbe() throws {
        let path = FileManager.default.currentDirectoryPath + "/tools/ddr-autodetect/rk3568_osregdump.cfg"
        try XCTSkipUnless(FileManager.default.fileExists(atPath: path))
        let plan = try CfgBinaryParser().parse(url: URL(fileURLWithPath: path))
        XCTAssertEqual(plan.downloadBaseAddress, 0xFDCC_4000)
        let names = plan.items.map { $0.name.lowercased() }
        XCTAssertTrue(names.contains("boot"))
        XCTAssertTrue(names.contains("osregdump"))
        XCTAssertFalse(names.contains("reboot"), "reboot must not be embedded in the detect cfg")
        XCTAssertEqual(names.count, 2)
    }

    func testStandaloneRebootBinExists() throws {
        let path = FileManager.default.currentDirectoryPath + "/tools/ddr-autodetect/rk3568_reboot.bin"
        try XCTSkipUnless(FileManager.default.fileExists(atPath: path))
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        XCTAssertGreaterThan(data.count, 0)
    }
}
