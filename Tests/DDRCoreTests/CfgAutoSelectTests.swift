import XCTest
@testable import DDRCore

final class CfgAutoSelectTests: XCTestCase {

    private func entry(_ path: String, soc: String = "RK3568&RK3566") -> TestFileEntry {
        TestFileEntry(absolutePath: path, relativePath: path, socName: soc, displayName: path)
    }

    private func candidate(_ e: TestFileEntry, score: Int) -> CfgAutoSelect.Candidate {
        CfgAutoSelect.Candidate(entry: e, dramType: nil, sizeMB: 0, csCount: 0, score: score)
    }

    func testFirstAvailablePicksTopRankedCandidatePresentInFiles() {
        let best = entry("/a/8GB LPDDR4X.cfg")
        let second = entry("/a/4GB LPDDR4X.cfg")
        let candidates = [candidate(best, score: 200), candidate(second, score: 100)]
        let files = [best, second]

        XCTAssertEqual(CfgAutoSelect.firstAvailable(candidates, in: files)?.id, best.id)
    }

    func testFirstAvailableSkipsCandidatesMissingFromFiles() {
        let missing = entry("/a/8GB LPDDR4X.cfg")
        let present = entry("/a/4GB LPDDR4X.cfg")
        // Best-ranked candidate (`missing`) no longer exists in the loaded file
        // set — firstAvailable should fall through to the next one that does.
        let candidates = [candidate(missing, score: 200), candidate(present, score: 100)]
        let files = [present]

        XCTAssertEqual(CfgAutoSelect.firstAvailable(candidates, in: files)?.id, present.id)
    }

    func testFirstAvailableReturnsNilWhenNoCandidatePresent() {
        let missing = entry("/a/8GB LPDDR4X.cfg")
        let candidates = [candidate(missing, score: 200)]
        let files: [TestFileEntry] = []

        XCTAssertNil(CfgAutoSelect.firstAvailable(candidates, in: files))
    }

    func testFirstAvailableReturnsNilForEmptyCandidates() {
        XCTAssertNil(CfgAutoSelect.firstAvailable([], in: [entry("/a/x.cfg")]))
    }
}
