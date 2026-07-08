import DDRCore
import XCTest

final class CfgRepositoryTests: XCTestCase {
    private func repoRoot() -> URL {
        URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("DDRTestFiles")
    }

    func testDiscoverTestFilesSocNames() throws {
        let root = repoRoot()
        let repo = CfgRepository(rootURL: root)
        let entries = try repo.discoverTestFiles()

        XCTAssertFalse(entries.isEmpty, "Should discover .cfg test files")

        // Verify SoC names match directory names, not filenames
        let rk3588Entries = entries.filter { $0.socName == "RK3588" }
        XCTAssertFalse(rk3588Entries.isEmpty, "RK3588 entries should have socName 'RK3588'")

        let rk3568Entries = entries.filter { $0.socName == "RK3568&RK3566" }
        XCTAssertFalse(rk3568Entries.isEmpty, "RK3568 entries should have socName 'RK3568&RK3566'")

        // No entry should have a .cfg extension as its socName
        for entry in entries {
            XCTAssertFalse(
                entry.socName.hasSuffix(".cfg"),
                "socName should be a directory name, not a filename. Got: \(entry.socName) for \(entry.displayName)"
            )
        }
    }

    // The DDR auto-detect payload cfg ("…自动探测.cfg") is an internal container
    // driven by DdrDetector, NOT a user-selectable test — discovery must exclude
    // it so it never appears in the picker or runs through TestExecutionEngine.
    func testDiscoverTestFilesExcludesDetectCfg() throws {
        let repo = CfgRepository(rootURL: repoRoot())
        let entries = try repo.discoverTestFiles()
        XCTAssertFalse(entries.isEmpty)
        XCTAssertFalse(entries.contains { $0.displayName.contains("自动探测") },
                       "detect cfg must not appear among discovered test files")
    }

    func testDiscoverTestFilesAreSorted() throws {
        let root = repoRoot()
        let repo = CfgRepository(rootURL: root)
        let entries = try repo.discoverTestFiles()

        // Entries should be sorted by SoC name, then by capacity
        let socNames = entries.map(\.socName)
        let sortedSocNames = socNames.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        XCTAssertEqual(socNames, sortedSocNames, "Entries should be sorted by SoC name")
    }

    func testLoadSettingsReturnsDefaultsWhenNoIni() throws {
        let root = repoRoot()
        let repo = CfgRepository(rootURL: root)
        let (settings, languages, tag) = try repo.loadSettings()

        // No config.ini in DDRTestFiles, so defaults should be returned
        XCTAssertEqual(tag, "ENG")
        XCTAssertTrue(languages.isEmpty)
        XCTAssertEqual(settings.mscWaitTime, 30)
        XCTAssertEqual(settings.rkusbWaitTime, 20)
    }
}
