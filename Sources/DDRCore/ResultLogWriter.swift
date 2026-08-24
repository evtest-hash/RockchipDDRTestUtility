import Foundation

public final class ResultLogWriter {
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy/MM/dd HH:mm:ss"
        return formatter
    }()

    public init() {}

    public func render(result: ExecutionResult, sourceCfgPath: String, outcome: TestOutcome? = nil) -> String {
        let finalOutcome = outcome ?? result.outcome

        var lines: [String] = []
        lines.append("Cfg: \(URL(fileURLWithPath: sourceCfgPath).lastPathComponent)")
        if let device = result.selectedDevice {
            lines.append("Device: \(device.productName)")
        }
        lines.append("Time: \(Self.dateFormatter.string(from: result.startedAt))")
        lines.append("Result: \(finalOutcome == .passed ? "PASS" : "FAIL")")
        lines.append("")

        for entry in result.logs where entry.code == "INFO_PRINTF" {
            let cleaned = entry.message
                .replacingOccurrences(of: "<>", with: "")
                .replacingOccurrences(of: "</N>", with: "")
            for line in cleaned.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                lines.append(trimmed)
            }
        }

        // Host-side error entries, appended after the device printf. Without
        // these the rendered log carried ONLY device output, so a run that died
        // on a bulk timeout produced a log with no reason in it — and the CLI
        // embeds this render in its JSON as the sole failure evidence.
        let errors = result.logs.filter { $0.level == .error }
        if !errors.isEmpty {
            lines.append("")
            lines.append("--- host errors ---")
            for entry in errors {
                let itemPrefix = entry.itemName.map { "[\($0)] " } ?? ""
                lines.append("\(entry.code): \(itemPrefix)\(entry.message)")
            }
        }

        return lines.joined(separator: "\n")
    }

    @discardableResult
    public func write(result: ExecutionResult, sourceCfgPath: String, outputURL: URL, outcome: TestOutcome? = nil) throws -> URL {
        let content = render(result: result, sourceCfgPath: sourceCfgPath, outcome: outcome)
        try content.write(to: outputURL, atomically: true, encoding: .utf8)
        return outputURL
    }
}
