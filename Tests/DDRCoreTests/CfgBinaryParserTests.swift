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

        // forceinit carries the single parameter block (Family A: global params).
        let forceinit = plan.items.first { $0.name == "forceinit" }
        XCTAssertNotNil(forceinit)
        XCTAssertEqual(forceinit?.params.count, 38)
        XCTAssertNotNil(forceinit?.paramAddress)
        // Boot and connect should have no params of their own.
        let boot = plan.items.first { $0.name == "Boot" }
        let connect = plan.items.first { $0.name == "connect" }
        XCTAssertEqual(boot?.params.count, 0)
        XCTAssertNil(boot?.paramAddress)
        XCTAssertEqual(connect?.params.count, 0)
        XCTAssertNil(connect?.paramAddress)

        XCTAssertNotNil(plan.address)
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
        // Params are mapped per-item by name. Init always receives its block.
        let initItem = plan.items.first { $0.name.range(of: "init", options: .caseInsensitive) != nil }
        XCTAssertNotNil(initItem)
        XCTAssertGreaterThan(initItem?.params.count ?? 0, 2, "Init item should get its parameter block")
        XCTAssertNotNil(plan.address)
    }

    /// Capture-golden test, mirrored from a Windows DDR_UserTool run on RK3288
    /// (board-stability 528 MHz). The USB capture showed exactly:
    ///   Init        <- block0 (5 controller params: Driver/ODT, values b,6,0,4,0)
    ///   ChangeFreq  <- block1 (1 param `Freq`, value 0x210 = 528)
    ///   memTest     <- block2 (21 test params incl. Write/Read Freq = 0x210)
    ///   DiagonalScan, CrossTalk <- no parameter download
    /// This pins the parser's per-item block mapping against measured behavior.
    func testRK3288BoardStabilityCaptureMapping() throws {
        let path = fixturePath(
            soc: "RK3288",
            fileName: "DDR3、LPDDR2、LPDDR3布板稳定性测试528MHz.cfg"
        )
        let plan = try parser.parse(url: URL(fileURLWithPath: path))
        let byName = Dictionary(plan.items.map { ($0.name.lowercased(), $0) }, uniquingKeysWith: { a, _ in a })

        let initItem = byName["init"]
        XCTAssertEqual(initItem?.params.count, 5, "Init must get block0's 5 controller params")
        XCTAssertTrue(initItem?.params.contains(where: { $0.name.contains("Driver") || $0.name.contains("ODT") }) ?? false)

        let changeFreq = byName["changefreq"]
        XCTAssertEqual(changeFreq?.params.count, 1, "ChangeFreq must get block1's single Freq param")
        XCTAssertEqual(changeFreq?.params.first?.value, "528", "Freq param should be 528 (= 0x210 in the capture)")

        let memTest = byName["memtest"]
        XCTAssertEqual(memTest?.params.count, 21, "memTest must get block2's 21 test params")

        XCTAssertEqual(byName["diagonalscan"]?.params.count, 0, "DiagonalScan takes no params")
        XCTAssertEqual(byName["crosstalk"]?.params.count, 0, "CrossTalk takes no params")
    }

    func testRK3036ConfigParsing() throws {
        let path = fixturePath(
            soc: "RK3036",
            fileName: "DDR3 休眠专项测试.cfg"
        )
        let plan = try parser.parse(url: URL(fileURLWithPath: path))

        XCTAssertEqual(plan.items.first?.name, "Boot")
        XCTAssertTrue(plan.items.contains(where: { $0.name == "Suspend" }))
        // Params are mapped per-item by content. The TEST_TYPE/Freq/SR_Time
        // blocks are test-config: Init takes the first, SR_Test (the self-
        // refresh test) takes the second — so SR_Test gets its own SR_Time.
        let initItem = plan.items.first { $0.name.range(of: "init", options: .caseInsensitive) != nil }
        XCTAssertNotNil(initItem, "Should have an Init item to receive params")
        XCTAssertGreaterThanOrEqual(initItem?.params.count ?? 0, 4, "Init item should receive its config block")
        let srTest = plan.items.first { $0.name == "SR_Test" }
        XCTAssertEqual(srTest?.params.count, 4, "SR_Test should receive the test-config block (SR_Time)")
        XCTAssertNotNil(plan.address)
    }

    func testRK3588CapturedCfgPayloads() throws {
        let path = repoRoot().appendingPathComponent("DDRTestFiles/RK3588/8GB LPDDR4X(2pcs x 2CS x 16Gb)soldering check.cfg").path

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

    /// Regression guard for the duplicate-`[PARAM_xx]` collision bug.
    ///
    /// Family B cfgs carry several `[ADDRESS]+[PARAM_xx]` blocks at the file
    /// tail — every block reuses `[PARAM_01..NN]`. When the parser treated the
    /// whole INI as one document, IniParser (keyed by section name) let later
    /// blocks overwrite earlier ones, so the init item inherited the LAST
    /// block's test-tuning params instead of the FIRST block's DDR-controller
    /// params. That mis-configured the controller and broke the whole test run.
    ///
    /// After segmentation, init must receive exactly block[0] (the controller
    /// config: Driver/ODT) at the cfg's param address.
    func testFamilyBInitGetsControllerParamBlock() throws {
        let path = fixturePath(
            soc: "RK3288",
            fileName: "DDR3、LPDDR2、LPDDR3颗粒专项测试324MHz.cfg"
        )
        let plan = try parser.parse(url: URL(fileURLWithPath: path))

        let initItem = plan.items.first { $0.name.range(of: "init", options: .caseInsensitive) != nil }
        XCTAssertNotNil(initItem, "Family B cfg should have an Init item")

        let paramNames = initItem?.params.map { $0.name } ?? []
        XCTAssertEqual(initItem?.params.count, 5, "Init should get exactly block[0]'s 5 controller params; got \(paramNames)")
        XCTAssertTrue(
            paramNames.contains(where: { $0.contains("Driver") || $0.contains("ODT") }),
            "Init params should be DDR controller config (Driver/ODT); got \(paramNames)"
        )
        XCTAssertFalse(
            paramNames.contains(where: { $0.contains("Test Size") || $0.contains("Mem Test Loop") }),
            "Init must not receive the last block's test-tuning params; got \(paramNames)"
        )
        XCTAssertEqual(initItem?.paramAddress, 0xFFFF1480)
    }

    private func fixturePath(soc: String, fileName: String) -> String {
        return repoRoot().appendingPathComponent("DDRTestFiles/\(soc)/\(fileName)").path
    }

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #file)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }
}
