import XCTest
@testable import DDRCore

final class CfgParamGeometryTests: XCTestCase {

    private func item(dieIdx: String, busIdx: String) -> CfgItem {
        let params = [
            CfgParameter(index: 0, section: "PARAM_02", name: "cs0_bit_width",
                         inputType: .combo, value: busIdx, unit: "",
                         inputRange: nil, inputRangeName: "*8|*16|*32", inputRangeValue: "8|16|32"),
            CfgParameter(index: 1, section: "PARAM_03", name: "cs0_die_bit_width",
                         inputType: .combo, value: dieIdx, unit: "",
                         inputRange: nil, inputRangeName: "*4|*8|*16|*32", inputRangeValue: "4|8|16|32"),
        ]
        return CfgItem(name: "forceinit", pathHint: nil, nameOffset: 0,
                       payloadOffset: 0, payloadLength: 0, paramAddress: nil, params: params)
    }

    func testDieWidthComboIndexMapping() {
        // 索引: 0→×4, 1→×8, 2→×16, 3→×32
        XCTAssertEqual(CfgParamGeometry.widthKey(fromForceinit: item(dieIdx: "0", busIdx: "0"))?.dieWidthBits, 4)
        XCTAssertEqual(CfgParamGeometry.widthKey(fromForceinit: item(dieIdx: "1", busIdx: "0"))?.dieWidthBits, 8)
        XCTAssertEqual(CfgParamGeometry.widthKey(fromForceinit: item(dieIdx: "2", busIdx: "0"))?.dieWidthBits, 16)
        XCTAssertEqual(CfgParamGeometry.widthKey(fromForceinit: item(dieIdx: "3", busIdx: "0"))?.dieWidthBits, 32)
    }

    func testBusWidthComboIndexMapping() {
        // 索引: 0→8, 1→16, 2→32
        XCTAssertEqual(CfgParamGeometry.widthKey(fromForceinit: item(dieIdx: "1", busIdx: "0"))?.busWidthBits, 8)
        XCTAssertEqual(CfgParamGeometry.widthKey(fromForceinit: item(dieIdx: "1", busIdx: "1"))?.busWidthBits, 16)
        XCTAssertEqual(CfgParamGeometry.widthKey(fromForceinit: item(dieIdx: "1", busIdx: "2"))?.busWidthBits, 32)
    }

    func testIndexOutOfRangeYieldsNil() {
        XCTAssertNil(CfgParamGeometry.widthKey(fromForceinit: item(dieIdx: "9", busIdx: "0")))
    }

    func testMissingParamsYieldNil() {
        let empty = CfgItem(name: "forceinit", pathHint: nil, nameOffset: 0,
                            payloadOffset: 0, payloadLength: 0, paramAddress: nil, params: [])
        XCTAssertNil(CfgParamGeometry.widthKey(fromForceinit: empty))
    }

    func testDecodedKeyPassthrough() {
        let ch = ChannelGeometry(rank: 2, col: 10, bank: 3, cs0Row: 16, cs1Row: 16,
                                 busWidthBits: 32, dieWidthBits: 16)
        let k = CfgParamGeometry.widthKey(fromDecoded: ch)
        XCTAssertEqual(k.busWidthBits, 32)
        XCTAssertEqual(k.dieWidthBits, 16)
    }

    // 交叉印证：用一个真实 cfg，widthKey 解析出的位宽应等于其文件名/物理事实。
    // 4GB LPDDR4(2CS,每CS 16Gb) 实采 dbw=16 bw=32。
    func testRealCfgResolvesToPhysicalWidth() throws {
        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("DDRTestFiles/RK3568&RK3566")
            .appendingPathComponent("4GB LPDDR4(用2个CS且每个CS为16Gb组成)焊接检测.cfg")
        let plan = try CfgBinaryParser().parse(url: url)
        let fi = try XCTUnwrap(plan.items.first { $0.name == "forceinit" })
        let k = try XCTUnwrap(CfgParamGeometry.widthKey(fromForceinit: fi))
        XCTAssertEqual(k.dieWidthBits, 16)
        XCTAssertEqual(k.busWidthBits, 32)
    }
}
