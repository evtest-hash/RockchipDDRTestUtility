// Sources/DDRUSB/DdrDetector.swift
import DDRCore
import Foundation

public struct DetectOutcome: Sendable {
    public let rawOsReg: [UInt32]
    public let geometry: DetectedGeometry
    public let candidates: [CfgAutoSelect.Candidate]
    public let rebootedToMaskrom: Bool
}

public enum DetectError: Error, Sendable {
    case unsupportedSoc
    case ddrBinMissing(String)
    case bootFailed(String)
    case noOsReg
}

/// Orchestrates the whole DDR auto-detect flow (verified in the CLI spike
/// `RockchipDDRTestUtilityCLI.runDetect`): download the auto-probing rkbin DDR
/// bin, run the detect cfg to dump OS_REG over the printf channel, decode the
/// geometry, rank candidate soldering-test cfgs, then reboot to maskrom and
/// wait for re-enumeration so the caller can proceed with the normal test flow.
public actor DdrDetector {
    private let resourcesDir: URL   // dir holding detect cfgs (autodetect resources)
    private let rkbinDir: URL       // dir holding rkbin DDR bins
    private let parser = CfgBinaryParser()

    public init(resourcesDir: URL, rkbinDir: URL) {
        self.resourcesDir = resourcesDir
        self.rkbinDir = rkbinDir
    }

    public func detect(transport: UsbTransport, device: UsbDevice,
                       socFiles: [TestFileEntry]) async throws -> DetectOutcome {
        guard let profile = DetectProfiles.forPID(device.productID) else {
            throw DetectError.unsupportedSoc
        }
        let ddrBinURL = rkbinDir.appendingPathComponent(profile.ddrBinName)
        guard let ddrBin = try? Data(contentsOf: ddrBinURL) else {
            throw DetectError.ddrBinMissing(ddrBinURL.path)
        }
        let cfgURL = resourcesDir.appendingPathComponent(profile.detectCfgName)
        let plan = try parser.parse(url: cfgURL)

        // --- phase timing (diagnostic; stderr) ---
        var mark = Date()
        func phase(_ label: String) {
            let now = Date()
            fputs("[DDRDetect/timing] \(label): \(Int(now.timeIntervalSince(mark) * 1000))ms\n", stderr)
            mark = now
        }

        // ① rkbin DDR bin via 0x471
        if !transport.isOpen { try transport.open(device: device) }
        let ddrItem = CfgItem(name: "ddrbin", payloadOffset: 0, payloadLength: ddrBin.count)
        try transport.downloadBoot(item: ddrItem, payload: ddrBin)
        phase("① open+rkbin download (\(ddrBin.count)B)")
        // Let the rkbin DDR bin finish auto-detect + write OS_REG before we load
        // the Test Tool Boot over it. DDR training on RK3568 completes well under
        // this; if it ever isn't ready the OS_REG parse below simply misses and
        // the in-session retry loop re-reads it, so this is a floor, not a
        // correctness dependency.
        try await Task.sleep(nanoseconds: 600_000_000)
        phase("settle-after-rkbin")

        // ②③ run detect cfg (Boot + osregdump) on the same handle; collect printf.
        // NOTE: adapted from the brief's live-mutating closure (`captured += ...`
        // inside the `@Sendable` logHandler), which Swift rejects at compile time
        // ("mutation of captured var in concurrently-executing code") — a `var`
        // can't be mutated inside a `@Sendable` closure. Instead, derive the
        // captured printf text from the returned `ExecutionResult.logs` once
        // `run()` has completed (same content: `await` only returns after every
        // log entry has been appended), mirroring the CLI spike's own
        // `result.logs.filter { $0.code == "INFO_PRINTF" }` approach.
        let engine = TestExecutionEngine(parser: parser, transport: transport)
        let result = await engine.run(cfgPath: cfgURL.path, selectedDeviceID: device.deviceID,
                                      skipBoot: false, keepTransportOpen: true, bootSettleMs: 300)
        phase("②③ engine.run (Test Tool Boot + osregdump)")
        var captured = result.logs
            .filter { $0.code == "INFO_PRINTF" }
            .map { $0.message }
            .joined(separator: "\n")
        var words = OsRegDecoder.parseProbeOutput(captured)

        // retry the probe item in-session (resident Boot; no reset) if the drain raced
        if words == nil,
           let item = plan.items.first(where: { $0.name.caseInsensitiveCompare("osregdump") == .orderedSame }),
           let pay = plan.embeddedBins["osregdump"] {
            var tries = 0
            while words == nil, tries < 20 {
                tries += 1
                do {
                    try transport.downloadItem(item: item, payload: pay, address: plan.downloadBaseAddress)
                    try transport.runItem(item: item, address: plan.downloadBaseAddress)
                } catch { break }
                for _ in 0..<12 {
                    if let s = try? transport.readPrintf(), !s.isEmpty { captured += "\n" + s }
                    try? await Task.sleep(nanoseconds: 40_000_000)
                }
                words = OsRegDecoder.parseProbeOutput(captured)
            }
            phase("capture retries")
        }
        guard let words else { throw DetectError.noOsReg }

        let geo = OsRegDecoder.decode(words)
        let candidates = CfgAutoSelect.rank(geometry: geo, socFiles: socFiles)

        // ④⑤ reboot to maskrom, then wait for re-enumeration. Deliberately AFTER
        // the OS_REG capture + retry loop above: reboot is a standalone payload
        // (not a record in the detect cfg run through engine.run above), so it
        // only ever fires here, explicitly — never mid-capture.
        let rebooted = (try? await rebootToMaskrom(transport: transport, profile: profile,
                                                    plan: plan, device: device)) ?? false
        phase("④⑤ reboot + re-enum (rebooted=\(rebooted))")
        return DetectOutcome(rawOsReg: words, geometry: geo, candidates: candidates,
                             rebootedToMaskrom: rebooted)
    }

    /// Loads the per-SoC standalone reboot-to-maskrom payload (raw, NOT part of
    /// the detect cfg — see DetectProfile.rebootBinName) and runs it directly on
    /// the already-booted device, then waits for the device to drop and
    /// re-enumerate in maskrom. Kept as a distinct raw file so it can never be
    /// auto-fired by TestExecutionEngine.run() (which executes every non-Boot
    /// record of a cfg in file order) — it must run only once this function is
    /// called explicitly, after OS_REG capture has succeeded.
    private func rebootToMaskrom(transport: UsbTransport, profile: DetectProfile,
                                 plan: CfgTestPlan, device: UsbDevice) async throws -> Bool {
        let rebootURL = resourcesDir.appendingPathComponent(profile.rebootBinName)
        guard let pay = try? Data(contentsOf: rebootURL) else { return false }
        let item = CfgItem(name: "reboot", payloadOffset: 0, payloadLength: pay.count)
        try? transport.downloadItem(item: item, payload: pay, address: plan.downloadBaseAddress)
        try? transport.runItem(item: item, address: plan.downloadBaseAddress)   // device resets mid-transfer
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
