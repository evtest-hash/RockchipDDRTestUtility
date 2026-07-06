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
        XCTAssertEqual(p.detectCfgName, "DDR自动探测.cfg")
    }
    func testRK3588Profile() throws {
        let p = try XCTUnwrap(DetectProfiles.forPID(0x350B))
        XCTAssertEqual(p.soc, "RK3588")
        XCTAssertEqual(p.downloadBase, 0xFF00_4000)
        XCTAssertEqual(p.usbPutsVector, 0xFF00_1004)
        XCTAssertEqual(p.osRegBase, 0xFD58_A200)
        XCTAssertEqual(p.bootModeReg, 0xFD58_A200)
        XCTAssertEqual(p.maskromMagic, 0xEF08_A53C)
        XCTAssertEqual(p.cruResetReg, 0xFD7C_0C08)
        XCTAssertEqual(p.cruResetValue, 0x0000_FDB9)
        XCTAssertEqual(p.detectCfgName, "DDR自动探测.cfg")
    }
    func testRK3576Profile() throws {
        let p = try XCTUnwrap(DetectProfiles.forPID(0x350E))
        XCTAssertEqual(p.soc, "RK3576")
        XCTAssertEqual(p.downloadBase, 0x3FF8_4000)
        XCTAssertEqual(p.usbPutsVector, 0x3FF8_1004)
        XCTAssertEqual(p.osRegBase, 0x2602_6200)
        XCTAssertEqual(p.bootModeReg, 0x2602_6200)
        XCTAssertEqual(p.maskromMagic, 0xEF08_A53C)
        XCTAssertEqual(p.cruResetReg, 0x2720_0C08)
        XCTAssertEqual(p.cruResetValue, 0x0000_FDB9)
        XCTAssertEqual(p.detectCfgName, "DDR自动探测.cfg")
    }
    func testUnsupportedPIDReturnsNil() {
        XCTAssertNil(DetectProfiles.forPID(0x350C))   // RK3562 not configured yet
    }
}
