// Sources/DDRUSB/EyescanRunner.swift
import DDRCore
import Foundation

/// Drives the 3-step eye-scan capture and streams the device's USB printf
/// channel (opcode 0x80) into a growing transcript.
///
/// Flow (see tools/ddr-eyescan/re/README.md and the design spec):
///   ① standard DDR bin (0x471) — trains the PHY; the per-DQ baseline persists
///      in PHY/controller HW across the bin swap.
///   ② DDR Test Tool blob (0x471) — starts the TWO-CORE resident firmware:
///      core 0 services USB 0x80 (drains the printf ring), core 1 runs items.
///   ③ eye-scan item — the relocated measurement core; its PARAM block is filled
///      from the detected geometry, then it's downloaded to `itemBase` and run.
///      Core 1 scans and PRODUCES into the ring; core 0 drains it to the host.
///
/// Eye-scan output can't be buffered on-device (~189 KB), so we keep polling
/// `readPrintf()` until an end-marker shows up or the timeout elapses. Mirrors
/// `DdrDetector`'s style: transport/device are method params, driven with the
/// same raw transport primitives.
public actor EyescanRunner {
    public init() {}

    /// End of the item's code region. The train-only bin (step ①) builds the
    /// detected a1 / DRAM-info in the BSS ABOVE this address; downloading only
    /// [itemBase, rawEnd) leaves that BSS intact so the item runs against the
    /// on-device-detected geometry (no host params). Any device layout with a
    /// different code/BSS split would change this — it is a property of the bin.
    static let rawEnd: UInt32 = 0xFDCC_F510

    public func run(transport: UsbTransport,
                    device: UsbDevice,
                    ddrBin: Data,
                    ddrTestTool: Data,
                    itemBin: Data,
                    itemBase: UInt32 = 0xFDCC_4000,
                    timeout: TimeInterval,
                    rebootBin: Data? = nil,
                    onProgress: (@Sendable (String) async -> Void)? = nil) async throws -> String {
        if !transport.isOpen { try transport.open(device: device) }

        // Per-step wall-clock instrumentation (diagnostic; prints to stdout for CLI runs).
        let t0 = Date()
        func mark(_ label: String) { print(String(format: "  [+%5.1fs] %@", Date().timeIntervalSince(t0), label)) }

        let dttItem = CfgItem(name: "ddrtesttool", pathHint: nil, nameOffset: 0,
                              payloadOffset: 0, payloadLength: ddrTestTool.count)
        if !ddrBin.isEmpty {
            // ① standard DDR bin — trains the PHY. Download ONCE, lenient: the bin
            //    LAUNCHES and runs long (train, or train+full-scan for the capture
            //    flow), so the device takes over before the final-chunk ACK — that
            //    is success, not failure. Do NOT strict-then-lenient re-download: the
            //    retry would hit the now-busy (running) device and error out
            //    ("4096 got -99"). step② below polls until it returns to maskrom.
            let ddrItem = CfgItem(name: "ddrbin", pathHint: nil, nameOffset: 0,
                                  payloadOffset: 0, payloadLength: ddrBin.count)
            try transport.downloadBoot(item: ddrItem, payload: ddrBin, lenientFinalChunk: true)
            mark("① stage-1 bin launched (\(ddrBin.count)B), running on-device")
            try? await Task.sleep(nanoseconds: 400_000_000)

            // ② DDR Test Tool — resident two-core USB 0x80 service. Step①'s bin ran
            //    for TENS OF SECONDS and RE-ENUMERATES the device (new USB address)
            //    when it finishes, so each attempt must RE-DISCOVER + RE-OPEN the
            //    (possibly new) device, not reuse the stale step① handle. Poll ~90s.
            var booted = false
            for _ in 0..<90 {
                do {
                    if transport.isOpen { try? transport.close() }
                    let devs = try transport.discoverDevices()
                    guard let d = devs.first(where: { $0.productID == device.productID }) ?? devs.first else {
                        throw DDRToolError.transportError("no maskrom device enumerated")
                    }
                    try transport.open(device: d)
                    try transport.downloadBoot(item: dttItem, payload: ddrTestTool, lenientFinalChunk: true)
                    booted = true
                    break
                } catch {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
            }
            if !booted { throw DDRToolError.transportError("DTT boot failed") }
        } else {
            // ② only. No train-only step (e.g. RK3576 option-B: the eyescan-item
            //    self-trains). Boot the DTT tolerantly — a lost final-chunk ACK means
            //    the long-running 0x471 bin launched, not that it failed.
            do {
                try transport.downloadBoot(item: dttItem, payload: ddrTestTool, lenientFinalChunk: false)
            } catch {
                try transport.downloadBoot(item: dttItem, payload: ddrTestTool, lenientFinalChunk: true)
            }
        }
        mark("② DDR Test Tool booted (\(ddrTestTool.count)B)")
        try? await Task.sleep(nanoseconds: 400_000_000)   // let core 0's service loop come up

        // ③ eye-scan item — download + run. NO host geometry.
        // RK3568 3-part model: a train-only bin (step ①) DETECTS geometry and leaves
        // a1/DRAM-info in the BSS ABOVE `rawEnd`, so there we download ONLY the code
        // region [itemBase, rawEnd) to keep that BSS (a1@0xFDCCFF40 / DRAM-info@0xFDCCFFB0)
        // alive across the reload. `rawEnd` is that model's (RK3568) address. For SoCs
        // whose item base sits AT/ABOVE rawEnd (e.g. RK3576/RK3588 PATH ②, where the
        // item is a small capture-relay that keeps NO mid-image survivors — itemBase
        // 0xFF004000 > rawEnd on RK3588) there is nothing to preserve: download the
        // whole item. Guard the subtraction so it never underflows UInt32 (→ SIGTRAP).
        let maxCode = itemBase < Self.rawEnd ? Int(Self.rawEnd - itemBase) : itemBin.count
        let dl = itemBin.prefix(min(itemBin.count, maxCode))
        let item = CfgItem(name: "eyescanitem", pathHint: nil, nameOffset: 0,
                           payloadOffset: 0, payloadLength: dl.count)
        try transport.downloadItem(item: item, payload: dl, address: itemBase)
        try transport.runItem(item: item, address: itemBase)
        mark("③ relay item downloaded (\(dl.count)B) + running @0x\(String(itemBase, radix: 16))")

        // ③ drain — STATE-BASED completion, but WITHOUT polling testDeviceReady on the hot path.
        // The relay item (core 1) forwards the filtered report over the ring, drains it, then
        // RETURNS so the DTT item-runner reports done. Completion is a device STATE (testDeviceReady
        // word1 == finished) — NOT a content marker (the report tail comes after "…done").
        //
        // Speed lesson (measured, vs the factory soldering test which drains fine): calling
        // testDeviceReady() every iteration is FATAL here. During a soldering memtest core 1 is
        // idle w.r.t. the ring, so the DTT answers opcode-0 instantly. During THIS relay, core 1
        // hammers the ring (PUTS + watermark spin) and contends with core 0's USB service, so an
        // opcode-0 (5 s timeout) can stall ~1 s — one per iteration throttled the whole drain to
        // ~500 B/s. Fix: drain 0x80 in a tight loop while data flows (readPrintf only), and probe
        // testDeviceReady ONLY when the ring goes idle (readPrintf empty) — by then core 1 has
        // finished producing, so opcode-0 answers instantly. `acknowledge:false`: the DTT ring
        // advances on the 0x80 read itself, so the extra ack round-trip is unnecessary.
        // Completion is DEVICE-SIGNALED only — no host-side content/timing judgement. The relay
        // item returns → the DTT item-runner sets status=done → testDeviceReady() reports finished.
        // We probe it only when the ring goes idle (readPrintf empty), because probing it while the
        // relay hammers the ring contends with core 0 and stalls opcode-0 (drops the drain to
        // ~500 B/s vs ~1 KB/s). The deadline is a hard safety timeout, not a completion signal.
        var transcript = ""
        // Drain-speed instrumentation: separate time spent in reads that RETURNED DATA from reads
        // that came back EMPTY (a 100 ms bulk-IN timeout). effective-when-data = the real USB-printf
        // throughput limit; empty-read time = pure waste (ring was empty when we polled).
        var dataBytes = 0, nData = 0, nEmpty = 0, maxChunk = 0
        var tData = 0.0, tEmpty = 0.0
        // DECOUPLE the UI from the USB drain. The drain MUST NEVER await onProgress: a slow UI
        // render must not be able to stall readPrintf / the device link. (That coupling — the
        // drain awaiting the main-actor UI callback per chunk — let a display change throttle the
        // USB pipeline.) Chunks go to a buffered, order-preserving stream; a SEPARATE task hands
        // them to onProgress at the UI's own pace. If the UI lags, chunks just queue here — the
        // drain keeps reading the device at full speed, structurally untouched by UI work.
        var uiEmit: AsyncStream<String>.Continuation!
        let uiStream = AsyncStream<String>(bufferingPolicy: .unbounded) { uiEmit = $0 }
        let uiTask = Task { for await chunk in uiStream { await onProgress?(chunk) } }
        let deadline = Date().addingTimeInterval(timeout)
        drain: while Date() < deadline {
            let t0 = Date()
            let s = try? transport.readPrintf(acknowledge: false)
            let dt = Date().timeIntervalSince(t0)
            if let s, !s.isEmpty {
                let n = s.utf8.count
                transcript += s
                dataBytes += n; nData += 1; tData += dt; maxChunk = max(maxChunk, n)
                uiEmit.yield(s)          // non-blocking + ordered: NEVER stall the drain on UI
                continue                 // keep draining fast — do NOT probe status while data flows
            }
            nEmpty += 1; tEmpty += dt
            // Ring idle → ask the device: has the item returned (status == done)?
            // Tolerant: a transient poll failure must not abort a run whose report is already
            // captured — the item returns then the DTT stays briefly busy, so retry, don't throw.
            guard let status = try? transport.testDeviceReady() else { continue }
            if status.phase == .finished || status.phase == .error {
                while let s = try? transport.readPrintf(acknowledge: false), !s.isEmpty {
                    transcript += s; dataBytes += s.utf8.count; nData += 1
                    uiEmit.yield(s)
                }
                mark("③ done via status (\(transcript.utf8.count)B)")
                break drain
            }
        }
        if Date() >= deadline { mark("③ drain hit \(Int(timeout))s deadline (device never reported done)") }
        let rate = tData > 0 ? Double(dataBytes)/tData : 0
        mark(String(format: "③ drain stats: %dB | data-reads %d in %.2fs = %.0f B/s (USB limit-when-data, avgchunk %dB, max %dB) | empty-reads %d in %.2fs (100ms-timeout waste)",
                    dataBytes, nData, tData, rate, nData>0 ? dataBytes/nData : 0, maxChunk, nEmpty, tEmpty))
        uiEmit.finish()   // USB drain done → no more chunks; the UI task drains its own buffer

        // Auto-return to maskrom: after the item returned (status=done, item-runner idle), download
        // and run the factory reboot payload (RK3588 boot-mode 0xFD588080=0xEF08A53C, CRU
        // 0xFD7C0C08=0xFDB9, from DDR自动探测.cfg). The device resets → next run starts from a clean
        // maskrom with NO manual replug. The runItem ack is lost (the device is rebooting) → lenient.
        if let rebootBin {
            let rb = CfgItem(name: "reboot", pathHint: nil, nameOffset: 0, payloadOffset: 0, payloadLength: rebootBin.count)
            try? transport.downloadItem(item: rb, payload: rebootBin, address: itemBase)
            try? transport.runItem(item: rb, address: itemBase)
            mark("④ reboot item sent → device returning to maskrom")
        }
        await uiTask.value   // let the decoupled UI delivery finish (overlaps the reboot above)
        return transcript
    }
}
