import DDRCore
import XCTest

/// Full-regression: parse every .cfg shipped in DDRTestFiles/.
final class ParseAllCfgsTests: XCTestCase {
    func testParseAllCfgs() throws {
        let root = URL(fileURLWithPath: #file)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("DDRTestFiles")
        let parser = CfgBinaryParser()
        var ok = 0, fail = 0, badItems = 0, missingInit = 0
        var errors: [String] = []

        let fm = FileManager.default
        guard let e = fm.enumerator(at: root, includingPropertiesForKeys: nil) else {
            XCTFail("Cannot enumerate DDRTestFiles")
            return
        }
        for case let url as URL in e where url.pathExtension == "cfg" {
            do {
                let plan = try parser.parse(url: url)
                if plan.items.isEmpty { badItems += 1 }
                let hasInit = plan.items.contains {
                    $0.name.range(of: "init", options: .caseInsensitive) != nil
                }
                if !hasInit { missingInit += 1 }
                ok += 1
            } catch {
                fail += 1
                let msg = "\(url.deletingLastPathComponent().lastPathComponent)/\(url.lastPathComponent): \(error)"
                errors.append(msg)
            }
        }
        print("Parsed: \(ok) ok  \(fail) failed  \(badItems) no-items  \(missingInit) missing-init-item")
        for err in errors { print("  FAIL: \(err)") }
        XCTAssertEqual(fail, 0, "Every cfg must parse without error")
    }
}
