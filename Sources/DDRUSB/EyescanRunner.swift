// Sources/DDRUSB/EyescanRunner.swift
import DDRCore
import Foundation

/// Drives the eye-scan and streams the device's USB printf channel (opcode 0x80)
/// into a growing transcript.
///
/// Two cfg shapes reach this runner, distinguished by whether the cfg ships a
/// `trainonly` record (→ a non-empty `ddrBin`):
///
///   THREE-STEP (RK3568) — cfg has `trainonly`:
///     ① train-only bin (0x471) trains the PHY; the per-DQ baseline persists in
///        PHY/controller HW across the bin swap. ② DDR Test Tool (0x471).
///     ③ the small relocated measurement core runs as the item.
///
///   TWO-STEP (RK3576, RK3588) — no `trainonly`, `ddrBin` is empty:
///     ② DDR Test Tool (0x471) only, then ③ the WHOLE eyescan, relocated to
///        `itemBase`, runs as the item and self-inits/self-trains. There is no
///        stage ① because the eyescan does its own DDR bring-up.
///
/// In both shapes ② leaves a resident TWO-CORE firmware: core 0 services USB
/// (it alone answers bulk OUT, dispatches commands and drains the printf ring),
/// core 1 runs downloaded items. The item PRODUCES into the ring, core 0 drains
/// it to the host, and completion is the device's own status word — never a
/// content marker.
///
/// Output can't be buffered on-device, so we keep polling `readPrintf()` until
/// the device reports done or the timeout elapses. Mirrors `DdrDetector`'s
/// style: transport/device are method params, driven with the same raw
/// transport primitives.
public actor EyescanRunner {
    public init() {}

    /// What a run produced, beyond the transcript. The two flags matter to the
    /// caller because they decide what the operator has to do next.
    public struct Outcome: Sendable {
        /// Every byte the device streamed over 0x80.
        public let transcript: String
        /// The DEVICE signalled completion (item-runner status finished/error).
        /// False only means the drain hit its deadline — which is NOT the same as
        /// a wedge: an item that streams steadily but is slower than the timeout
        /// also lands here, and that board is perfectly healthy. See `wedged`.
        public let completedViaStatus: Bool
        /// The drain hit its deadline AND the device had gone silent for a while,
        /// so the item really has stopped. Only then is the board stuck: it stops
        /// answering altogether — including the reboot item — and a physical replug
        /// is the only recovery.
        public let wedged: Bool
        /// Raw CPUID read from OTP after the scan, or nil when this SoC ships no otpdump payload,
        /// its eye-scan loader is a different build, or the read did not complete. Never fatal.
        public let cpuid: [UInt8]?
        /// true — the reset was OBSERVED (the board left the bus, or came back on the
        ///        same socket under a new USB address).
        /// nil  — not attempted, or attempted and not observable. NOT the same as "it
        ///        did not reset": the absence window can be shorter than any polling
        ///        interval and the host may hand back the same address, so a reset that
        ///        did happen is routinely unobservable. The only definitive test is
        ///        whether the next 0x471 boot download succeeds.
        /// false — only when the reboot was deliberately skipped.
        public let returnedToMaskrom: Bool?
    }

    /// End of the item's code region — an RK3568 constant, applied globally (see the
    /// download site below for why the other SoCs survive that). In the RK3568 three-step
    /// model the train-only bin (step ①) builds the detected a1 / DRAM-info in the BSS
    /// ABOVE this address; downloading only [itemBase, rawEnd) leaves that BSS intact so
    /// the item runs against the on-device-detected geometry (no host params). It is a
    /// property of that bin's code/BSS split, so it should really be per-SoC.
    static let rawEnd: UInt32 = 0xFDCC_F510

    public func run(transport: UsbTransport,
                    device: UsbDevice,
                    ddrBin: Data,
                    ddrTestTool: Data,
                    itemBin: Data,
                    itemBase: UInt32 = 0xFDCC_4000,
                    timeout: TimeInterval,
                    rebootBin: Data? = nil,
                    /// The detect cfg's otpdump probe, when this SoC's eye-scan loader is the same
                    /// build the probe expects. Absent ⇒ no identity is read, flow unchanged.
                    otpBin: Data? = nil,
                    otpCpuidByteOffset: Int? = nil,
                    // How long the device must have been silent at the deadline before we call the
                    // board wedged rather than merely slow. Injectable so tests need not sleep.
                    stallSilence: TimeInterval = 5,
                    onProgress: (@Sendable (String) async -> Void)? = nil) async throws -> Outcome {
        if !transport.isOpen { try transport.open(device: device) }

        // Per-step wall-clock instrumentation (diagnostic; goes to stderr so the
        // CLI's --json stdout stays a pure JSON object — these timing marks are
        // progress, not the result).
        let t0 = Date()
        func mark(_ label: String) {
            FileHandle.standardError.write(Data(String(format: "  [+%5.1fs] %@\n", Date().timeIntervalSince(t0), label).utf8))
        }

        let dttItem = CfgItem(name: "ddrtesttool", pathHint: nil, nameOffset: 0,
                              payloadOffset: 0, payloadLength: ddrTestTool.count)
        if !ddrBin.isEmpty {
            // ① train-only bin — trains the PHY (RK3568's three-step cfg only; the
            //    two-step SoCs ship no `trainonly` record, so `ddrBin` is empty and
            //    this whole branch is skipped). Download ONCE, lenient: the bin
            //    LAUNCHES and runs long, so the device takes over before the
            //    final-chunk ACK — that is success, not failure. Do NOT
            //    strict-then-lenient re-download: the retry would hit the now-busy
            //    (running) device and error out ("4096 got -99"). step② below polls
            //    until it returns to maskrom.
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
            // ② only. No train-only step (e.g. RK3576/RK3588: the eyescan-item
            //    self-trains). Boot the DTT on the already-open handle, strict FIRST
            //    (a full final-chunk ACK = the resident 2-core service fully loaded);
            //    only if that fails retry lenient. Do NOT close+re-open here — the
            //    fresh maskrom handle is already good, and re-opening re-issues
            //    SET_CONFIGURATION which can leave the DTT half-initialised.
            do {
                try transport.downloadBoot(item: dttItem, payload: ddrTestTool, lenientFinalChunk: false)
            } catch {
                try transport.downloadBoot(item: dttItem, payload: ddrTestTool, lenientFinalChunk: true)
            }
        }
        mark("② DDR Test Tool booted (\(ddrTestTool.count)B)")
        try? await Task.sleep(nanoseconds: 400_000_000)   // let core 0's service loop come up

        // ③ eye-scan item — download + run. NO host geometry.
        // `rawEnd` belongs to the RK3568 three-step model ONLY: there the train-only bin (step ①)
        // detects geometry and leaves a1@0xFDCCFF40 / DRAM-info@0xFDCCFFB0 in the BSS above it, so
        // we download only [itemBase, rawEnd) and those survivors stay alive across the reload.
        //
        // ⚠ It is a per-SoC constant applied globally, and the two-step SoCs land on either side of
        // it by numeric accident rather than by design: one has an item base above it and takes the
        // `else` branch, the other falls below and gets a cap astronomically larger than the item.
        // Both end up downloading the WHOLE item, which is what they want — the eyescan self-trains
        // and keeps no mid-image survivors, so there is nothing to preserve — but making `rawEnd`
        // per-SoC is the real fix. The comparison also guards the subtraction from underflowing
        // UInt32 (→ SIGTRAP).
        let maxCode = itemBase < Self.rawEnd ? Int(Self.rawEnd - itemBase) : itemBin.count
        let dl = itemBin.prefix(min(itemBin.count, maxCode))
        let item = CfgItem(name: "eyescanitem", pathHint: nil, nameOffset: 0,
                           payloadOffset: 0, payloadLength: dl.count)
        try transport.downloadItem(item: item, payload: dl, address: itemBase)
        try transport.runItem(item: item, address: itemBase)
        mark("③ eye-scan item downloaded (\(dl.count)B) + running @0x\(String(itemBase, radix: 16))")

        // ③ drain — STATE-BASED completion, but WITHOUT polling testDeviceReady on the hot path.
        // The item (core 1) pushes its report into the DTT ring, then RETURNS so the item-runner
        // sets status=done. Completion is a device STATE (testDeviceReady word1 == finished) — NOT a
        // content marker (the report tail comes after "…done"). The deadline is a hard safety
        // timeout, not a completion signal.
        //
        // Speed lesson (measured, vs the factory soldering test which drains fine): calling
        // testDeviceReady() every iteration is FATAL here. Both opcodes are served by the same
        // device-side service loop, which contends with the item while it is producing — so during
        // a scan an opcode-0 (5 s timeout) can stall ~1 s, and one per iteration throttled the whole
        // drain to ~500 B/s. A soldering memtest produces no printf, which is why that path does not
        // show the problem. Fix: drain 0x80 in a tight loop while data flows (readPrintf only), and
        // probe testDeviceReady ONLY when the device goes idle — by then it answers instantly.
        // `acknowledge:false`: the DTT ring advances on the 0x80 read itself, so the extra ack
        // round-trip is unnecessary.
        var transcript = ""
        // Drain-speed instrumentation: separate time spent in reads that RETURNED DATA from reads
        // that came back EMPTY (a 100 ms bulk-IN timeout). effective-when-data = the real USB-printf
        // throughput limit; empty-read time = pure waste (ring was empty when we polled).
        var dataBytes = 0, nData = 0, nEmpty = 0, maxChunk = 0
        var tData = 0.0, tEmpty = 0.0
        // Diagnostic: the status poll below is guarded by `try?`, so a stalled run
        // cannot say whether the device answered "still running" or stopped
        // answering at all. Count both, and time the poll itself.
        var nStatusOK = 0, nStatusFail = 0, tStatus = 0.0
        var lastStatusError = ""
        var lastDataAt = Date()
        // Stall probe: once the ring has been idle for a while with the item still running, poll
        // tightly with no status poll in between. Bytes resuming means the item was merely held by
        // output backpressure and our own opcode-0 polling was starving it; nothing coming back
        // means the item has stopped, which takes the device's whole USB service down with it.
        // Runs once so it cannot mask the stall it is measuring.
        var idleRun = 0, burstDone = false
        // DECOUPLE the UI from the USB drain — STRUCTURALLY, not best-effort. The USB link must be
        // PHYSICALLY INCAPABLE of being stalled, starved, or grown without bound by UI work: a slow
        // (or hung) display can never drag down readPrintf / the device link. Two guarantees:
        //   1. The drain NEVER awaits onProgress — chunks are handed off via `yield` (which never
        //      suspends the producer) and a SEPARATE task feeds onProgress at the UI's own pace.
        //   2. The hand-off buffer is BOUNDED + drop-oldest (`.bufferingNewest`). If the UI can't
        //      keep up, the DISPLAY drops its oldest queued chunks — purely cosmetic, since
        //      `transcript` below keeps EVERY byte for the verdict — while memory stays capped and
        //      the end-of-run `await uiTask.value` can only ever wait on a bounded backlog.
        // (The prior `.unbounded` policy let a pathologically slow UI grow memory and delay run()'s
        // return; the drain loop itself was already non-blocking, but this makes the whole path
        // provably immune to UI speed.)
        var uiEmit: AsyncStream<String>.Continuation!
        let uiStream = AsyncStream<String>(bufferingPolicy: .bufferingNewest(2048)) { uiEmit = $0 }
        let uiTask = Task { for await chunk in uiStream { await onProgress?(chunk) } }
        var uiDropped = 0
        var completedViaStatus = false
        let deadline = Date().addingTimeInterval(timeout)
        drain: while Date() < deadline {
            let t0 = Date()
            let s = try? transport.readPrintf(acknowledge: false)
            let dt = Date().timeIntervalSince(t0)
            if let s, !s.isEmpty {
                let n = s.utf8.count
                transcript += s
                dataBytes += n; nData += 1; tData += dt; maxChunk = max(maxChunk, n)
                if case .dropped = uiEmit.yield(s) { uiDropped += 1 }   // non-blocking; drop-oldest if UI lags
                lastDataAt = Date()
                idleRun = 0
                continue                 // keep draining fast — do NOT probe status while data flows
            }
            nEmpty += 1; tEmpty += dt
            // Ring idle → ask the device: has the item returned (status == done)?
            // Tolerant: a transient poll failure must not abort a run whose report is already
            // captured — the item returns then the DTT stays briefly busy, so retry, don't throw.
            let tS = Date()
            let statusOrNil: DeviceReadyStatus?
            do { statusOrNil = try transport.testDeviceReady(); nStatusOK += 1 }
            catch { statusOrNil = nil; nStatusFail += 1; lastStatusError = "\(error)"; idleRun += 1 }
            tStatus += Date().timeIntervalSince(tS)
            if idleRun >= 8, !burstDone {
                    burstDone = true
                    let bT = Date(); var got = 0, reads = 0
                    while Date().timeIntervalSince(bT) < 2.0 {
                        reads += 1
                        if let b = try? transport.readPrintf(acknowledge: false), !b.isEmpty {
                            got += b.utf8.count
                            transcript += b
                            if case .dropped = uiEmit.yield(b) { uiDropped += 1 }
                        }
                    }
                    mark("③ stall probe: \(reads) tight polls in 2s while item is RUNNING -> \(got)B"
                         + (got > 0 ? " (backpressure: bytes resume without the status poll)"
                                    : " (no bytes: core 1 is not merely blocked on the ring)"))
                    if got > 0 { lastDataAt = Date(); idleRun = 0 }
            }
            guard let status = statusOrNil else { continue }
            if status.phase == .running { idleRun += 1 }
            if status.phase == .finished || status.phase == .error {
                while let s = try? transport.readPrintf(acknowledge: false), !s.isEmpty {
                    transcript += s; dataBytes += s.utf8.count; nData += 1
                    if case .dropped = uiEmit.yield(s) { uiDropped += 1 }
                }
                completedViaStatus = true
                mark("③ done via status (\(transcript.utf8.count)B)")
                break drain
            }
        }
        if Date() >= deadline {
            mark("③ drain hit \(Int(timeout))s deadline (device never reported done)")
            mark(String(format: "③ stall detail: last data %.1fs ago | status polls ok=%d fail=%d in %.1fs (%.0fms each)%@ | last transcript line: %@",
                        Date().timeIntervalSince(lastDataAt), nStatusOK, nStatusFail, tStatus,
                        (nStatusOK + nStatusFail) > 0 ? tStatus / Double(nStatusOK + nStatusFail) * 1000 : 0,
                        lastStatusError.isEmpty ? "" : " | last status error: \(lastStatusError)",
                        transcript.split(separator: "\n").last.map(String.init) ?? "-"))
        }
        let rate = tData > 0 ? Double(dataBytes)/tData : 0
        mark(String(format: "③ drain stats: %dB | data-reads %d in %.2fs = %.0f B/s (USB limit-when-data, avgchunk %dB, max %dB) | empty-reads %d in %.2fs (100ms-timeout waste) | UI-dropped %d chunk(s)",
                    dataBytes, nData, tData, rate, nData>0 ? dataBytes/nData : 0, maxChunk, nEmpty, tEmpty, uiDropped))
        uiEmit.finish()   // USB drain done → no more chunks; the UI task drains its own buffer

        // ③b otpdump — the per-chip identity, read after the scan and before the reboot. Never
        // fatal: a failure leaves the identity unknown and the run is otherwise unaffected. An item
        // is finished when the DEVICE says so, not when its output stops, so this polls for
        // completion before returning — issuing the next download while the loader is still running
        // the previous item stops it servicing commands at all.
        var cpuid: [UInt8]? = nil
        if let otpBin, let otpCpuidByteOffset {
            do {
                let od = CfgItem(name: "otpdump", pathHint: nil, nameOffset: 0,
                                 payloadOffset: 0, payloadLength: otpBin.count)
                try transport.downloadItem(item: od, payload: otpBin, address: itemBase)
                try transport.runItem(item: od, address: itemBase)
                let otpDeadline = Date().addingTimeInterval(6)
                var captured = ""
                var returned = false
                while Date() < otpDeadline {
                    if let s = try? transport.readPrintf(), !s.isEmpty { captured += "\n" + s }
                    if cpuid == nil {
                        cpuid = ChipIdentity.parseOtpProbeOutput(captured, cpuidByteOffset: otpCpuidByteOffset)
                    }
                    if let st = try? transport.testDeviceReady(), st.phase == .finished {
                        returned = true
                        break
                    }
                    try? await Task.sleep(nanoseconds: 40_000_000)
                }
                mark("③b otpdump (cpuid \(cpuid == nil ? "unavailable" : "ok"), item \(returned ? "returned" : "DID NOT return"))")
            } catch {
                mark("③b otpdump skipped (\(error))")
            }
        }

        // ④ Auto-return to maskrom: run the factory reboot payload (per-SoC boot-mode magic + CRU
        // soft-reset, taken from that SoC's DDR自动探测.cfg). The device resets → the next run starts
        // from a clean maskrom with NO manual replug. The runItem ack is lost (the device is
        // rebooting) → lenient.
        //
        // The reboot payload is itself an ITEM, so it needs the same device-side runner the
        // eye-scan item was using. That makes it useless when the drain above timed out: the device
        // never reported done precisely because that item never came back, so the reboot cannot run
        // either, and every transfer we attempt just burns a full USB timeout. Skip it and say
        // plainly that the board needs a physical replug — that is the only recovery.
        // A deadline alone does NOT mean the board is stuck. Measured on RK3576: a stress item
        // streaming steadily at ~1 KB/s simply outlasts the timeout, with data still arriving at
        // the moment it fires — the item is alive and the reboot works normally. Only a device that
        // has gone SILENT has actually stopped.
        let silentFor = Date().timeIntervalSince(lastDataAt)
        let wedged = !completedViaStatus && silentFor >= stallSilence
        if !completedViaStatus {
            mark(String(format: "③ deadline with last data %.1fs ago → %@",
                        silentFor,
                        wedged ? "device STOPPED (wedged)"
                               : "device still producing — the item is just slower than the timeout"))
        }

        var returnedToMaskrom: Bool? = nil
        if let rebootBin {
            // ALWAYS attempt it, even when the run stalled. An earlier version skipped the reboot
            // on a stalled run, reasoning that the payload is itself an item and a device stuck
            // inside the previous item could never pick it up. Measured: that is wrong often enough
            // to matter — a stalled RK3588 recovered on the very next run because the released
            // build sent the reboot regardless. "The drain timed out" only means we never saw the
            // completion signal; it does not mean the device stopped answering. Skipping costs a
            // human walking to the bench; attempting costs a few seconds of USB timeouts.
            //
            // `answering` records whether the device was responding at all while we drained, so a
            // stalled-but-alive run reads differently from one where USB itself had failed — and so
            // the pairing of that state with whether the reboot then worked accumulates as evidence
            // rather than staying a guess.
            let answering = nStatusFail == 0 || nStatusOK > 0
            let rb = CfgItem(name: "reboot", pathHint: nil, nameOffset: 0, payloadOffset: 0, payloadLength: rebootBin.count)
            var sent = "download+run ok"
            do {
                try transport.downloadItem(item: rb, payload: rebootBin, address: itemBase)
            } catch { sent = "download FAILED (\(error))" }
            if sent.hasPrefix("download+run") {
                // The device resets mid-command, so a lost ack here is expected, not a fault.
                do { try transport.runItem(item: rb, address: itemBase) }
                catch { sent = "run returned \(error) (expected if the reset fired)" }
            }
            mark("④ reboot item: \(sent)" + (wedged ? "  [after a stall; device was \(answering ? "still answering" : "NOT answering")]" : ""))
            returnedToMaskrom = await deviceReset(transport: transport, device: device)
            mark(returnedToMaskrom == true
                 ? "④ reset observed — board re-enumerated"
                 : "④ reset NOT observed (it may still have happened; the next boot download is the real test)")
        }
        await uiTask.value   // let the decoupled UI delivery finish (overlaps the reboot above)
        return Outcome(transcript: transcript,
                       completedViaStatus: completedViaStatus,
                       wedged: wedged,
                       cpuid: cpuid,
                       returnedToMaskrom: returnedToMaskrom)
    }

    /// Was the reset OBSERVED? Returns nil when it could not be, which is not a failure.
    ///
    /// Two signals, either of which is positive: the device leaving the bus, or coming back on the
    /// same socket under a new USB address. Neither is guaranteed to be visible — the gap can be
    /// shorter than any polling interval, and the host may reassign the same address — so a
    /// negative result means "not observed", never "did not happen". Both were measured giving
    /// false negatives on boards that had demonstrably rebooted, so this must not be reported as a
    /// fault: the next 0x471 boot download is the only definitive test.
    ///
    /// Note the device id deliberately does NOT change across re-enumeration (it names the socket,
    /// so a board can be addressed among several of the same model), which is why the address is
    /// tracked separately here.
    private func deviceReset(transport: UsbTransport, device: UsbDevice) async -> Bool? {
        try? transport.close()
        for _ in 0..<200 {                                  // ~6 s at 30 ms, to catch a short gap
            try? await Task.sleep(nanoseconds: 30_000_000)
            let list = (try? transport.discoverDevices()) ?? []
            guard let same = list.first(where: { $0.deviceID == device.deviceID }) else {
                return true                                 // off the bus ⇒ it reset
            }
            if same.usbAddress != device.usbAddress { return true }
        }
        return nil                                          // never observed — inconclusive
    }

}
