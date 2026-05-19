import DDRCore
import XCTest

final class CfgBinaryParserTests: XCTestCase {
    private let parser = CfgBinaryParser()

    func testRK3588ConfigParsing() throws {
        let path = fixturePath(
            soc: "RK3588",
            fileName: "16GB LPDDR5(用2片颗粒 每片颗粒2个CS 每个CS有32Gb).cfg"
        )
        let plan = try parser.parse(url: URL(fileURLWithPath: path))

        XCTAssertFalse(plan.items.isEmpty)
        XCTAssertEqual(plan.items.first?.name, "Boot")
        XCTAssertEqual(plan.items.map(\.name), ["Boot", "forceinit", "connect"])
        XCTAssertNotNil(plan.address)
        XCTAssertGreaterThan(plan.params.count, 20)
        XCTAssertFalse(plan.embeddedBins.isEmpty)
        XCTAssertGreaterThan(plan.downloadBaseAddress, 0)
    }

    func testRK3368ConfigParsing() throws {
        let path = fixturePath(
            soc: "RK3368",
            fileName: "DDR3 LPDDR3 400MHz颗粒简单测试.cfg"
        )
        let plan = try parser.parse(url: URL(fileURLWithPath: path))

        XCTAssertEqual(plan.items.first?.name, "Boot")
        XCTAssertTrue(plan.items.contains(where: { $0.name == "MemTest" }))
        XCTAssertNotNil(plan.address)
        XCTAssertGreaterThan(plan.params.count, 15)
    }

    func testRK3036ConfigParsing() throws {
        let path = fixturePath(
            soc: "RK3036",
            fileName: "DDR3 休眠专项测试.cfg"
        )
        let plan = try parser.parse(url: URL(fileURLWithPath: path))

        XCTAssertEqual(plan.items.first?.name, "Boot")
        XCTAssertTrue(plan.items.contains(where: { $0.name == "Suspend" }))
        XCTAssertNotNil(plan.address)
        XCTAssertGreaterThanOrEqual(plan.params.count, 4)
    }

    func testRK3588CapturedCfgPayloads() throws {
        let base = ProcessInfo.processInfo.environment["DDR_USERTOOL_ROOT"]
            ?? "/Users/kevin.zhuang/DDR_UserTool/DDR_UserTool_v1.41"
        let path = "\(base)/TestFile/RK3588/8GB LPDDR4X(2pcs x 2CS x 16Gb)soldering check.cfg"

        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("Captured RK3588 cfg fixture not found: \(path)")
        }

        let plan = try parser.parse(url: URL(fileURLWithPath: path))
        let itemMap = Dictionary(uniqueKeysWithValues: plan.items.map { ($0.name.lowercased(), $0) })

        XCTAssertEqual(itemMap["boot"]?.payloadOffset, 0x894)
        XCTAssertEqual(itemMap["forceinit"]?.payloadLength, 60328)
        XCTAssertEqual(itemMap["connect"]?.payloadLength, 65848)

        let bootBinSize = plan.embeddedBins["Boot"]?.count ?? 0
        let bootSpan = itemMap["boot"]?.payloadLength ?? 0
        XCTAssertGreaterThanOrEqual(bootBinSize, bootSpan)
        XCTAssertEqual(plan.embeddedBins["forceinit"]?.count, itemMap["forceinit"]?.payloadLength)
        XCTAssertEqual(plan.embeddedBins["connect"]?.count, itemMap["connect"]?.payloadLength)

        XCTAssertGreaterThan(plan.downloadBaseAddress, 0)
    }

    private func fixturePath(soc: String, fileName: String) -> String {
        let base = ProcessInfo.processInfo.environment["DDR_USERTOOL_ROOT"]
            ?? "/Users/kevin.zhuang/DDR_UserTool/DDR_UserTool_v1.41"
        return "\(base)/TestFiles/\(soc)/\(fileName)"
    }
}
