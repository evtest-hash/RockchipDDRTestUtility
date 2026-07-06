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

        // ① rkbin DDR bin via 0x471
        if !transport.isOpen { try transport.open(device: device) }
        let ddrItem = CfgItem(name: "ddrbin", payloadOffset: 0, payloadLength: ddrBin.count)
        try transport.downloadBoot(item: ddrItem, payload: ddrBin)
        try await Task.sleep(nanoseconds: 1_500_000_000)

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
                                      skipBoot: false, keepTransportOpen: true)
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
        }
        guard let words else { throw DetectError.noOsReg }

        let geo = OsRegDecoder.decode(words)
        let candidates = CfgAutoSelect.rank(geometry: geo, socFiles: socFiles)

        // ④⑤ reboot to maskrom, then wait for re-enumeration
        let rebooted = (try? await rebootToMaskrom(transport: transport, plan: plan, device: device)) ?? false
        return DetectOutcome(rawOsReg: words, geometry: geo, candidates: candidates,
                             rebootedToMaskrom: rebooted)
    }

    private func rebootToMaskrom(transport: UsbTransport, plan: CfgTestPlan,
                                 device: UsbDevice) async throws -> Bool {
        guard let item = plan.items.first(where: { $0.name.caseInsensitiveCompare("reboot") == .orderedSame }),
              let pay = plan.embeddedBins["reboot"] else { return false }
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
