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
        public let score: Int           // higher = better match
    }

    /// Two LPDDR4 variants (LPDDR4 / LPDDR4X) share electrical geometry and are
    /// hard to tell apart from OS_REG alone, so treat them as one family.
    private static func sameFamily(_ a: DramType, _ b: DramType) -> Bool {
        if a == b { return true }
        let lp4: Set<DramType> = [.lpddr4, .lpddr4x]
        return lp4.contains(a) && lp4.contains(b)
    }

    /// Parse chip-select count from a filename ("用2个CS" / "2个cs" / "4 CS").
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

    /// Rank soldering-test cfgs (filenames containing 焊接) for a SoC against the
    /// detected geometry. Returns candidates sorted best-first.
    public static func rank(geometry: DetectedGeometry, socFiles: [TestFileEntry]) -> [Candidate] {
        let solder = socFiles.filter { $0.displayName.contains("焊接") }
        let pool = solder.isEmpty ? socFiles : solder
        var out: [Candidate] = []
        for e in pool {
            let t = dramType(fromFilename: e.displayName)
            let sz = sizeMB(fromFilename: e.displayName)
            let cs = csCount(fromFilename: e.displayName)
            var score = 0
            if let t, let g = geometry.dramType {
                if t == g { score += 100 }                    // exact type
                else if sameFamily(t, g) { score += 80 }      // LPDDR4 ≈ LPDDR4X
            }
            if sz != 0, sz == geometry.totalSizeMB { score += 100 }
            else if sz != 0, geometry.totalSizeMB != 0 {
                score += max(0, 40 - abs(sz - geometry.totalSizeMB) / 64)
            }
            if cs != 0, cs == geometry.totalCS { score += 50 } // CS layout disambiguator
            out.append(Candidate(entry: e, dramType: t, sizeMB: sz, csCount: cs, score: score))
        }
        return out.sorted { $0.score > $1.score }
    }
}
