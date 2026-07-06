// Tests/DDRCoreTests/DetectProfileTests.swift
import XCTest
@testable import DDRCore

final class DetectProfileTests: XCTestCase {
    func testRK3568Profile() throws {
        let p = try XCTUnwrap(DetectProfiles.forPID(0x350A))
        XCTAssertEqual(p.soc, "RK3568&RK3566")
        XCTAssertEqual(p.downloadBase, 0xFDCC_4000)
        XCTAssertEqual(p.usbPutsVector, 0xFDCC_1004)
        XCTAssertEqual(p.osRegBase, 0xFDC2_0200)
        XCTAssertEqual(p.bootModeReg, 0xFDC2_0200)
        XCTAssertEqual(p.maskromMagic, 0xEF08_A53C)
        XCTAssertEqual(p.ddrBinName, "rk3568_ddr_1560MHz_v1.25.bin")
        XCTAssertEqual(p.detectCfgName, "rk3568_osregdump.cfg")
        XCTAssertEqual(p.rebootBinName, "rk3568_reboot.bin")
    }
    func testUnsupportedPIDReturnsNil() {
        XCTAssertNil(DetectProfiles.forPID(0x350B))   // RK3588 not configured yet
    }
}
