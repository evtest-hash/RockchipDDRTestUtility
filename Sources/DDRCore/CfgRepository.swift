import Foundation

public final class CfgRepository {
    public let rootURL: URL

    public init(rootURL: URL) {
        self.rootURL = rootURL
    }

    public static func makeDefaultRootURL() -> URL {
        let env = ProcessInfo.processInfo.environment["DDR_USERTOOL_ROOT"]
        if let env, !env.isEmpty {
            return URL(fileURLWithPath: env)
        }
        // Check inside app bundle Resources/RuntimeData
        if let resourceURL = Bundle.main.resourceURL {
            let bundled = resourceURL.appendingPathComponent("RuntimeData")
            if FileManager.default.fileExists(atPath: bundled.path) {
                return bundled
            }
        }
        // Walk up from executable to find DDR_UserTool_v1.41 sibling
        if let exeURL = Bundle.main.executableURL ?? ExecutableHelper.executableURL {
            var dir = exeURL.deletingLastPathComponent()
            for _ in 0..<6 {
                let candidate = dir.appendingPathComponent("DDR_UserTool_v1.41")
                if FileManager.default.fileExists(atPath: candidate.path) {
                    return candidate.standardizedFileURL
                }
                dir = dir.deletingLastPathComponent()
            }
        }
        // Fallback: relative to CWD
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        return cwd.appendingPathComponent("../DDR_UserTool_v1.41").standardizedFileURL
    }

    public func loadSettings() throws -> (settings: ConfigSettings, languages: [AppLanguage], selectedLanguageTag: String) {
        let configURL = rootURL.appendingPathComponent("resource/config.ini")
        let ini = try IniParser.parse(url: configURL)
        let language = ini.section("Language")
        let system = ini.section("System")

        let selected = language["Selected"] ?? "1"
        let selectedTag = language["Lang\(selected)Tag"] ?? "ENG"

        var languages: [AppLanguage] = []
        let langCount = Int(language["Kinds"] ?? "0") ?? 0
        for idx in 1...max(langCount, 1) where langCount > 0 {
            let fileName = language["Lang\(idx)File"] ?? ""
            guard !fileName.isEmpty else { continue }
            let lang = AppLanguage(
                tag: language["Lang\(idx)Tag"] ?? "LANG\(idx)",
                titleChinese: language["Lang\(idx)CHNTitle"] ?? "",
                titleEnglish: language["Lang\(idx)ENGTitle"] ?? "",
                fileName: fileName
            )
            languages.append(lang)
        }

        let settings = ConfigSettings(
            defaultTestFile: system["DEFAULT_TESTFILE"],
            autoTest: system["AUTOTEST"],
            logFlag: parseBool(system["LOGFLAG"], fallback: true),
            supportLowUSB: parseBool(system["SUPPORTLOWUSB"], fallback: true),
            mscWaitTime: Int(system["MSC_WAITTIME"] ?? "30") ?? 30,
            rkusbWaitTime: Int(system["RKUSB_WAITTIME"] ?? "20") ?? 20,
            printfInterval: Int(system["PRINTF_INTERVAL"] ?? "100") ?? 100,
            supportDeviceSelect: parseBool(system["SUPPORT_DEVICE_SELECT"], fallback: false),
            closeRC4List: (system["CLOSE_RC4_LIST"] ?? "").split(separator: "|").map(String.init)
        )

        return (settings, languages, selectedTag)
    }

    public func loadLanguageStrings(fileName: String) throws -> LocalizedStrings {
        let langURL = rootURL.appendingPathComponent("resource/Language/\(fileName)")
        let ini = try IniParser.parse(url: langURL)
        var map: [String: String] = [:]
        for section in ini.sections.values {
            for (key, value) in section {
                map[key] = value
            }
        }
        return LocalizedStrings(map: map)
    }

    public func discoverTestFiles() throws -> [TestFileEntry] {
        let manager = FileManager.default
        var entries: [TestFileEntry] = []
        let rootPath = rootURL.path

        let directory = rootURL.appendingPathComponent("TestFiles")
        guard manager.fileExists(atPath: directory.path) else {
            return entries
        }
        let enumerator = manager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )

        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension.lowercased() == "cfg" else { continue }
            let relative = url.path.replacingOccurrences(of: rootPath + "/", with: "")
            let components = relative.split(separator: "/")
            let soc = components.count >= 2 ? String(components[1]) : "Unknown"
            entries.append(TestFileEntry(
                absolutePath: url.path,
                relativePath: relative,
                socName: soc,
                displayName: url.lastPathComponent
            ))
        }

        return entries.sorted { lhs, rhs in
            if lhs.socName != rhs.socName {
                return lhs.socName.localizedStandardCompare(rhs.socName) == .orderedAscending
            }
            let capL = Self.parseCapacityMB(lhs.displayName)
            let capR = Self.parseCapacityMB(rhs.displayName)
            if capL != capR { return capL < capR }
            return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
        }
    }

    /// Parse leading capacity from filename like "4GB LPDDR4(...).cfg" → 4096
    private static func parseCapacityMB(_ name: String) -> Int {
        let pattern = #"^(\d+(?:\.\d+)?)\s*GB"#
        guard let match = name.range(of: pattern, options: .regularExpression),
              let value = Double(name[match].replacingOccurrences(of: "GB", with: "")) else {
            return 0
        }
        return Int(value * 1024)
    }

    public func resolveDefaultTestFile(_ settings: ConfigSettings, allFiles: [TestFileEntry]) -> TestFileEntry? {
        guard let configured = settings.defaultTestFile, !configured.isEmpty else {
            return allFiles.first
        }
        let normalized = configured.replacingOccurrences(of: "\\", with: "/")
        return allFiles.first { $0.relativePath == normalized }
            ?? allFiles.first { $0.relativePath.hasSuffix(normalized) }
            ?? allFiles.first
    }

    private func parseBool(_ value: String?, fallback: Bool) -> Bool {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return fallback
        }
        switch value.uppercased() {
        case "TRUE", "1", "YES", "Y":
            return true
        case "FALSE", "0", "NO", "N":
            return false
        default:
            return fallback
        }
    }
}

// SPM-built executables don't have a Bundle, so use CommandLine.arguments[0].
private enum ExecutableHelper {
    static var executableURL: URL? {
        if let path = CommandLine.arguments.first {
            return URL(fileURLWithPath: path).standardizedFileURL
        }
        return nil
    }
}
