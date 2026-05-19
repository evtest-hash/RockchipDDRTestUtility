import Foundation

public final class ResultLogWriter {
    public init() {}

    public func render(result: ExecutionResult, sourceCfgPath: String, outcome: TestOutcome? = nil) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy/MM/dd HH:mm:ss"
        let finalOutcome = outcome ?? result.outcome

        var lines: [String] = []
        lines.append("Cfg: \(URL(fileURLWithPath: sourceCfgPath).lastPathComponent)")
        if let device = result.selectedDevice {
            lines.append("Device: \(device.productName)")
        }
        lines.append("Time: \(dateFormatter.string(from: result.startedAt))")
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

        return lines.joined(separator: "\n")
    }

    @discardableResult
    public func write(result: ExecutionResult, sourceCfgPath: String, outputURL: URL, outcome: TestOutcome? = nil) throws -> URL {
        let content = render(result: result, sourceCfgPath: sourceCfgPath, outcome: outcome)
        try content.write(to: outputURL, atomically: true, encoding: .utf8)
        return outputURL
    }
}
