import Foundation

/// Ranks the soldering-test cfgs of a SoC folder against detected geometry, so
/// the tool can auto-select (or shortlist) the right config file.
///
/// Matching keys off the two most robust signals — DRAM type and total capacity
/// — which are both encoded in the cfg filename (e.g. "8GB LPDDR4X(...)焊接检测.cfg")
/// and independently decoded from OS_REG. Filename parsing is deliberately
/// resilient: a slightly-off bitfield decode still shortlists correctly on type,
/// and the caller always shows the ranked list rather than blindly running.
public enum CfgAutoSelect {

    public struct Candidate: Sendable {
        public let entry: TestFileEntry
        public let dramType: DramType?
        public let sizeMB: Int
        public let csCount: Int         // 0 = unknown
    }

    /// Parse the PER-DIE chip-select count from a filename. Rockchip labels CS
    /// per die, not per module: RK356x "用2个CS", RK3588 "每片颗粒2个CS" — the
    /// regex picks up the digit immediately before 个?CS in both, which is the
    /// per-die value to match against `DetectedGeometry.csPerDie`.
    public static func csCount(fromFilename name: String) -> Int {
        if let m = name.range(of: #"(\d+)\s*个?\s*[Cc][Ss]"#, options: .regularExpression) {
            let digits = name[m].prefix { $0.isNumber }
            return Int(digits) ?? 0
        }
        return 0
    }

    /// Parse DRAM type from a cfg filename. Order matters: check LPDDR4X before
    /// LPDDR4, LPDDR before DDR.
    public static func dramType(fromFilename name: String) -> DramType? {
        let u = name.uppercased()
        if u.contains("LPDDR5") { return .lpddr5 }
        if u.contains("LPDDR4X") { return .lpddr4x }
        if u.contains("LPDDR4") { return .lpddr4 }
        if u.contains("LPDDR3") { return .lpddr3 }
        if u.contains("LPDDR2") { return .lpddr2 }
        if u.contains("DDR4") { return .ddr4 }
        if u.contains("DDR3") { return .ddr3 }
        if u.contains("DDR2") { return .ddr2 }
        return nil
    }

    /// Parse leading capacity ("8GB ...", "1.5GB ...", "512MB ...") to MB.
    public static func sizeMB(fromFilename name: String) -> Int {
        if let m = name.range(of: #"^(\d+(?:\.\d+)?)\s*GB"#, options: .regularExpression),
           let v = Double(name[m].replacingOccurrences(of: "GB", with: "").trimmingCharacters(in: .whitespaces)) {
            return Int(v * 1024)
        }
        if let m = name.range(of: #"^(\d+)\s*MB"#, options: .regularExpression),
           let v = Int(name[m].replacingOccurrences(of: "MB", with: "").trimmingCharacters(in: .whitespaces)) {
            return v
        }
        return 0
    }

    /// Returns ONLY the soldering-test cfgs (filenames containing 焊接) whose
    /// **(capacity, CS count, DRAM type) all EXACTLY match** the detected geometry
    /// — this exact three-way match is the definition of a successful detection.
    /// An empty result means detection did NOT identify a cfg: either the board's
    /// config isn't in the library, or DDR init failed and the geometry is garbage
    /// (e.g. all-zero SYS_REG decodes to a bogus part that matches nothing here).
    ///
    /// Type matches EXACTLY per the Rockchip SYS_REG standard (U-Boot `sdram.h`):
    /// LPDDR4 (7) and LPDDR4X (8) are distinct DDRTYPE codes that the V3 encoder
    /// and `OsRegDecoder` both represent fully, so we trust the decoded type and
    /// do NOT fold LP4/LP4X together. (LPDDR5X has no separate `sdram.h` code —
    /// both LPDDR5 and LPDDR5X are 9 — so an LPDDR5X part and an "LPDDR5X"-named
    /// cfg both resolve to `.lpddr5` and match without any special-casing.)
    ///
    /// More than one candidate can still come back when the library holds several
    /// cfgs with the same (type, capacity, CS) that differ only in die
    /// composition — a real ambiguity the caller surfaces for the user to resolve.
    public static func rank(geometry: DetectedGeometry, socFiles: [TestFileEntry]) -> [Candidate] {
        guard let g = geometry.dramType, geometry.totalSizeMB > 0, geometry.csPerDie > 0 else { return [] }
        let solder = socFiles.filter { $0.displayName.contains("焊接") }
        let pool = solder.isEmpty ? socFiles : solder
        var out: [Candidate] = []
        for e in pool {
            guard let t = dramType(fromFilename: e.displayName) else { continue }
            let sz = sizeMB(fromFilename: e.displayName)
            let cs = csCount(fromFilename: e.displayName)
            guard sz == geometry.totalSizeMB, cs == geometry.csPerDie, t == g else { continue }
            out.append(Candidate(entry: e, dramType: t, sizeMB: sz, csCount: cs))
        }
        return out
    }

    /// Picks the best-ranked candidate that is actually present in `files`
    /// (matched by `TestFileEntry.id`), skipping any ranked candidates whose
    /// entry has since disappeared from the loaded file set. Returns nil if
    /// none match, so the caller can fall back (e.g. to the first cfg for the
    /// SoC) rather than silently keeping a stale selection.
    ///
    /// Kept as pure, dependency-free decision logic — separate from
    /// `MainViewModel` (a `@MainActor` GUI class in the app target, which
    /// isn't unit-testable) — so the actual preselect rule has test coverage.
    public static func firstAvailable(_ candidates: [Candidate], in files: [TestFileEntry]) -> TestFileEntry? {
        let ids = Set(files.map(\.id))
        for c in candidates where ids.contains(c.entry.id) {
            return c.entry
        }
        return nil
    }

    /// 探测匹配分级，供上层决定是否允许自动测试。
    public enum MatchTier: Sendable {
        case uniqueByCoarse    // L1(文件名 type+容量+CS) 即唯一命中
        case uniqueByTieBreak  // L1>1，靠参数几何 tie-break 收敛成唯一（离散颗粒，未硬件验证 → 待确认）
        case ambiguous         // L1>1 且 tie-break 仍无法唯一
        case none              // L1 零命中
    }

    /// 在 L1 候选内部，用每个候选 `forceinit` 的位宽几何与解码几何比对，
    /// 只保留 (busWidthBits, dieWidthBits) 与解码首通道一致的候选。保序。
    /// 解码无通道、或候选 `forceinit` 为 nil / 取不到位宽键 → 该候选被排除，
    /// 绝不误选（配合铁律回退手动）。
    public static func tieBreak(_ pairs: [(candidate: Candidate, forceinit: CfgItem?)],
                                decoded: DetectedGeometry) -> [Candidate] {
        guard let ch = decoded.channels.first else { return [] }
        let target = CfgParamGeometry.widthKey(fromDecoded: ch)
        return pairs.compactMap { pair in
            guard let fi = pair.forceinit,
                  let k = CfgParamGeometry.widthKey(fromForceinit: fi),
                  k == target else { return nil }
            return pair.candidate
        }
    }
}
