import DDRCore
import DDRUSB
import Foundation

struct CLIArguments {
    var selectedDeviceID: String?
    var listOnly = false
    /// DDR auto-detect: download the auto-probing rkbin DDR bin (0x471), run the
    /// osregdump probe cfg, read OS_REG over USB, decode + match a cfg.
    var detect = false
    var detectCfgPath: String?
    /// SOLDER: detect → soldering test on ONE transport, no reboot between.
    /// detect(reboot:false) leaves the DDR Test Tool Boot resident + transport
    /// open; the matched cfg then runs with skipBoot:true on that same Boot, then
    /// reboots to maskrom. The device USB printf is embedded in the JSON result.
    var solder = false
    /// EYE-SCAN mode: like --detect / --solder, driven by the SoC's packaged `DDR眼图.cfg`
    /// (auto-located by the connected device's PID → SoC). All payloads (DTT/item/trainonly/
    /// reboot) + the item base come from that cfg — no per-bin flags. `--eye-timeout` is a
    /// run option. The full transcript is embedded in the JSON result (no side file).
    var eyescan = false
    var eyescanTimeout: TimeInterval = 120
    /// Emit a single machine-readable JSON object on stdout; route all human
    /// progress/log lines to stderr so stdout carries ONLY the JSON.
    var json = false
    /// Suppress step-by-step progress lines (final human summary still shown,
    /// unless --json). Independent of --json.
    var quiet = false

    /// The four production commands — every mode this CLI has, and all of them
    /// inside the `--json` contract.
    var mode: CLIMode {
        if listOnly { return .list }
        if eyescan { return .eyescan }
        if detect { return .detect }
        if solder { return .solder }
        return .unknown
    }

    static func parse(_ argv: [String]) throws -> CLIArguments {
        var args = CLIArguments()
        var idx = 1

        while idx < argv.count {
            let token = argv[idx]
            switch token {
            case "--device-id":
                idx += 1
                guard idx < argv.count else {
                    throw DDRToolError.invalidFormat("Missing value for --device-id")
                }
                args.selectedDeviceID = argv[idx]
            case "--list":
                args.listOnly = true
            case "--detect":
                args.detect = true
            case "--solder":
                args.solder = true
            case "--detect-cfg":
                idx += 1
                guard idx < argv.count else {
                    throw DDRToolError.invalidFormat("Missing value for --detect-cfg")
                }
                args.detectCfgPath = argv[idx]
            case "--eyescan":
                args.eyescan = true
            case "--eye-timeout":
                idx += 1
                guard idx < argv.count, let n = Double(argv[idx]), n >= 1 else {
                    throw DDRToolError.invalidFormat("Missing/invalid --eye-timeout (seconds)")
                }
                args.eyescanTimeout = n
            case "--json":
                args.json = true
            case "--quiet":
                args.quiet = true
            case "--help", "-h":
                printUsageAndExit()
            default:
                throw DDRToolError.invalidFormat("Unknown argument: \(token)")
            }
            idx += 1
        }

        return args
    }
}

/// Which command ran. Emitted as JSON `mode` so a consumer never has to infer it
/// from which sub-object happens to be present — `--cfg` used to report itself
/// under the `solder` key, making a diagnostic run indistinguishable from a real
/// soldering test.
enum CLIMode: String, Encodable {
    case detect, solder, eyescan, list      // every mode — all inside the --json contract
    case unknown                            // argument error before a mode was known
}

/// Output router. In `--json` mode stdout carries ONLY the final JSON object;
/// every human/progress line is diverted to stderr. In `--quiet` mode progress
/// lines are dropped entirely. This keeps the CLI pipeline-native: a script can
/// read structured results off stdout without scraping log text.
enum CLIOut {
    static var json = false
    static var quiet = false

    /// Verbose / progress line. stderr under --json, dropped under --quiet, else stdout.
    static func log(_ s: String) {
        if json { FileHandle.standardError.write(Data((s + "\n").utf8)); return }
        if quiet { return }
        print(s)
    }

    /// Final human summary. Shown on stdout unless --json (which prints JSON instead).
    static func summary(_ s: String) {
        if json { return }
        print(s)
    }

    /// The single machine-readable result. Only emitted (to stdout) under --json.
    /// An encoding failure is fatal on purpose: silently dropping the object while
    /// still exiting 0 would report a pass that no consumer ever received.
    static func result<T: Encodable>(_ value: T) {
        guard json else { return }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? enc.encode(value), let s = String(data: data, encoding: .utf8) else {
            fputs("Error: failed to encode the JSON result\n", stderr)
            Foundation.exit(CLIExit.error.rawValue)
        }
        print(s)
    }
}

// MARK: - Exit codes

/// The CLI's three exit codes, computed in exactly ONE place (`CLIExit.from`) so
/// the JSON verdict and the process status can never disagree:
///
///   0  PASS  — the device produced a verdict, and it passed
///   2  FAIL  — the device produced a verdict, and it FAILED → scrap the board
///   1  ERROR — NO verdict was produced (cable / fixture / cfg / argument problem)
///              → the board is untested, not bad. Fix the setup and re-run.
///
/// The `errorCode != nil ⇒ 1` rule is what makes exit 2 trustworthy. Previously a
/// bulk timeout mid-test also surfaced as exit 2, so a flaky cable could scrap a
/// good board; and `--detect` failing to match returned 0 despite the documented 2.
enum CLIExit: Int32 {
    case pass = 0
    case error = 1
    case fail = 2

    static func from(pass: Bool, errorCode: CLIErrorCode?) -> CLIExit {
        if errorCode != nil { return .error }
        return pass ? .pass : .fail
    }
}

/// Machine-readable reason no verdict was produced. Replaces the old free-text
/// `error` field, which carried `DDRToolError.errorDescription` — and that drops
/// the case discriminator, so a consumer could not tell "no device" from "bulk
/// stall" from "unsupported SoC".
enum CLIErrorCode: String, Encodable {
    case badArgument      // unknown flag, missing value, or --json on a diagnostic mode
    case noDevice         // no Rockchip device found in maskrom
    case cfgNotFound      // cfg / payload missing, or unparseable
    case unsupportedSoc   // the device's USB PID has no detect profile
    case transport        // control or bulk transfer failed, stalled, or timed out
    case probeFailed      // the osregdump probe never returned OS_REG
    case ambiguousCfg     // geometry decoded fine, but >1 cfg matches — needs a human
    case deviceWedged     // eye-scan: device stopped responding → PHYSICALLY REPLUG
    case scanIncomplete   // eye-scan: still streaming at the deadline → raise --eye-timeout

    /// Classify a thrown error. Anything unrecognised becomes `.transport` —
    /// deliberately conservative, because the alternative (no errorCode) would
    /// report an unknown host-side failure as a bad board.
    static func classify(_ error: Error) -> CLIErrorCode {
        if let e = error as? DDRToolError {
            switch e {
            case .noDevice, .multipleDevices: return .noDevice
            case .fileNotFound, .parseFailure: return .cfgNotFound
            case .invalidFormat: return .badArgument
            case .transportError, .runtimeError: return .transport
            }
        }
        if let e = error as? DetectError {
            switch e {
            case .unsupportedSoc: return .unsupportedSoc
            case .cfgPayloadMissing: return .cfgNotFound
            case .noOsReg: return .probeFailed
            }
        }
        return .transport
    }
}

// MARK: - Machine-readable result model

/// Per-channel decoded geometry — the fields the DDR bin itself prints
/// (`BW=.. Col=.. Bk=.. Row=.. CS=.. Die BW=..`), surfaced so callers can do
/// spec verification straight from JSON instead of scraping printf/stderr.
struct ChannelJSON: Encodable {
    let rank: Int          // CS count in this channel (1 or 2)
    let col: Int           // column address bits
    let bank: Int          // bank address bits (3 → 8 banks)
    let cs0Row: Int        // CS0 row address bits
    let cs1Row: Int        // CS1 row address bits (valid when rank==2)
    let busWidthBits: Int  // channel bus width (8/16/32)
    let dieWidthBits: Int  // per-die width (8/16/32)

    init(from c: ChannelGeometry) {
        rank = c.rank; col = c.col; bank = c.bank
        cs0Row = c.cs0Row; cs1Row = c.cs1Row
        busWidthBits = c.busWidthBits; dieWidthBits = c.dieWidthBits
    }
}

struct DeviceJSON: Encodable {
    let deviceID: String
    let vid: String
    let pid: String
    let name: String
    let soc: String?
}

struct DetectJSON: Encodable {
    /// True only for a UNIQUE match (`uniqueByCoarse` / `uniqueByTieBreak`) —
    /// the same iron rule the GUI applies before it will auto-test.
    let pass: Bool
    let tier: String
    let type: String?
    let capacityMB: Int
    let channels: Int
    let sysRegVersion: Int
    let csPerDie: Int
    let geometry: [ChannelJSON]
    /// The uniquely matched cfg, or null. Never a "best guess" out of an
    /// ambiguous group.
    let cfg: String?
    /// Every cfg that matched, by name — not just how many. An ambiguous result
    /// is only actionable if the caller can see what to choose between.
    let candidates: [String]
    /// Raw OS_REG words. The only way to diagnose a bad decode from JSON alone.
    let rawOsReg: [String]

    static func from(_ out: DetectOutcome, cfg: String?) -> DetectJSON {
        DetectJSON(pass: cfg != nil,
                   tier: tierString(out.matchTier),
                   type: out.geometry.dramType?.displayName,
                   capacityMB: out.geometry.totalSizeMB,
                   channels: out.geometry.numChannels,
                   sysRegVersion: out.geometry.sysRegVersion,
                   csPerDie: out.geometry.csPerDie,
                   geometry: out.geometry.channels.map(ChannelJSON.init(from:)),
                   cfg: cfg,
                   candidates: out.candidates.map(\.entry.displayName),
                   rawOsReg: out.rawOsReg.map { String(format: "0x%08X", $0) })
    }
}

struct SolderJSON: Encodable {
    /// The device's own verdict. `outcome`/`state` are gone: `outcome` was a pure
    /// restatement of this flag, and `state` is diagnostic prose already in `log`.
    let pass: Bool
    let cfg: String
    let bootSucceeded: Bool
    /// Device USB printf (INFO_PRINTF, framing stripped) PLUS host-side error
    /// entries, so the JSON is self-contained even when the run died on a
    /// transport error (逐项 DQS/DQ/DM/CA/CS/ZQ 检查过程 + 结果).
    let log: String?
}

struct EyescanJSON: Encodable {
    /// Renamed from `go`: every mode now spells its verdict `pass`.
    let pass: Bool
    /// The device reported done via status. False means it was still streaming at
    /// the deadline — the board is fine, the timeout was short.
    let completed: Bool
    /// The device stopped responding; it must be PHYSICALLY REPLUGGED. Was only
    /// ever printed to the human summary, so automation could not tell "replug
    /// the fixture" from "this board's eye failed".
    let wedged: Bool
    let bytes: Int
    /// Full eye-scan transcript captured over USB, embedded so the JSON is self-contained.
    let transcript: String
}

/// The single object `--json` prints. `pass` is the one verdict field (the old
/// `ok` plus the per-mode `outcome`/`state`/`go` duplicates), and `errorCode`
/// says whether there was a verdict at all — together they determine the exit
/// code, in one place, so the two can never diverge.
struct CLIResult: Encodable {
    var mode: CLIMode
    var pass: Bool
    var errorCode: CLIErrorCode?
    var errorMessage: String?
    /// Wall-clock for the whole process, stamped centrally in `finish` — every
    /// mode used to fill this itself and two of them hardcoded 0.
    var elapsedMs: Int = 0
    /// Absent (not `""`) when unknown, like every other optional field.
    var soc: String?
    var pid: String?
    var device: String?
    /// Chip identity from OTP. Present whenever the mode read it and the SoC supports it.
    var cpuid: String?
    var serial: String?
    /// Model variant within the family (RK3588S2, RK3566PRO …), and the raw OTP
    /// fields it was decoded from. Absent when the probe read no variant field.
    var chipVariant: String?
    var cpuCode: String?
    var otpSpec: String?
    var otpPackage: String?
    var otpTestVersion: String?
    var rebootedToMaskrom: Bool?
    var devices: [DeviceJSON]?
    var detect: DetectJSON?
    var solder: SolderJSON?
    var eyescan: EyescanJSON?

    init(mode: CLIMode, pass: Bool, errorCode: CLIErrorCode? = nil, errorMessage: String? = nil) {
        self.mode = mode
        self.pass = pass
        self.errorCode = errorCode
        self.errorMessage = errorMessage
    }

    /// Fill in the identity columns from a decoded ChipVariant.
    mutating func fill(variant: ChipVariant?) {
        guard let variant else { return }
        chipVariant = variant.name
        cpuCode = variant.cpuCode.map { String(format: "0x%04x", $0) }
        otpSpec = variant.spec.map { String(format: "0x%02x", $0) }
        otpPackage = variant.package.map { String(format: "0x%x", $0) }
        otpTestVersion = variant.testVersion.map { String(format: "0x%x", $0) }
    }

    mutating func fill(device: UsbDevice, soc: String?) {
        self.soc = (soc?.isEmpty == false) ? soc : nil
        self.pid = "0x" + String(format: "%04X", device.productID)
        self.device = device.productName
    }
}

func tierString(_ t: CfgAutoSelect.MatchTier) -> String {
    switch t {
    case .uniqueByCoarse: return "uniqueByCoarse"
    case .uniqueByTieBreak: return "uniqueByTieBreak"
    case .ambiguous: return "ambiguous"
    case .none: return "none"
    }
}

/// The cfg a detect run selected, or nil. Mirrors the GUI's iron rule: ONLY a
/// unique tier may preselect. `CfgAutoSelect.firstAvailable` alone returns
/// `candidates[0]` even for an ambiguous group, which is how the CLI used to
/// test a board against a cfg the GUI would have refused.
func uniqueCfg(_ out: DetectOutcome, in files: [TestFileEntry]) -> TestFileEntry? {
    switch DetectVerdict.decide(out.matchTier) {
    case .adopt: return CfgAutoSelect.firstAvailable(out.candidates, in: files)
    case .manual: return nil
    }
}

/// One human-readable line per conclusion. "FAIL" is reserved for a real device
/// verdict — a run that produced none must never print it.
func eyescanVerdictLine(_ c: RunConclusion) -> String {
    switch c {
    case .passed: return "PASS — all DQ eye margins pass"
    case .deviceFailed: return "FAIL — the firmware judged a DQ eye out of margin"
    case .inconclusive(let reason): return "NO VERDICT — \(reason) (the board was not judged)"
    }
}

/// Map the shared conclusion onto this CLI's machine-readable reason. The
/// verdict itself is `DDRCore.RunConclusion`; only the naming is CLI-local.
extension CLIErrorCode {
    static func from(_ reason: InconclusiveReason) -> CLIErrorCode {
        switch reason {
        case .transport: return .transport
        case .cfg: return .cfgNotFound
        case .noDevice: return .noDevice
        case .deviceWedged: return .deviceWedged
        case .scanIncomplete: return .scanIncomplete
        }
    }
}

func printUsageAndExit() -> Never {
    let usage = """
    Rockchip DDR Test Utility CLI

    Three DDR checks (run each on a board in Maskrom; each returns to maskrom when done).
    Pass --json for one machine-readable object on stdout (verdict + full device output embedded):
      --detect  [--device-id <id>] [--detect-cfg <detect.cfg>]
                          DDR 自动探测 — probe DDR geometry (type/capacity/channels/CS +
                          per-channel rank/col/bank/row/busWidth/dieWidth) and match a cfg.
      --solder  [--device-id <id>]
                          焊接检测 — detect→soldering test on one transport, then reboot.
                          Device USB printf embedded in JSON as solder.log.
      --eyescan [--device-id <id>] [--eye-timeout <s>]
                          DQ 眼图 — eye-scan via the SoC's packaged DDR眼图.cfg.
                          Verdict = scan completed AND all `all result:` lines pass.
                          Full transcript embedded in JSON as eyescan.transcript.
      --list              list connected Rockchip devices

    Global options:
      --json          emit one JSON object on stdout; all human logs go to stderr
      --quiet         suppress progress lines (final summary still shown unless --json)
      --help, -h      show this help

    Exit codes — 0/2 mean the device produced a verdict, 1 means it did not:
      0  PASS   the check passed
      2  FAIL   the device tested the DDR and reported it BAD (scrap the board)
      1  ERROR  no verdict at all — no device / bad argument / missing cfg /
                USB transport error / eye-scan device wedged or timed out /
                detect matched more than one cfg. The board is untested, not bad.
                The JSON `errorCode` field says which.

    Examples:
      RockchipDDRTestUtilityCLI --list    --json
      RockchipDDRTestUtilityCLI --detect  --json
      RockchipDDRTestUtilityCLI --solder  --json
      RockchipDDRTestUtilityCLI --eyescan --json
    """
    print(usage)
    Foundation.exit(CLIExit.pass.rawValue)
}

@main
struct RockchipDDRTestUtilityCLI {
    /// Process start. A lazy `static let` is only initialised on FIRST access —
    /// and the only access is in `finish()`, which would make every elapsedMs 0.
    /// `main` touches it on its first line to pin it to the real start.
    static let startedAt = Date()

    /// The ONLY place a result is emitted and the process exits. Everything above
    /// just builds a `CLIResult`.
    static func finish(_ result: CLIResult) -> Never {
        var out = result
        out.elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1000)
        CLIOut.result(out)
        Foundation.exit(CLIExit.from(pass: out.pass, errorCode: out.errorCode).rawValue)
    }

    static func main() async {
        _ = startedAt                     // force the lazy static now — see its doc comment
        setvbuf(stdout, nil, _IOLBF, 0)   // line-buffer so piped progress shows live
        // Single-file fallback: if no DDRTestFiles/ is found on disk, extract the
        // compiled-in cfg library. Consulted only after makeDefaultRootURL's disk
        // probes, so a real on-disk directory still wins (see EmbeddedCfgs).
        CfgRepository.embeddedRootProvider = { EmbeddedCfgs.rootURL() }

        // Pre-scan for the output flags BEFORE parsing, so an argument error still
        // honours --json. Previously CLIOut.json was set after parse(), which made
        // `--json --bogus` the one path that printed no JSON at all.
        let argv = CommandLine.arguments
        CLIOut.json = argv.contains("--json")
        CLIOut.quiet = argv.contains("--quiet")

        var mode = CLIMode.unknown
        do {
            let args = try CLIArguments.parse(argv)
            mode = args.mode

            switch mode {
            case .list:      finish(try runList(args: args))
            case .eyescan:   finish(try await runEyescan(args: args))
            case .detect:    finish(try await runDetect(args: args))
            case .solder:    finish(try await runSolder(args: args))
            case .unknown:
                throw DDRToolError.invalidFormat("--detect, --solder, --eyescan or --list is required")
            }
        } catch {
            fputs("Error: \(error.localizedDescription)\n", stderr)
            finish(CLIResult(mode: mode, pass: false,
                             errorCode: CLIErrorCode.classify(error),
                             errorMessage: error.localizedDescription))
        }
    }

    // MARK: - list

    static func runList(args: CLIArguments) throws -> CLIResult {
        let transport = try RkUsbTransportLibusb()
        let devices = try transport.discoverDevices()
        CLIOut.log("Discovered \(devices.count) Rockchip device(s)")
        for (idx, d) in devices.enumerated() {
            CLIOut.log("[\(idx)] id=\(d.deviceID) vid=0x\(hex16(d.vendorID)) pid=0x\(hex16(d.productID)) name=\(d.productName)")
        }
        // An empty bus is `noDevice`, not a pass: a production script that treats
        // "listed nothing" as success would silently skip the whole board.
        var out = CLIResult(mode: .list, pass: !devices.isEmpty,
                            errorCode: devices.isEmpty ? .noDevice : nil,
                            errorMessage: devices.isEmpty ? "No device found" : nil)
        out.devices = devices.map {
            DeviceJSON(deviceID: $0.deviceID, vid: "0x" + hex16($0.vendorID),
                       pid: "0x" + hex16($0.productID), name: $0.productName,
                       soc: DetectProfiles.forPID($0.productID)?.soc ?? $0.socName)
        }
        return out
    }

    // MARK: - eyescan

    /// EYE-SCAN, driven by the SoC's packaged `DDR眼图.cfg` — same shape as `--detect` / `--solder`.
    /// Discover the device → PID→SoC → locate the cfg → extract payloads (DTT/item/trainonly/reboot +
    /// item base) → run. No per-bin flags: everything comes from the packaged cfg.
    static func runEyescan(args: CLIArguments) async throws -> CLIResult {
        let transport = try RkUsbTransportLibusb()
        let devices = try transport.discoverDevices()
        guard let device = chooseDevice(from: devices, selectedDeviceID: args.selectedDeviceID) else {
            throw DDRToolError.noDevice
        }
        let soc = DetectProfiles.forPID(device.productID)?.soc ?? device.socName ?? ""
        CLIOut.log("Device: \(device.productName) soc=\(soc) pid=0x\(hex16(device.productID))")

        let root = CfgRepository.makeDefaultRootURL()
        guard let cfgURL = CfgRepository(rootURL: root).eyescanCfgURL(forSoc: soc) else {
            throw DDRToolError.fileNotFound("no eye-scan cfg (…眼图.cfg) found for \(soc) under \(root.path)")
        }
        let plan = try CfgBinaryParser().parse(url: cfgURL)
        guard let p = plan.eyescanPayloads() else {
            throw DDRToolError.parseFailure("\(cfgURL.lastPathComponent) is not an eye-scan cfg (missing Boot/eyescan)")
        }
        CLIOut.log("Eye-scan cfg: \(cfgURL.lastPathComponent)")
        CLIOut.log("  DTT \(p.dtt.count)B + item \(p.item.count)B"
            + (p.trainOnly.isEmpty ? "" : " + trainonly \(p.trainOnly.count)B")
            + (p.reboot.map { " + reboot \($0.count)B" } ?? "")
            + " @0x\(String(p.itemBase, radix: 16))")

        // The identity probe lives in the DETECT cfg and calls the loader's puts vector at a fixed
        // address, so it is only safe when the eye-scan loader is the same build. They are built
        // from one source and differ only in a timing constant, so this checks same-build (identical
        // size) rather than byte-identical — a byte comparison never matches, because the eye-scan
        // cfgs ship a speed-patched copy, and the identity would silently never be read.
        let profile = DetectProfiles.forPID(device.productID)
        var otpBin: Data?
        if let profile, profile.idProbe != nil,
           let detectPlan = try? CfgBinaryParser().parse(url: root.appendingPathComponent(soc)
               .appendingPathComponent(profile.detectCfgName)),
           let detectBoot = detectPlan.payload(named: "Boot"), detectBoot.count == p.dtt.count {
            otpBin = detectPlan.payload(named: "otpdump")
        }
        CLIOut.log("  chip identity  : " + (otpBin == nil
            ? "not read (no otpdump payload for this SoC, or its eye-scan loader is a different build)"
            : "otpdump from the detect cfg"))

        let start = Date()
        let box = ProgressBox()
        let outcome = try await EyescanRunner().run(
            transport: transport, device: device,
            ddrBin: p.trainOnly, ddrTestTool: p.dtt, itemBin: p.item,
            itemBase: p.itemBase, timeout: args.eyescanTimeout, rebootBin: p.reboot,
            otpBin: otpBin, idProbe: profile?.idProbe, family: profile?.family,
            onProgress: { chunk in box.note(chunk, since: start) })
        try? transport.close()

        let transcript = outcome.transcript
        let report = EyescanVerdict.parse(transcript)
        // Wedged, still-streaming, or completed-without-the-done-marker all mean
        // NO verdict about the eye — exit 1, not 2. Only a completed scan whose
        // firmware summary says fail scraps a board.
        let conclusion = RunConclusion.eyescan(report: report, wedged: outcome.wedged,
                                               completedViaStatus: outcome.completedViaStatus)
        let pass = conclusion == .passed
        let errorCode: CLIErrorCode? = switch conclusion {
        case .inconclusive(let reason): CLIErrorCode.from(reason)
        case .passed, .deviceFailed: nil
        }
        // The code alone doesn't say what to DO about it, and these two are the
        // only outcomes an operator can act on without touching the board.
        let errorMessage: String? = switch errorCode {
        case .deviceWedged: "The device stopped responding mid-scan — physically replug the board and re-run"
        case .scanIncomplete: "Still streaming at the \(Int(args.eyescanTimeout))s deadline — raise --eye-timeout; the board is fine"
        default: nil
        }

        CLIOut.summary("\n=== EYE-SCAN SUMMARY ===")
        CLIOut.summary("  bytes captured : \(transcript.utf8.count)")
        CLIOut.summary("  verdict        : \(eyescanVerdictLine(conclusion))")
        if let line = report.displayLine { CLIOut.summary("  firmware says  : \(line)") }
        if outcome.wedged {
            CLIOut.summary("  device         : WEDGED — stopped responding; PHYSICALLY REPLUG the board before the next run")
        } else if !outcome.completedViaStatus {
            CLIOut.summary("  device         : still streaming at the deadline — raise --eye-timeout, the board is fine")
        } else if outcome.returnedToMaskrom == false {
            CLIOut.summary("  device         : did NOT reset — replug before the next run")
        }

        var out = CLIResult(mode: .eyescan, pass: pass,
                            errorCode: errorCode, errorMessage: errorMessage)
        out.fill(device: device, soc: DetectProfiles.forPID(device.productID)?.soc ?? soc)
        out.cpuid = outcome.cpuid.map(ChipIdentity.hex)
        out.serial = outcome.cpuid.flatMap(ChipIdentity.serial(fromCpuid:))
        out.fill(variant: outcome.variant)
        out.rebootedToMaskrom = outcome.returnedToMaskrom
        out.eyescan = EyescanJSON(pass: pass, completed: outcome.completedViaStatus && report.scanCompleted,
                                  wedged: outcome.wedged, bytes: transcript.utf8.count,
                                  transcript: transcript)
        return out
    }

    /// Thread-safe progress heartbeat for the streaming drain.
    final class ProgressBox: @unchecked Sendable {
        private let lock = NSLock()
        private var bytes = 0
        private var nextBeat = 5.0
        private let ph: FileHandle?
        init(partialPath: String = "/tmp/eyescan_partial.txt") {
            FileManager.default.createFile(atPath: partialPath, contents: nil)
            ph = try? FileHandle(forWritingTo: URL(fileURLWithPath: partialPath))
        }
        func note(_ chunk: String, since start: Date) {
            lock.lock(); defer { lock.unlock() }
            bytes += chunk.utf8.count
            if let d = chunk.data(using: .utf8) { ph?.write(d) }   // incremental capture (survives a kill)
            let el = Date().timeIntervalSince(start)
            if el >= nextBeat {
                CLIOut.log("    [\(Int(el))s] \(bytes) B captured")
                nextBeat += 5.0
            }
        }
    }

    // MARK: - detect

    static func runDetect(args: CLIArguments) async throws -> CLIResult {
        let transport = try RkUsbTransportLibusb()
        let devices = try transport.discoverDevices()
        guard let device = chooseDevice(from: devices, selectedDeviceID: args.selectedDeviceID) else {
            throw DDRToolError.noDevice
        }
        CLIOut.log("Device: \(device.productName) soc=\(device.socName ?? "?") pid=0x\(hex16(device.productID))")

        let root = CfgRepository.makeDefaultRootURL()
        let socName = DetectProfiles.forPID(device.productID)?.soc ?? device.socName ?? ""
        let socFiles = ((try? CfgRepository(rootURL: root).discoverTestFiles()) ?? [])
            .filter { $0.socName == socName }

        // The self-contained detect cfg (rkbin DDR bin + Boot + osregdump +
        // reboot) lives in the SoC's DDRTestFiles dir alongside the real test
        // cfgs. Default there; --detect-cfg overrides the directory.
        let resourcesDir = args.detectCfgPath.map { URL(fileURLWithPath: ($0 as NSString).deletingLastPathComponent) }
            ?? root.appendingPathComponent(socName)

        let detector = DdrDetector(resourcesDir: resourcesDir)
        let out = try await detector.detect(transport: transport, device: device, socFiles: socFiles,
                                            readIdentity: true)

        CLIOut.log("\n=== OS_REG (raw) ===")
        for (i, w) in out.rawOsReg.enumerated() {
            CLIOut.log(String(format: "  OS_REG%-2d = 0x%08X", i, w))
        }
        CLIOut.summary("\n=== Detected geometry ===")
        CLIOut.summary("  \(out.geometry.summary())  rebootedToMaskrom: \(out.rebootedToMaskrom)")

        let matched = uniqueCfg(out, in: socFiles)
        CLIOut.summary("\n=== Exact-match soldering-test cfgs (\(socName)) ===")
        for c in out.candidates.prefix(6) {
            let t = c.dramType?.displayName ?? "?"
            CLIOut.summary(String(format: "  %@  (%@ %dMB %dCS)", c.entry.displayName, t, c.sizeMB, c.csCount))
        }
        if let matched {
            CLIOut.summary("\nAuto-select: \(matched.relativePath)")
        }

        var result = CLIResult(mode: .detect, pass: matched != nil)
        switch out.matchTier {
        case .uniqueByCoarse, .uniqueByTieBreak:
            break
        case .none:
            // The cfg library covers every shipped DRAM combination, so a zero-match
            // means the geometry read back doesn't correspond to any real part —
            // DDR init failed. That is a board verdict: FAIL (exit 2), no errorCode.
            CLIOut.summary("  (none)\n\nFAIL: the decoded geometry matches no cfg — DDR is uninitialised or defective.")
        case .ambiguous:
            // Geometry decoded fine and DID match — just not uniquely (candidates
            // share type+capacity+CS and tie-break didn't converge). The board is
            // not bad; the tool can't choose. Needs a human → exit 1.
            CLIOut.summary("\nMultiple cfgs share this exact (type + capacity + CS) — they differ only in die composition — pick one manually.")
            result.errorCode = .ambiguousCfg
            result.errorMessage = "\(out.candidates.count) cfgs match; none uniquely"
        }
        result.fill(device: device, soc: socName)
        result.cpuid = out.cpuid.map(ChipIdentity.hex)
        result.serial = out.cpuid.flatMap(ChipIdentity.serial(fromCpuid:))
        result.fill(variant: out.variant)
        result.rebootedToMaskrom = out.rebootedToMaskrom
        result.detect = DetectJSON.from(out, cfg: matched?.displayName)
        return result
    }

    // MARK: - solder

    /// detect → test on ONE transport, then reboot to bootrom.
    static func runSolder(args: CLIArguments) async throws -> CLIResult {
        let transport = try RkUsbTransportLibusb()
        let devices = try transport.discoverDevices()
        guard let device = chooseDevice(from: devices, selectedDeviceID: args.selectedDeviceID) else {
            throw DDRToolError.noDevice
        }
        CLIOut.log("Device: \(device.productName) soc=\(device.socName ?? "?") pid=0x\(hex16(device.productID))")

        let root = CfgRepository.makeDefaultRootURL()
        let socName = DetectProfiles.forPID(device.productID)?.soc ?? device.socName ?? ""
        let socFiles = ((try? CfgRepository(rootURL: root).discoverTestFiles()) ?? [])
            .filter { $0.socName == socName }
        let resourcesDir = args.detectCfgPath.map { URL(fileURLWithPath: ($0 as NSString).deletingLastPathComponent) }
            ?? root.appendingPathComponent(socName)

        // ── detect WITHOUT reboot: keeps the DDR Test Tool Boot resident + the
        //    transport open. Steps unchanged; only the ④ reboot is skipped.
        let detector = DdrDetector(resourcesDir: resourcesDir)
        let out = try await detector.detect(transport: transport, device: device,
                                            socFiles: socFiles, reboot: false, readIdentity: true)
        CLIOut.log("\n=== Detected: \(out.geometry.summary()) ===")

        var result = CLIResult(mode: .solder, pass: false)
        result.fill(device: device, soc: socName)
        result.cpuid = out.cpuid.map(ChipIdentity.hex)
        result.serial = out.cpuid.flatMap(ChipIdentity.serial(fromCpuid:))
        result.fill(variant: out.variant)

        guard let matched = uniqueCfg(out, in: socFiles) else {
            // Same split as --detect: no match at all is a board verdict (exit 2);
            // an ambiguous group is the tool's problem (exit 1). Either way, reboot
            // so the device is left in maskrom — detect ran with reboot:false, and
            // just closing the handle left it in the resident-firmware state,
            // reported as rebootedToMaskrom:null when the truth was false.
            let ambiguous = out.matchTier == .ambiguous
            CLIOut.summary(ambiguous
                ? "Ambiguous match (\(out.candidates.count) cfgs) — cannot auto-test; pick a cfg manually."
                : "No cfg matches the decoded geometry — FAIL (DDR uninitialised or defective).")
            let rebooted = await detector.rebootToMaskrom(transport: transport, device: device)
            try? transport.close()
            result.errorCode = ambiguous ? .ambiguousCfg : nil
            result.errorMessage = ambiguous ? "\(out.candidates.count) cfgs match; none uniquely" : nil
            result.rebootedToMaskrom = rebooted
            result.detect = DetectJSON.from(out, cfg: nil)
            return result
        }
        CLIOut.log("Matched cfg: \(matched.relativePath)")

        // ── test on the SAME transport with skipBoot: reuse the resident Boot
        //    (no downloadBoot, no reboot).
        CLIOut.log("\n=== Running test with skipBoot on the resident Boot (no reboot) ===")
        let engine = TestExecutionEngine(parser: CfgBinaryParser(), transport: transport) { entry in
            CLIOut.log("[\(entry.level.rawValue)] \(entry.code) \(entry.message)")
        }
        let run = await engine.run(
            cfgPath: matched.absolutePath,
            selectedDeviceID: args.selectedDeviceID,
            skipBoot: true,
            keepTransportOpen: true   // keep open so we can reboot to bootrom below
        )
        CLIOut.summary("\n=== detect→test result: \(run.outcome.rawValue) state=\(run.state.rawValue) bootSucceeded=\(run.bootSucceeded)"
            + (run.failure.map { " failure=\($0.rawValue)" } ?? "") + " ===")

        // Return the device to a clean bootrom. The CLI is one-shot with no persistent keep-alive
        // handle (unlike the GUI), so leaving it in the resident test-firmware state is fragile —
        // reboot so the next operation starts from maskrom. Runs the SoC's detect-cfg reboot payload.
        let rebooted = await detector.rebootToMaskrom(transport: transport, device: device)
        CLIOut.summary("=== reboot to bootrom: \(rebooted ? "OK (re-enumerated in maskrom)" : "sent") ===")

        // A transport/cfg failure means the DDR was never judged — exit 1. ONLY
        // FailureKind.deviceVerdict (resultCode != 0) yields exit 2.
        let conclusion = RunConclusion.solder(run)
        let pass = conclusion == .passed
        result.pass = pass
        result.errorCode = switch conclusion {
        case .inconclusive(let reason): CLIErrorCode.from(reason)
        case .passed, .deviceFailed: nil
        }
        result.errorMessage = result.errorCode == nil ? nil
            : run.logs.last(where: { $0.level == .error })?.message
        result.rebootedToMaskrom = rebooted
        result.detect = DetectJSON.from(out, cfg: matched.displayName)
        result.solder = SolderJSON(pass: pass, cfg: matched.displayName,
                                   bootSucceeded: run.bootSucceeded,
                                   log: ResultLogWriter().render(result: run, sourceCfgPath: matched.absolutePath))
        return result
    }

    // MARK: - helpers

    private static func hex16(_ value: UInt16) -> String {
        String(format: "%04X", value)
    }

    private static func chooseDevice(from devices: [UsbDevice], selectedDeviceID: String?) -> UsbDevice? {
        if devices.isEmpty { return nil }
        if let selectedDeviceID {
            return devices.first(where: { $0.deviceID == selectedDeviceID })
        }
        return devices.first
    }
}
