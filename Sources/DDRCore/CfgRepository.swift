import Foundation

public final class CfgRepository {
    public let rootURL: URL

    /// Filename marker of an eye-scan container cfg. Single source — used both to
    /// exclude it from the selectable list here and to locate it (MainViewModel).
    public static let eyescanCfgMarker = "眼图"

    /// Filename markers of internal container cfgs excluded from the selectable
    /// test-file list (see `discoverTestFiles`). Single source — extend here.
    private static let containerCfgMarkers = ["自动探测", eyescanCfgMarker]

    public init(rootURL: URL) {
        self.rootURL = rootURL
    }

    /// Optional fallback that materializes a DDRTestFiles/ root when none is
    /// found on disk. The single-file CLI sets this to extract its embedded
    /// (LZMA-compressed) cfg library to a temp dir — so a lone binary with no
    /// sibling DDRTestFiles/ still resolves cfgs. Unset in the GUI (which bundles
    /// the directory in Resources) and in tests. Consulted by `makeDefaultRootURL`
    /// AFTER the disk probes, so a real on-disk directory always wins.
    public static var embeddedRootProvider: (() -> URL?)?

    /// Locate a SoC's packaged eye-scan cfg (`DDRTestFiles/<soc>/…眼图.cfg`). SINGLE SOURCE shared by
    /// the GUI (`MainViewModel.locateEyescanCfg`) and the CLI `--eyescan` mode, so both drive the
    /// eye-scan from the packaged cfg (like detect/solder) instead of hand-specified per-bin paths.
    public func eyescanCfgURL(forSoc soc: String) -> URL? {
        let dir = rootURL.appendingPathComponent(soc)
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        else { return nil }
        return files.first { $0.pathExtension.lowercased() == "cfg"
            && $0.lastPathComponent.contains(Self.eyescanCfgMarker) }
    }

    public static func makeDefaultRootURL() -> URL {
        // Bundled app: DDRTestFiles is in Resources/
        if let resourceURL = Bundle.main.resourceURL {
            let bundled = resourceURL.appendingPathComponent("DDRTestFiles")
            if FileManager.default.fileExists(atPath: bundled.path) {
                log("Using bundled DDRTestFiles: \(bundled.path)")
                return bundled
            }
            log("Bundle resource DDRTestFiles not found at: \(bundled.path)")
        }
        // CLI / development: DDRTestFiles sibling to executable
        if let exeURL = Bundle.main.executableURL ?? ExecutableHelper.executableURL {
            let candidate = exeURL.deletingLastPathComponent().appendingPathComponent("DDRTestFiles")
            if FileManager.default.fileExists(atPath: candidate.path) {
                log("Using executable-sibling DDRTestFiles: \(candidate.path)")
                return candidate.standardizedFileURL
            }
            log("Executable-sibling DDRTestFiles not found at: \(candidate.path)")
        }
        // CWD relative (dev: `swift run` from the package root)
        let cwdRelative = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("DDRTestFiles").standardizedFileURL
        if FileManager.default.fileExists(atPath: cwdRelative.path) {
            log("Using CWD-relative DDRTestFiles: \(cwdRelative.path)")
            return cwdRelative
        }
        // Embedded fallback (single-file CLI): extract the compiled-in library.
        if let embedded = embeddedRootProvider?() {
            log("Using embedded DDRTestFiles: \(embedded.path)")
            return embedded
        }
        // Last resort: the (missing) CWD-relative path, so callers get a stable URL.
        log("Falling back to CWD-relative DDRTestFiles: \(cwdRelative.path)")
        return cwdRelative
    }

    public func loadSettings() throws -> (settings: ConfigSettings, languages: [AppLanguage], selectedLanguageTag: String) {
        let configURL = rootURL.appendingPathComponent("resource/config.ini")
        guard FileManager.default.fileExists(atPath: configURL.path) else {
            return (.default, [], "ENG")
        }
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

        guard manager.fileExists(atPath: rootPath) else {
            return entries
        }
        let enumerator = manager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )

        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension.lowercased() == "cfg" else { continue }
            // Skip the DDR auto-detect payload cfg: it's an internal container
            // (Boot + ddrbin + osregdump + reboot) driven by DdrDetector's own
            // pipeline, NOT a user-selectable soldering-test cfg. Its name always
            // carries "自动探测" and never "焊接" (by design), so it's identifiable
            // here. Excluding it keeps it out of the picker and out of
            // TestExecutionEngine (which would otherwise run its osregdump/reboot
            // items as if they were a memory test). DdrDetector loads it directly
            // by path, so this doesn't affect detection.
            // Skip internal container cfgs: they package payloads driven directly
            // by DdrDetector ("自动探测") / EyescanRunner ("眼图"), NOT user-selectable
            // soldering-test cfgs. Their names carry one of these markers and never
            // "焊接" (by design), so a filename denylist identifies them. (Keep this
            // the single source; add a marker here rather than a new inline guard.)
            if Self.containerCfgMarkers.contains(where: url.lastPathComponent.contains) { continue }
            let fullPath = url.path
            guard fullPath.hasPrefix(rootPath + "/") else { continue }
            let relative = String(fullPath.dropFirst(rootPath.count + 1))
            let components = relative.split(separator: "/")
            let soc = components.count >= 2 ? String(components[0]) : "Unknown"
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
    private static func log(_ message: String) {
        fputs("[CfgRepository] \(message)\n", stderr)
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
