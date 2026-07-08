import XCTest
@testable import DDRCore

final class CfgParamGeometryTests: XCTestCase {

    // 用真实 cfg 的 forceinit params 构造 CfgItem 的辅助
    private func item(dieEnum: String, busEnum: String) -> CfgItem {
        let params = [
            CfgParameter(index: 0, section: "PARAM_02", name: "cs0_bit_width",
                         inputType: .combo, value: busEnum, unit: "",
                         inputRange: nil, inputRangeName: nil, inputRangeValue: nil),
            CfgParameter(index: 1, section: "PARAM_03", name: "cs0_die_bit_width",
                         inputType: .combo, value: dieEnum, unit: "",
                         inputRange: nil, inputRangeName: nil, inputRangeValue: nil),
        ]
        return CfgItem(name: "forceinit", pathHint: nil, nameOffset: 0,
                       payloadOffset: 0, payloadLength: 0, paramAddress: nil, params: params)
    }

    func testDieWidthEnumMapping() {
        // 1→×8, 2→×16, 3→×32
        XCTAssertEqual(CfgParamGeometry.widthKey(fromForceinit: item(dieEnum: "1", busEnum: "1"))?.dieWidthBits, 8)
        XCTAssertEqual(CfgParamGeometry.widthKey(fromForceinit: item(dieEnum: "2", busEnum: "1"))?.dieWidthBits, 16)
        XCTAssertEqual(CfgParamGeometry.widthKey(fromForceinit: item(dieEnum: "3", busEnum: "1"))?.dieWidthBits, 32)
    }

    func testBusWidthEnumMapping() {
        // 1→16-bit, 2→32-bit
        XCTAssertEqual(CfgParamGeometry.widthKey(fromForceinit: item(dieEnum: "2", busEnum: "1"))?.busWidthBits, 16)
        XCTAssertEqual(CfgParamGeometry.widthKey(fromForceinit: item(dieEnum: "2", busEnum: "2"))?.busWidthBits, 32)
    }

    func testMissingParamsYieldNil() {
        // RK3288 cha/chb schema 没有 cs0_* → nil（本轮不支持，回退手动）
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
}
