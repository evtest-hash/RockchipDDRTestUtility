// Sources/DDRUSB/DdrDetector.swift
import DDRCore
import Foundation

public struct DetectOutcome: Sendable {
    public let rawOsReg: [UInt32]
    public let geometry: DetectedGeometry
    public let candidates: [CfgAutoSelect.Candidate]
    public let matchTier: CfgAutoSelect.MatchTier
    public let rebootedToMaskrom: Bool
}

public enum DetectError: Error, Sendable {
    case unsupportedSoc
    case cfgPayloadMissing(String)
    case noOsReg
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
                       socFiles: [TestFileEntry], reboot: Bool = true) async throws -> DetectOutcome {
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
        while words == nil, tries < 20 {
            tries += 1
            do {
                try transport.downloadItem(item: probeItem, payload: probeBin, address: base)
                try transport.runItem(item: probeItem, address: base)
            } catch { break }
            for _ in 0..<12 {
                if let s = try? transport.readPrintf(), !s.isEmpty { captured += "\n" + s }
                try? await Task.sleep(nanoseconds: 40_000_000)
            }
            words = OsRegDecoder.parseProbeOutput(captured)
        }
        phase("③ osregdump capture (\(tries) tr\(tries == 1 ? "y" : "ies"))")
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
                             matchTier: tier, rebootedToMaskrom: rebooted)
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
