import Foundation

/// THE verdict layer. Every pass/fail decision this tool makes lives here and
/// nowhere else — the GUI and the CLI are only allowed to display what these
/// return and (for the CLI) map them onto exit codes.
///
/// This file exists because the rule wasn't enforced: the eye-scan verdict had
/// one copy in `MainViewModel` and another in the CLI, they drifted, and the
/// GUI's copy reported PASS on a board the firmware had judged bad.

// MARK: - eye-scan

/// What the firmware's own summary says about a scan. The host adds no
/// thresholds of its own — the device prints one `all result:` line per channel
/// (RK3576 dual, RK3588 quad, RK356x single) and a final `all dq eye scan done`.
public struct EyescanReport: Sendable, Equatable {
    /// The `all dq eye scan done` marker: the scan really reached the end.
    public let scanCompleted: Bool
    /// Every `all result:` line, in order, whitespace-trimmed.
    public let resultLines: [String]

    public init(scanCompleted: Bool, resultLines: [String]) {
        self.scanCompleted = scanCompleted
        self.resultLines = resultLines
    }

    /// Completed AND at least one summary AND every summary passing. A later
    /// channel's pass must never bury an earlier channel's failure.
    public var pass: Bool {
        scanCompleted && !resultLines.isEmpty && resultLines.allSatisfy { $0.contains("pass") }
    }

    /// The line to show a human: the first failing channel, else the last one.
    public var displayLine: String? {
        resultLines.first { !$0.contains("pass") } ?? resultLines.last
    }
}

public enum EyescanVerdict {
    /// Parse a device transcript into its summary lines.
    ///
    /// Splits on `isNewline`, NOT on the Character `"\n"`: the device speaks
    /// CRLF and `"\r\n"` is a single Swift Character, so `split(separator: "\n")`
    /// returns the whole transcript as one element — which then "contains pass"
    /// because of the per-channel `pass` lines inside it. That is the bug this
    /// function replaces.
    public static func parse(_ transcript: String) -> EyescanReport {
        EyescanReport(
            scanCompleted: transcript.contains("all dq eye scan done"),
            resultLines: transcript
                .split(whereSeparator: \.isNewline)
                .filter { $0.contains("all result:") }
                .map { $0.trimmingCharacters(in: .whitespaces) })
    }
}

// MARK: - run conclusion

/// Why a run produced no verdict. Distinct from `FailureKind` because the
/// eye-scan has two failure modes the engine can't express (the device stopped
/// answering; it was still streaming at the deadline).
public enum InconclusiveReason: String, Sendable, Equatable {
    case transport        // control/bulk transfer failed, stalled, or timed out
    case cfg              // cfg missing, unparseable, or carrying no items
    case noDevice         // nothing in maskrom to talk to
    case deviceWedged     // eye-scan: device stopped responding → physically replug
    case scanIncomplete   // eye-scan: no verdict by the deadline → raise the timeout
}

/// The outcome of one run, as a production line needs it: three states, not two.
///
/// Collapsing `.inconclusive` into "failed" is what scraps good boards — a bulk
/// timeout looked exactly like a device saying the DDR is bad. Only
/// `.deviceFailed` means the board was tested and judged bad.
public enum RunConclusion: Sendable, Equatable {
    case passed
    case deviceFailed
    case inconclusive(InconclusiveReason)

    /// True only when the device itself judged the DDR. The one condition under
    /// which scrapping the board is correct.
    public var isDeviceVerdict: Bool { self == .deviceFailed }
}

extension RunConclusion {
    /// Solder test: the engine already classified the failure conservatively
    /// (`FailureKind.classify` turns anything unrecognised into `.transport`),
    /// so this is a straight mapping. A failure that names no reason is treated
    /// as inconclusive, never as a bad board.
    public static func solder(_ result: ExecutionResult) -> RunConclusion {
        guard result.outcome != .passed else { return .passed }
        switch result.failure {
        case .deviceVerdict: return .deviceFailed
        case .cfg: return .inconclusive(.cfg)
        case .noDevice: return .inconclusive(.noDevice)
        case .transport, .none: return .inconclusive(.transport)
        }
    }

    /// Eye-scan: a verdict exists only when the device reported done AND the
    /// transcript carries the completion marker. `wedged` and "still streaming"
    /// are transport-side outcomes, so they outrank whatever the text says.
    public static func eyescan(report: EyescanReport,
                               wedged: Bool,
                               completedViaStatus: Bool) -> RunConclusion {
        if wedged { return .inconclusive(.deviceWedged) }
        guard completedViaStatus, report.scanCompleted else { return .inconclusive(.scanIncomplete) }
        return report.pass ? .passed : .deviceFailed
    }
}

// MARK: - detect adoption

/// What to do with a detect result. The iron rule: a cfg is run only when the
/// decoded geometry picked exactly one — otherwise a human picks.
public enum DetectDecision: Sendable, Equatable {
    case adopt    // unique match → preselect the cfg and go on to test
    case manual   // ambiguous or no match → leave the choice to the operator
}

public enum DetectVerdict {
    public static func decide(_ tier: CfgAutoSelect.MatchTier) -> DetectDecision {
        switch tier {
        case .uniqueByCoarse, .uniqueByTieBreak: return .adopt
        case .ambiguous, .none: return .manual
        }
    }
}
