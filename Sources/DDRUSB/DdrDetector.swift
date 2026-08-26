// Sources/DDRUSB/DdrDetector.swift
import DDRCore
import Foundation

public struct DetectOutcome: Sendable {
    public let rawOsReg: [UInt32]
    public let geometry: DetectedGeometry
    public let candidates: [CfgAutoSelect.Candidate]
    public let matchTier: CfgAutoSelect.MatchTier
    public let rebootedToMaskrom: Bool
    /// Raw CPUID from OTP; nil when unsupported or the read did not complete.
    public let cpuid: [UInt8]?
    /// Which variant of the model this chip is (RK3588S2, RK3566PRO, RK3576J …);
    /// nil when the identity probe did not run or read no variant field.
    public let variant: ChipVariant?
}

/// What driving one probe item produced. `returned` distinguishes "the device
/// finished the item" from "we gave up waiting" — the detector's diagnostics
/// could not tell those apart before.
struct ProbeItemRun: Sendable {
    let captured: String
    let returned: Bool
    let statusPolls: Int
    let statusFailures: Int
}

public enum DetectError: Error, LocalizedError, Sendable {
    case unsupportedSoc
    case cfgPayloadMissing(String)
    case noOsReg

    /// Without LocalizedError these surfaced as "DDRUSB.DetectError error 1." —
    /// useless in the CLI's `errorMessage` and in any log that renders them.
    public var errorDescription: String? {
        switch self {
        case .unsupportedSoc:
            return "This SoC has no detect profile (unsupported USB PID)"
        case .cfgPayloadMissing(let name):
            return "Detect cfg is missing its \(name) payload"
        case .noOsReg:
            return "The osregdump probe returned no OS_REG words"
        }
    }
}

/// Orchestrates the whole DDR auto-detect flow over pure USB (no xrock).
///
/// Everything the flow needs is packaged into ONE self-contained detect cfg
/// (see tools/ddr-autodetect/build.sh): the auto-probing rkbin DDR bin
/// ("ddrbin"), the DDR Test Tool loader ("Boot"), the OS_REG probe ("osregdump")
/// and the reboot-to-maskrom payload ("reboot"). The cfg is a PACKAGING
/// container only — this detector pulls each payload out of the parsed cfg
/// (`plan.embeddedBins`) and drives the fixed sequence itself with raw transport
/// primitives. It deliberately does NOT run the cfg through TestExecutionEngine:
/// the sequence is non-standard (two 0x471 boot stages, read-back over USB, and
/// a reboot that must fire only after capture), which the engine's
/// "boot once, run each item in file order for pass/fail" model can't express.
public actor DdrDetector {
    /// One probe item (osregdump / otpdump), driven to the point where the DEVICE
    /// says it is done.
    ///
    /// Completion is a device STATE (`testDeviceReady` word1 == finished), NOT a
    /// content marker: the probe's last bytes can arrive after the text already
    /// parses, and returning on the text alone left the loader still inside the
    /// item — the next `downloadItem` then went to a firmware that wasn't back in
    /// its command loop.
    ///
    /// The polling rule is transcribed from `EyescanRunner`, where it was measured
    /// on hardware: opcode 0 and a producing item are served by the SAME device-side
    /// loop, so a status poll issued while printf is still handing back data
    /// contends with the item. Poll ONLY when the ring has gone quiet — by then the
    /// device answers instantly.
    ///
    /// Never throws on a status failure or on the deadline: it returns whatever was
    /// captured with `returned == false`, which is exactly what this code did before
    /// it looked at status at all. The caller decides whether the capture is usable.
    static func runProbeItem(transport: UsbTransport, item: CfgItem, payload: Data,
                             base: UInt32, timeout: TimeInterval) async throws -> ProbeItemRun {
        try transport.downloadItem(item: item, payload: payload, address: base)
        try transport.runItem(item: item, address: base)

        var captured = ""
        var returned = false
        var polls = 0, failures = 0
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let s = try? transport.readPrintf(), !s.isEmpty {
                captured += "\n" + s
                continue                       // data still flowing → do NOT poll status
            }
            polls += 1
            do {
                if try transport.testDeviceReady().phase == .finished {
                    returned = true
                    break
                }
            } catch {
                failures += 1                  // transient: retry, don't abort
            }
            try? await Task.sleep(nanoseconds: 40_000_000)
        }
        return ProbeItemRun(captured: captured, returned: returned,
                            statusPolls: polls, statusFailures: failures)
    }

    private let resourcesDir: URL   // dir holding the detect cfg
    private let parser = CfgBinaryParser()

    public init(resourcesDir: URL) {
        self.resourcesDir = resourcesDir
    }

    /// `reboot` (default true) controls only whether the ④ reboot-to-maskrom step
    /// runs — the detect STEPS (ddrbin → Boot → osregdump) are unchanged. Pass
    /// false to keep the device in its booted state and the `transport` OPEN, so a
    /// caller can hand the same session straight to a test with `skipBoot: true`
    /// (the resident DDR Test Tool Boot is reused). This is the unified
    /// detect→test path that avoids the reboot entirely (and thus the RK3288
    /// populated-eMMC reboot limitation).
    public func detect(transport: UsbTransport, device: UsbDevice,
                       socFiles: [TestFileEntry], reboot: Bool = true,
                       readIdentity: Bool = false) async throws -> DetectOutcome {
        guard let profile = DetectProfiles.forPID(device.productID) else {
            throw DetectError.unsupportedSoc
        }
        let cfgURL = resourcesDir.appendingPathComponent(profile.detectCfgName)
        let plan = try parser.parse(url: cfgURL)

        // Pull each payload out of the packaged cfg by (case-insensitive) name.
        func payload(_ name: String) -> Data? { plan.payload(named: name) }
        guard let ddrBin = payload("ddrbin") else {
            throw DetectError.cfgPayloadMissing("ddrbin")
        }
        guard let bootBin = payload("Boot") else {
            throw DetectError.cfgPayloadMissing("Boot")
        }
        guard let probeBin = payload("osregdump") else {
            throw DetectError.cfgPayloadMissing("osregdump")
        }
        let rebootBin = payload("reboot")   // optional; absent → no auto-reboot
        let base = plan.downloadBaseAddress

        // --- phase timing (diagnostic; stderr) ---
        var mark = Date()
        func phase(_ label: String) {
            let now = Date()
            fputs("[DDRDetect/timing] \(label): \(Int(now.timeIntervalSince(mark) * 1000))ms\n", stderr)
            mark = now
        }

        if !transport.isOpen { try transport.open(device: device) }

        // ① rkbin DDR bin via 0x471 → SoC auto-detects DRAM and writes OS_REG.
        let ddrItem = CfgItem(name: "ddrbin", payloadOffset: 0, payloadLength: ddrBin.count)
        try transport.downloadBoot(item: ddrItem, payload: ddrBin)
        phase("① rkbin download (\(ddrBin.count)B)")
        // Let the rkbin DDR bin finish auto-detect + write OS_REG before we load
        // the Test Tool Boot over it. This is a floor, not a correctness
        // dependency: if OS_REG isn't ready the capture loop below re-reads it.
        try await Task.sleep(nanoseconds: 600_000_000)
        phase("settle-after-rkbin")

        // ② DDR Test Tool Boot via 0x471 → provides the resident USB service +
        // 0x80 printf channel + service-vector table the probe calls.
        let bootItem = CfgItem(name: "Boot", payloadOffset: 0, payloadLength: bootBin.count)
        try transport.downloadBoot(item: bootItem, payload: bootBin)
        phase("② Test Tool Boot download (\(bootBin.count)B)")
        try await Task.sleep(nanoseconds: 300_000_000)   // boot settle

        // ③ osregdump: bulk download + RunMemory, then drain the printf channel.
        // Retried in-session (resident Boot; no reset) if the drain races — the
        // 0xFDCC1004 USB-ring channel makes the first try reliable in practice,
        // this is a safety net.
        let probeItem = CfgItem(name: "osregdump", payloadOffset: 0, payloadLength: probeBin.count)
        var captured = ""
        var words: [UInt32]? = nil
        var tries = 0
        var returned = false
        // Overall bound preserves the old worst case (20 tries x 480ms fixed drain
        // ~= 10s). Each try may now wait longer than that drain, but it exits as
        // soon as the device reports the item done — normally tens of ms.
        let osregDeadline = Date().addingTimeInterval(10)
        while words == nil, tries < 20, Date() < osregDeadline {
            tries += 1
            guard let run = try? await Self.runProbeItem(transport: transport, item: probeItem,
                                                         payload: probeBin, base: base, timeout: 1.5)
            else { break }
            captured += run.captured
            returned = run.returned
            words = OsRegDecoder.parseProbeOutput(captured)
        }
        phase("③ osregdump capture (\(tries) tr\(tries == 1 ? "y" : "ies"), item \(returned ? "returned" : "DID NOT return"))")
        guard let words else { throw DetectError.noOsReg }

        let geo = OsRegDecoder.decode(words)
        let coarse = CfgAutoSelect.rank(geometry: geo, socFiles: socFiles)
        // 两级匹配：L1>1 时，解析这几个候选的 forceinit 参数做组内 tie-break。
        var candidates = coarse
        var tier: CfgAutoSelect.MatchTier
        switch coarse.count {
        case 0:
            tier = .none
        case 1:
            tier = .uniqueByCoarse
        default:
            let parser = CfgBinaryParser()
            let pairs = coarse.map { c -> (candidate: CfgAutoSelect.Candidate, forceinit: CfgItem?) in
                let plan = try? parser.parse(url: URL(fileURLWithPath: c.entry.absolutePath))
                return (c, plan?.items.first { $0.name == "forceinit" })
            }
            let narrowed = CfgAutoSelect.tieBreak(pairs, decoded: geo)
            if narrowed.count == 1 {
                candidates = narrowed
                tier = .uniqueByTieBreak
            } else {
                tier = .ambiguous   // 保留原始 coarse 候选，交回上层手动
            }
        }

        // ③b otpdump: per-chip identity on the same resident Boot. After the geometry capture and
        // never fatal — a failure just yields no identity. OPT-IN (`readIdentity`), because it is
        // an extra item download+run on a path the GUI drives for every soldering test, and only
        // the CLI reports the identity. Callers that do not want it pay nothing.
        var cpuid: [UInt8]? = nil
        var variant: ChipVariant? = nil
        var otpDump: OtpDump? = nil
        if readIdentity, let idProbe = profile.idProbe, let otpBin = payload("otpdump") {
            let otpItem = CfgItem(name: "otpdump", payloadOffset: 0, payloadLength: otpBin.count)
            var otpReturned = false
            do {
                // Parse ONCE, on the finished capture. The old loop re-parsed every
                // 40ms and broke on the first complete-looking text — which is how a
                // still-running item got left behind.
                let run = try await Self.runProbeItem(transport: transport, item: otpItem,
                                                      payload: otpBin, base: base, timeout: 3)
                otpReturned = run.returned
                if let dump = ChipIdentity.parseOtpDump(run.captured,
                                                        fallbackBaseByte: idProbe.legacyBaseByte) {
                    otpDump = dump
                    if let family = profile.family {
                        variant = ChipVariant.resolve(family: family, dump: dump)
                    }
                    cpuid = dump.slice(at: idProbe.cpuidOffset, count: ChipIdentity.cpuidLength)
                }
            } catch {
                cpuid = nil
                variant = nil
                otpDump = nil
            }
            // The raw dump goes to the diagnostic line as well: every variant field is
            // a couple of bits inside these bytes, and when a reading looks wrong the
            // bytes are the only thing that can settle it (the decode rules come from
            // the vendor kernel, which is not a source we can re-verify at runtime).
            let raw = otpDump.map { "otp[0x\(String($0.baseByte, radix: 16))+]=\(ChipIdentity.hex($0.bytes))" }
                ?? "otp=unreadable"
            phase("③b otpdump capture (cpuid \(cpuid == nil ? "unavailable" : "ok")"
                  + ", item \(otpReturned ? "returned" : "DID NOT return")"
                  + ", 型号 \(variant?.name ?? "未判定"), \(raw))")
        }

        // ④ reboot to maskrom, then wait for re-enumeration. Runs ONLY here,
        // explicitly, after capture — never mid-capture (the whole reason this
        // detector doesn't hand the cfg to TestExecutionEngine).
        var rebooted = false
        if reboot, let rebootBin {
            rebooted = (try? await rebootToMaskrom(transport: transport, payload: rebootBin,
                                                   base: base, device: device)) ?? false
        }
        phase(reboot ? "④ reboot + re-enum (rebooted=\(rebooted))"
                     : "④ reboot SKIPPED (unified detect→test; transport kept open)")
        return DetectOutcome(rawOsReg: words, geometry: geo, candidates: candidates,
                             matchTier: tier, rebootedToMaskrom: rebooted, cpuid: cpuid,
                             variant: variant)
    }

    /// Reboot a RESIDENT (post-test) device back to maskrom using the SoC's detect-cfg reboot payload,
    /// on the still-open transport. For one-shot CLI flows (`--detect-then-test`, `--cfg`) that have no
    /// persistent keep-alive handle: leaving the device in a booted state is fragile, so the CLI
    /// returns it to a clean bootrom. (The GUI instead holds its handle open across clicks.) Returns
    /// whether the device re-enumerated. No-op (false) if the SoC/cfg/reboot payload is unavailable.
    public func rebootToMaskrom(transport: UsbTransport, device: UsbDevice) async -> Bool {
        guard let profile = DetectProfiles.forPID(device.productID),
              let plan = try? parser.parse(url: resourcesDir.appendingPathComponent(profile.detectCfgName)),
              let rebootBin = plan.payload(named: "reboot") else { return false }
        return (try? await rebootToMaskrom(transport: transport, payload: rebootBin,
                                           base: plan.downloadBaseAddress, device: device)) ?? false
    }

    /// Runs the reboot-to-maskrom payload (extracted from the detect cfg) on the
    /// already-booted device, then waits for it to drop and re-enumerate in a
    /// fresh MASKROM. The payload writes the boot-mode magic + triggers a CRU
    /// soft-reset and does not return, so the run "fails" mid-transfer by design.
    private func rebootToMaskrom(transport: UsbTransport, payload: Data,
                                 base: UInt32, device: UsbDevice) async throws -> Bool {
        let item = CfgItem(name: "reboot", payloadOffset: 0, payloadLength: payload.count)
        try? transport.downloadItem(item: item, payload: payload, address: base)
        try? transport.runItem(item: item, address: base)   // device resets mid-transfer
        try? transport.close()
        // Wait for the device to drop and re-appear (fresh MASKROM).
        for _ in 0..<40 {                              // up to ~6s
            try? await Task.sleep(nanoseconds: 150_000_000)
            let probe = try? RkUsbTransportLibusb()
            if let list = try? probe?.discoverDevices(),
               list.contains(where: { $0.productID == device.productID }) {
                return true
            }
        }
        return false
    }
}
