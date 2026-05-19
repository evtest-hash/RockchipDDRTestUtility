import Foundation

public struct IniDocument {
    public let sections: [String: [String: String]]

    public init(sections: [String: [String: String]]) {
        self.sections = sections
    }

    public func section(_ name: String) -> [String: String] {
        sections[name] ?? [:]
    }
}

public enum IniParser {
    public static func parse(url: URL) throws -> IniDocument {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw DDRToolError.fileNotFound("Failed to read INI file at \(url.path): \(error.localizedDescription)")
        }
        return try parse(data: data)
    }

    public static func parse(data: Data) throws -> IniDocument {
        let text = try decode(data: data)
        return parse(text: text)
    }

    public static func parse(text: String) -> IniDocument {
        var sections: [String: [String: String]] = [:]
        var currentSection = ""

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix(";") || line.hasPrefix("#") {
                continue
            }
            if line.hasPrefix("[") && line.hasSuffix("]") {
                currentSection = String(line.dropFirst().dropLast())
                if sections[currentSection] == nil {
                    sections[currentSection] = [:]
                }
                continue
            }
            guard let splitIndex = line.firstIndex(of: "=") else {
                continue
            }
            let key = String(line[..<splitIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
            let value = String(line[line.index(after: splitIndex)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            sections[currentSection, default: [:]][key] = value
        }
        return IniDocument(sections: sections)
    }

    private static func decode(data: Data) throws -> String {
        if data.starts(with: [0xFF, 0xFE]) {
            if let text = String(data: data.dropFirst(2), encoding: .utf16LittleEndian) {
                return text.replacingOccurrences(of: "\u{0000}", with: "")
            }
        }
        if let text = String(data: data, encoding: .utf16LittleEndian) {
            return text.replacingOccurrences(of: "\u{0000}", with: "")
        }
        if let text = String(data: data, encoding: .utf8) {
            return text
        }
        if let text = String(data: data, encoding: .ascii) {
            return text
        }
        throw DDRToolError.invalidFormat("Unable to decode INI text")
    }
}
