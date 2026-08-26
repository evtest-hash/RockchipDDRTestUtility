import DDRCore
import DDRUSB
import Foundation
import XCTest
@testable import RockchipDDRTestUtilityCLI

/// The CLI's machine contract — exit codes, the errorCode enum, argv parsing and
/// the JSON shape. Automation depends on all four and none of them had a test.
///
/// These pin EXISTING behaviour (characterisation): the contract is documented in
/// CLAUDE.md and already shipped, so the job here is to make it impossible to
/// change by accident, not to change it.
final class CLIContractTests: XCTestCase {

    // MARK: - exit codes

    /// The documented rule. `exit 2` is the only one that scraps a board, which
    /// is why it must mean "a verdict was produced AND it was bad".
    func testExitCodeTruthTable() {
        XCTAssertEqual(CLIExit.from(pass: true, errorCode: nil).rawValue, 0)
        XCTAssertEqual(CLIExit.from(pass: false, errorCode: nil).rawValue, 2)
        XCTAssertEqual(CLIExit.from(pass: false, errorCode: .transport).rawValue, 1)
    }

    /// An errorCode outranks `pass`: no verdict was produced, so a stale `true`
    /// must not report a pass.
    func testAnErrorCodeAlwaysWinsOverPass() {
        XCTAssertEqual(CLIExit.from(pass: true, errorCode: .noDevice).rawValue, 1)
    }

    func testExitTwoImpliesNoErrorCode() {
        for code in [CLIErrorCode.transport, .noDevice, .cfgNotFound, .unsupportedSoc,
                     .probeFailed, .ambiguousCfg, .deviceWedged, .scanIncomplete, .badArgument] {
            XCTAssertNotEqual(CLIExit.from(pass: false, errorCode: code).rawValue, 2,
                              "\(code) must not be reportable as a device verdict")
        }
    }

    // MARK: - error classification

    func testHostErrorsClassifyToTheirOwnCode() {
        XCTAssertEqual(CLIErrorCode.classify(DDRToolError.noDevice), .noDevice)
        XCTAssertEqual(CLIErrorCode.classify(DDRToolError.fileNotFound("x")), .cfgNotFound)
        XCTAssertEqual(CLIErrorCode.classify(DDRToolError.parseFailure("x")), .cfgNotFound)
        XCTAssertEqual(CLIErrorCode.classify(DDRToolError.invalidFormat("x")), .badArgument)
        XCTAssertEqual(CLIErrorCode.classify(DDRToolError.transportError("x")), .transport)
        XCTAssertEqual(CLIErrorCode.classify(DetectError.unsupportedSoc), .unsupportedSoc)
        XCTAssertEqual(CLIErrorCode.classify(DetectError.noOsReg), .probeFailed)
        XCTAssertEqual(CLIErrorCode.classify(DetectError.cfgPayloadMissing("x")), .cfgNotFound)
    }

    /// Deliberately conservative: an unrecognised error is a host problem, never
    /// a bad board. Getting this wrong scraps good boards.
    func testAnUnknownErrorIsTransportNotAVerdict() {
        struct Weird: Error {}
        XCTAssertEqual(CLIErrorCode.classify(Weird()), .transport)
    }

    /// Every inconclusive reason has a distinct code — collapsing any two would
    /// stop automation telling "replug the fixture" from "raise the timeout".
    func testEveryInconclusiveReasonMapsToItsOwnCode() {
        let pairs: [(InconclusiveReason, CLIErrorCode)] = [
            (.transport, .transport), (.cfg, .cfgNotFound), (.noDevice, .noDevice),
            (.deviceWedged, .deviceWedged), (.scanIncomplete, .scanIncomplete),
        ]
        for (reason, expected) in pairs {
            XCTAssertEqual(CLIErrorCode.from(reason), expected)
        }
        XCTAssertEqual(Set(pairs.map(\.1.rawValue)).count, pairs.count, "codes must stay distinct")
    }

    // MARK: - argv

    func testEachProductionFlagSelectsItsMode() throws {
        XCTAssertEqual(try CLIArguments.parse(["x", "--list"]).mode, .list)
        XCTAssertEqual(try CLIArguments.parse(["x", "--detect"]).mode, .detect)
        XCTAssertEqual(try CLIArguments.parse(["x", "--solder"]).mode, .solder)
        XCTAssertEqual(try CLIArguments.parse(["x", "--eyescan"]).mode, .eyescan)
    }

    func testNoCommandIsUnknownRatherThanADefault() throws {
        XCTAssertEqual(try CLIArguments.parse(["x", "--json"]).mode, .unknown)
    }

    func testUnknownFlagIsRejected() {
        XCTAssertThrowsError(try CLIArguments.parse(["x", "--bogus"]))
    }

    /// The bring-up diagnostics are gone; asking for one must fail loudly rather
    /// than being silently ignored into `.unknown`.
    func testRemovedDiagnosticFlagsAreRejected() {
        for flag in ["--cfg", "--probe-bulk", "--repeat"] {
            XCTAssertThrowsError(try CLIArguments.parse(["x", flag, "1"]), flag)
        }
    }

    func testFlagsThatTakeAValueRejectAMissingOne() {
        XCTAssertThrowsError(try CLIArguments.parse(["x", "--device-id"]))
        XCTAssertThrowsError(try CLIArguments.parse(["x", "--eye-timeout"]))
        XCTAssertThrowsError(try CLIArguments.parse(["x", "--eyescan", "--eye-timeout", "abc"]))
    }

    func testOptionsParseIntoTheirFields() throws {
        let a = try CLIArguments.parse(["x", "--eyescan", "--eye-timeout", "240",
                                        "--device-id", "dev-1", "--json", "--quiet"])
        XCTAssertEqual(a.eyescanTimeout, 240)
        XCTAssertEqual(a.selectedDeviceID, "dev-1")
        XCTAssertTrue(a.json)
        XCTAssertTrue(a.quiet)
    }

    // MARK: - JSON shape

    func testVerdictFieldIsAlwaysPresentAndNamedPass() throws {
        let json = try encode(CLIResult(mode: .solder, pass: false))
        XCTAssertEqual(json["pass"] as? Bool, false)
        XCTAssertEqual(json["mode"] as? String, "solder")
    }

    /// Unknown fields are ABSENT, never "" or 0 — a consumer must be able to tell
    /// "not read" from "read as empty".
    func testUnknownFieldsAreOmittedRatherThanEmptied() throws {
        let json = try encode(CLIResult(mode: .detect, pass: true))
        for key in ["errorCode", "errorMessage", "cpuid", "serial", "chipVariant",
                    "soc", "pid", "device", "rebootedToMaskrom", "detect", "solder", "eyescan"] {
            XCTAssertNil(json[key], "\(key) should be omitted when unset")
        }
    }

    func testErrorCodeEncodesAsItsStableString() throws {
        let json = try encode(CLIResult(mode: .eyescan, pass: false, errorCode: .deviceWedged))
        XCTAssertEqual(json["errorCode"] as? String, "deviceWedged")
    }

    func testEveryModeEncodesAsItsFlagName() throws {
        for (mode, name) in [(CLIMode.detect, "detect"), (.solder, "solder"),
                             (.eyescan, "eyescan"), (.list, "list")] {
            let json = try encode(CLIResult(mode: mode, pass: true))
            XCTAssertEqual(json["mode"] as? String, name)
        }
    }

    // MARK: - human summary

    /// FAIL is reserved for a device verdict. A run that produced none must not
    /// print it — that wording is what an operator acts on.
    func testTheSummaryLineSaysFailOnlyForADeviceVerdict() {
        XCTAssertTrue(eyescanVerdictLine(.deviceFailed).hasPrefix("FAIL"))
        XCTAssertTrue(eyescanVerdictLine(.passed).hasPrefix("PASS"))
        for reason: InconclusiveReason in [.transport, .deviceWedged, .scanIncomplete] {
            let line = eyescanVerdictLine(.inconclusive(reason))
            XCTAssertFalse(line.contains("FAIL"), line)
            XCTAssertTrue(line.contains("NO VERDICT"), line)
        }
    }

    private func encode(_ r: CLIResult) throws -> [String: Any] {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let obj = try JSONSerialization.jsonObject(with: try enc.encode(r))
        return obj as? [String: Any] ?? [:]
    }
}
