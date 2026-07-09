import XCTest
@testable import DDRCore

final class CfgAutoSelectTieBreakTests: XCTestCase {

    private let parser = CfgBinaryParser()

    private func repoRoot() -> URL {
        // 测试运行目录为包根；DDRTestFiles 在包根下
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("DDRTestFiles")
    }

    private func forceinit(_ url: URL) -> CfgItem? {
        (try? parser.parse(url: url))?.items.first { $0.name == "forceinit" }
    }

    // 用一个候选自身的 forceinit 参数，合成"理想解码几何"（单通道、位宽取自该 cfg）
    private func idealDecoded(from item: CfgItem) -> DetectedGeometry {
        let k = CfgParamGeometry.widthKey(fromForceinit: item)!
        let ch = ChannelGeometry(rank: 1, col: 10, bank: 3, cs0Row: 15, cs1Row: 13,
                                 busWidthBits: k.busWidthBits, dieWidthBits: k.dieWidthBits)
        return DetectedGeometry(rawOsReg: [], sysRegVersion: 3, dramType: .ddr4,
                                numChannels: 1, channels: [ch], totalSizeMB: 1024)
    }

    private func candidate(_ url: URL, soc: String) -> CfgAutoSelect.Candidate {
        // TestFileEntry.id 派生自 absolutePath（无 id: 参数）。
        let entry = TestFileEntry(absolutePath: url.path,
                                  relativePath: "\(soc)/\(url.lastPathComponent)",
                                  socName: soc, displayName: url.lastPathComponent)
        return CfgAutoSelect.Candidate(entry: entry, dramType: nil, sizeMB: 0, csCount: 0)
    }

    /// 核心证明：对 RK3568 每一个歧义组，用某成员自身参数合成的解码几何，
    /// tieBreak 必须唯一返回它自己。覆盖全部 14 组。
    func testTieBreakResolvesEveryRK3568AmbiguousGroupToSelf() throws {
        let soc = "RK3568&RK3566"
        let dir = repoRoot().appendingPathComponent(soc)
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "cfg" && $0.lastPathComponent.contains("焊接")
                      && !$0.lastPathComponent.contains("自动探测") }

        // 按 (类型, 容量前缀, CS) 分组（与 CfgAutoSelect.rank 的 L1 键一致）
        func keyOf(_ n: String) -> String {
            "\(CfgAutoSelect.dramType(fromFilename: n)?.rawValue ?? -1)|\(CfgAutoSelect.sizeMB(fromFilename: n))|\(CfgAutoSelect.csCount(fromFilename: n))"
        }
        var groups: [String: [URL]] = [:]
        for f in files { groups[keyOf(f.lastPathComponent), default: []].append(f) }
        let ambiguous = groups.values.filter { $0.count > 1 }
        XCTAssertGreaterThanOrEqual(ambiguous.count, 14, "应至少有 14 个歧义组")

        for group in ambiguous {
            let pairs = group.map { (candidate($0, soc: soc), forceinit($0)) }
            for member in group {
                guard let fi = forceinit(member) else {
                    XCTFail("解析 forceinit 失败: \(member.lastPathComponent)"); continue
                }
                let decoded = idealDecoded(from: fi)
                let winners = CfgAutoSelect.tieBreak(pairs.map { (candidate: $0.0, forceinit: $0.1) },
                                                     decoded: decoded)
                XCTAssertEqual(winners.count, 1,
                    "组内应唯一命中: \(member.lastPathComponent) -> \(winners.map { $0.entry.displayName })")
                // entry.id == absolutePath == member.path
                XCTAssertEqual(winners.first?.entry.id, member.path,
                    "应命中它自己: \(member.lastPathComponent)")
            }
        }
    }

    /// 硬件回归：RK3568 实采 (dbw=16,bw=32) 的位宽键，必须等于其对应 cfg
    /// (4GB LPDDR4 2CS 16Gb) 参数换算出的键。验证解码↔cfg 映射在真实数据上一致。
    func testHardwareSampleCrosswalkMatchesCfg() throws {
        let real = OsRegDecoder.decode([0,0,0x1000EAF1,0x30000001,0,0,0,0,
                                        0x34B02204,0x8210A088,0x49068440,0x0040285A])
        let decodedKey = CfgParamGeometry.widthKey(fromDecoded: real.channels[0])
        let url = repoRoot().appendingPathComponent("RK3568&RK3566")
            .appendingPathComponent("4GB LPDDR4(用2个CS且每个CS为16Gb组成)焊接检测.cfg")
        let fi = try XCTUnwrap(forceinit(url))
        let cfgKey = try XCTUnwrap(CfgParamGeometry.widthKey(fromForceinit: fi))
        XCTAssertEqual(decodedKey, cfgKey, "实采位宽键应与 cfg 参数换算键一致")
    }

    /// nil 键（RK3288 schema）时 tieBreak 不会误选。
    func testCandidatesWithNilKeyAreExcluded() {
        let soc = "RK3288"
        let dir = repoRoot().appendingPathComponent(soc)
        // 造两个都取不到 cs0_* 的候选（forceinit 传 nil 模拟）
        let c1 = candidate(dir.appendingPathComponent("a.cfg"), soc: soc)
        let c2 = candidate(dir.appendingPathComponent("b.cfg"), soc: soc)
        let ch = ChannelGeometry(rank: 1, col: 10, bank: 3, cs0Row: 15, cs1Row: 13,
                                 busWidthBits: 32, dieWidthBits: 16)
        let decoded = DetectedGeometry(rawOsReg: [], sysRegVersion: 0, dramType: .ddr3,
                                       numChannels: 1, channels: [ch], totalSizeMB: 2048)
        let winners = CfgAutoSelect.tieBreak([(c1, nil), (c2, nil)], decoded: decoded)
        XCTAssertTrue(winners.isEmpty, "key 取不到时应排除，交回手动")
    }
}
