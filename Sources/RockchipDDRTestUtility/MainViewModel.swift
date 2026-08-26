import DDRCore
import DDRUSB
import Foundation

@MainActor
final class MainViewModel: ObservableObject {
    @Published var testFiles: [TestFileEntry] = []
    @Published var selectedFileID: String?
    @Published var devices: [UsbDevice] = []
    @Published var selectedDeviceID: String?
    @Published var isRunning = false
    @Published var statusMessage: String = ""
    @Published var testSteps: [TestStep] = []
    /// Monotonic count of messages appended across all steps. Bumped at every
    /// `messages.append` site, so it changes for both new steps (always created
    /// with a first message) and printf appended to an existing step. The UI
    /// observes this single O(1) value to auto-scroll — cheaper than recomputing
    /// a reduce on every body evaluation, and it doesn't thrash the main thread
    /// on the streaming printf path.
    @Published var totalMessageCount = 0

    /// The run's conclusion, three-state (see `DDRCore.RunConclusion`). A USB
    /// timeout is NOT a bad board: it used to be collapsed into `.failed` here,
    /// which showed the operator the same red 「测试失败」 as a real device
    /// verdict — and that scraps good boards.
    @Published var overallConclusion: RunConclusion?
    @Published var selectedSoc: String? {
        didSet { if selectedSoc != oldValue { refreshEyescanCfgURL() } }
    }
    @Published var autoTestEnabled = false
    /// User switch for DDR auto-detect (preselecting the cfg on plug-in). ON by
    /// default. Deliberately NOT persisted — its lifetime is this app run only,
    /// so every launch starts with auto-detect on. When OFF, a profiled device is
    /// treated like any other: no probe, no reboot, the user picks the cfg
    /// manually (their choice is never overwritten). Auto-detect only ever
    /// *preselects*; this switch lets the operator opt out entirely.
    @Published var autoDetectEnabled = true
    /// True while a DDR auto-detect probe (DdrDetector.detect) is in flight for
    /// a newly-arrived device. UI can use this to show a "detecting..." state
    /// distinct from `isRunning` (which covers the actual test execution).
    @Published var isDetecting = false
    /// 工具箱模式:焊接测试(广覆盖)或眼图 / 裕量扫描(窄覆盖,按 cfg 存在与否背书)。
    /// 分段控件选「测什么」,单个「开始」按钮按此模式分派。每个模式自带它的展示
    /// 文案(空状态标题 / 步骤、保存按钮标题 / 文件名),文案跟着模式走,视图里不必
    /// 散落 `mode == …` 三元分支——加新工具时只在这里补一行。
    enum ToolMode: String, CaseIterable, Identifiable {
        case solder = "焊接"
        case eyescan = "眼图"
        var id: String { rawValue }

        var emptyStateTitle: String {
            switch self {
            case .solder:  return "DDR 焊接质量测试"
            case .eyescan: return "DDR 眼图 / 裕量扫描"
            }
        }
        /// 空状态里的三步引导:(文案, SF Symbol)。
        var emptyStateSteps: [(text: String, symbol: String)] {
            switch self {
            case .solder:
                return [("连接设备（Maskrom 状态）", "1.circle"),
                        ("点「开始」：自动识别 DDR 并选好配置", "2.circle"),
                        ("查看焊接质量结果", "3.circle")]
            case .eyescan:
                return [("连接设备（Maskrom 状态）", "1.circle"),
                        ("点「开始」：固件自训练 DDR，逐 DQ 扫描裕量", "2.circle"),
                        ("查看 rx / tx 眼图裕量结果", "3.circle")]
            }
        }
        var saveButtonLabel: String { self == .eyescan ? "保存眼图日志" : "保存测试结果" }
        var saveFileName: String { self == .eyescan ? "DDR_Eyescan.txt" : "DDR_Test_Result.txt" }
    }
    @Published var mode: ToolMode = .solder

    /// 每开一轮新测试(焊接 / detect / 眼图)自增。用作日志区 ScrollView 的 `.id`,
    /// 强制新一轮重建一个全新的 ScrollView——否则会复用上一轮已滚到底部的滚动
    /// 位置,清空重填后偏移停在旧底部、显示空白(内容其实在,往上滚才见)。
    @Published private(set) var runToken = 0

    /// 复位一轮新测试的公共状态:清时间线、重置计数、翻 `runToken`(强制新建
    /// ScrollView)、清总判定。焊接 / detect / 眼图三个入口共用。
    private func beginNewRun() {
        testSteps = []
        totalMessageCount = 0
        runToken += 1
        overallConclusion = nil
    }

    /// 眼图对当前 SoC 是否可用,**完全由「是否随附眼图 cfg」决定**——眼图无需任何
    /// host 侧参数 / 地址,cfg 的存在本身就是该 SoC 的背书。缓存,在 `selectedSoc`
    /// 变化时刷新(refreshEyescanCfgURL),使 canEyescan / eyescanHelp / startEyescan
    /// 在 SwiftUI 渲染热路径上零磁盘 I/O。新增一款眼图 SoC = 打好 "…眼图.cfg" 放进
    /// DDRTestFiles/<soc>/ 即可,零代码改动。
    @Published private(set) var eyescanCfgURL: URL?

    /// 眼图当前是否可用(当前 SoC 有随附眼图 cfg)。
    var canEyescan: Bool { eyescanCfgURL != nil }

    /// 「开始」按钮是否可点(按当前模式)。
    var canStart: Bool {
        guard !isRunning, !isDetecting, !devices.isEmpty else { return false }
        return mode == .solder || canEyescan
    }

    /// 眼图模式下「开始」按钮的 hover 说明(不可用时解释原因)。
    var eyescanHelp: String {
        guard selectedSoc != nil else { return "请先连接设备" }
        if !canEyescan { return "当前芯片未随附眼图 cfg,暂不支持眼图测试" }
        return "对当前 DDR 做眼图 / 裕量扫描(需设备处于 Maskrom)"
    }

    /// Name of the DDR auto-detect card shown in the central log area (so detect
    /// and the subsequent test read as one timeline).
    static let detectStepName = "DDR 自动探测"
    /// Set when a detect card has been placed in `testSteps`; tells the next
    /// `startTest` to APPEND its steps after it (one timeline) instead of clearing.
    /// Consumed by that `startTest`; a fresh detect re-arms it, an unplug clears it.
    private var carryDetectStepIntoTest = false
    /// Set the moment `performDetectThenTest` is launched for the current
    /// device, so a subsequent `pollDevices` tick (the 1s timer) can't launch a
    /// second, overlapping detect for the same connection — detect's own
    /// reboot-to-maskrom step drops the device off USB and re-enumerates for up
    /// to ~6s, during which two racing detects (or a reboot-induced re-enum
    /// re-triggering detect) would otherwise loop. Cleared in
    /// `resetConnectionState()` so a genuine unplug re-arms it.
    private var hasDetectedForCurrentDevice = false
    /// True until a boot download succeeds on the current device connection.
    /// Mirrors DDR_UserTool's `this+0x4B8` flag: set whenever the device set
    /// changes (device (re)connected), cleared after the first successful boot,
    /// so repeated "start test" runs skip boot and just re-run the bulk test —
    /// exactly how Windows lets you keep clicking start.
    private var deviceNeedsBoot = true
    /// 眼图流式展示的跨 chunk 行缓冲:readPrintf 的字节不按行对齐,末尾未完成的
    /// 一行暂存于此,待下一段补齐后再落成一条消息(见 appendEyescanLines)。
    private var eyescanLineCarry = ""
    /// Persistent USB transport held open across "start test" clicks for the
    /// selected device — mirrors Windows' persistent device handle. The engine
    /// is told `keepTransportOpen`, so repeat tests reuse the same claimed
    /// interface instead of re-opening (which re-issues SET_CONFIGURATION and
    /// stalls the booted device's bulk endpoint). Torn down on device-set change
    /// or device-selection change.
    /// Held as the PROTOCOL, not `RkUsbTransportLibusb`: the session logic only
    /// needs the transport's contract, and binding it to libusb is what kept this
    /// class impossible to drive from a test.
    private var activeTransport: UsbTransport?
    private var activeTransportDeviceID: String?
    /// Idle keep-alive for the held transport. Mirrors DDR_UserTool's permanent
    /// printf-reader thread (PrintfReaderThreadProc / sub_405C30): while a device
    /// is connected and no test is running, poll `readPrintf()` (opcode 0x80 on
    /// ep 0x81) every ~300ms. The perpetual in-flight transfer keeps the USB
    /// pipe "active" so macOS never selectively suspends the device — which is
    /// what otherwise kills the held handle after a few seconds idle and breaks
    /// repeat "start test". Cancelled at the start of every test (the engine
    /// owns the transport while `isRunning`) and on teardown. The transport's
    /// `ioLock` serializes any residual overlap with the engine.
    private var keepAliveTask: Task<Void, Never>?

    private let parser = CfgBinaryParser()
    private let logWriter = ResultLogWriter()
    private(set) var lastResult: ExecutionResult?
    /// 最近一次眼图扫描的完整 transcript(供「保存结果」写出;眼图不产生
    /// `ExecutionResult`,所以单独存)。
    @Published private(set) var lastEyescanTranscript: String?
    /// The eye-scan log as ONE growing string, rendered by `LogView` (a native NSTextView) which
    /// appends only the DELTA per update (O(delta)); a NON-append change (a new run clears it to "")
    /// makes LogView replace the whole document — that's what clears the previous scan's log. The
    /// COMPLETE report also lives in `EyescanRunner`'s returned transcript → `lastEyescanTranscript`
    /// (verdict + save). Separate from the step-message model.
    @Published private(set) var eyescanLog = ""
    /// Append text to the growing log (LogView lays out only the appended tail).
    private func appendEyescanText(_ s: String) {
        guard !s.isEmpty else { return }
        eyescanLog += s
    }
    /// Reset display state at the start of an eyescan run. Clearing `eyescanLog` to "" makes LogView
    /// (the shown text is no longer a prefix of "") replace the whole document → the pane starts empty.
    private func resetEyescanState() {
        beginNewRun()
        lastEyescanTranscript = nil
        eyescanLineCarry = ""
        eyescanLog = ""
    }
    private var deviceMonitorTimer: Timer?

    var socNames: [String] {
        let set = Set(testFiles.map(\.socName))
        return set.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    var filesForSelectedSoc: [TestFileEntry] {
        guard let soc = selectedSoc else { return [] }
        return testFiles.filter { $0.socName == soc }
    }

    func load() async {
        do {
            let repo = CfgRepository(rootURL: defaultRootURL())

            testFiles = try repo.discoverTestFiles()

            try await refreshDevices()

            // No fallback to socNames.first: that listed an unrelated chip's cfgs
            // (RK29, alphabetically first) while the header read "not connected".
            // An empty list now means one thing: no chip identified yet.

        } catch {
            statusMessage = error.localizedDescription
        }

        startDeviceMonitor()
    }

    func refreshDevices() async throws {
        let transport = try makeTransport()
        devices = try transport.discoverDevices()

        // If previously selected device is gone, reset to first available
        if let currentID = selectedDeviceID,
           !devices.contains(where: { $0.deviceID == currentID }) {
            selectedDeviceID = devices.first?.deviceID
        }
        if selectedDeviceID == nil {
            selectedDeviceID = devices.first?.deviceID
        }

        // Take the chip from the device's socName; nil when pidToSoc has no entry
        // for that PID, else the previous chip's cfg stays selected and runnable.
        // Only while a device is present — unplugging keeps the list on screen.
        if let current = devices.first(where: { $0.deviceID == selectedDeviceID }) {
            let soc = current.socName.flatMap { $0.isEmpty ? nil : $0 }
            if selectedSoc != soc {
                selectedSoc = soc
                selectedFileID = nil
            }
        }
    }

    /// 对当前选中的 cfg 在持久 transport 上执行焊接测试。假定已选中 cfg
    /// （由调用方保证）。这是原 startTest 的测试主体，原样保留（含持久
    /// transport / skipBoot / keep-alive 语义）。
    private func runSolderTest() async {
        guard let selected = testFiles.first(where: { $0.id == selectedFileID }) else {
            statusMessage = "请先选择配置文件"
            return
        }

        isRunning = true
        // Keep the detect card + start a continuous timeline when this test
        // follows an auto-detect; otherwise start fresh. (Consume the flag so a
        // second, standalone test run resets normally.)
        if carryDetectStepIntoTest {
            carryDetectStepIntoTest = false   // 续用 detect 的时间线,不新建 ScrollView
            overallConclusion = nil
        } else {
            beginNewRun()
        }
        // The engine owns the transport while a test runs — stop the idle
        // keep-alive so the two never contend (the engine's own 200ms
        // testDeviceReady polling keeps the pipe active mid-test). Restarted
        // below once the test finishes.
        stopKeepAlive()

        do {
            // Bind the persistent transport to the selected device: if the
            // selection changed, drop the old handle first. Held open via
            // keepTransportOpen so repeat tests reuse the same claimed interface
            // — exactly how Windows holds its device handle across "start test"
            // clicks (re-opening re-issues SET_CONFIGURATION and stalls the
            // booted device's bulk endpoint; verified on RK3568 hardware).
            if activeTransport == nil || activeTransportDeviceID != selectedDeviceID {
                tearDownActiveTransport()
                activeTransport = try makeTransport()
                activeTransportDeviceID = selectedDeviceID
            }
            let skipBoot = !deviceNeedsBoot
            let engine = TestExecutionEngine(parser: parser, transport: activeTransport!) { [weak self] entry in
                // Preserve engine log order in the UI. A detached Task per entry
                // can reorder Boot / forceinit / connect updates under load.
                guard let self else { return }
                await self.handleExecutionLog(entry)
            }

            let result = await engine.run(
                cfgPath: selected.absolutePath,
                selectedDeviceID: selectedDeviceID,
                skipBoot: skipBoot,
                keepTransportOpen: true
            )
            lastResult = result
            // Clear the latch only after a real boot succeeds — a failed boot
            // leaves it set so the next run retries (matches Windows, which
            // clears 0x4B8 solely after a good boot).
            if result.bootSucceeded {
                setDeviceNeedsBoot(false)
            }

            // The verdict is the engine's — it comes from the device's status /
            // result words. The old code additionally forced FAIL whenever any
            // step had logged an error, which turned a non-fatal host-side error
            // on a passing run into a scrapped board.
            let conclusion = RunConclusion.solder(result)
            overallConclusion = conclusion
            statusMessage = Self.statusLine(conclusion)
        } catch {
            // Never reached the device's verdict → no conclusion about the DDR.
            overallConclusion = .inconclusive(.transport)
            statusMessage = "未测出结论:\(error.localizedDescription)"
        }

        isRunning = false
        // Transport is still held (keepTransportOpen); resume the idle
        // keep-alive so the device doesn't get suspended before the next click.
        startKeepAlive()
    }

    /// One status line per conclusion. 「测试失败」 is reserved for a real device
    /// verdict; everything else says plainly that the board was NOT judged.
    static func statusLine(_ c: RunConclusion) -> String {
        switch c {
        case .passed: return "测试通过"
        case .deviceFailed: return "测试失败:设备判定 DDR 不合格"
        case .inconclusive(let reason):
            switch reason {
            case .transport: return "未测出结论:USB 传输失败 —— 请检查连接后重试,板子未被判定"
            case .cfg: return "未测出结论:配置文件缺失或无法解析,板子未被判定"
            case .noDevice: return "未测出结论:未找到处于 Maskrom 的设备"
            case .deviceWedged: return "未测出结论:设备中途停止响应 —— 请重新插拔后重试"
            case .scanIncomplete: return "未测出结论:扫描未在时限内完成 —— 板子正常,是耗时超限"
            }
        }
    }

    static let eyescanStepName = "眼图测试"

    /// 眼图测试入口。3 步全在设备端:train-only 眼图 bin(自训练 DDR + 定几何)→
    /// DDR Test Tool(常驻 0x80 服务)→ 重定位测量核。全程无需选配置文件。
    /// 眼图要求设备处于 Maskrom(第①步是 downloadBoot),且自己做整套 boot 序列
    /// 并在结束时自复位回 Maskrom —— 所以不复用焊接测试的常驻 Boot 持久句柄。
    func startEyescan() async {
        // 先清上一轮显示——无论后续是否真正开跑,都不残留旧的通过/失败结论。
        // (这也是眼图的唯一清屏点:pollDevices 不再清,见其注释。)
        resetEyescanState()

        // selectedDeviceID 在重枚举后可能短暂失配 → 回退到当前第一台设备。
        guard let device = devices.first(where: { $0.deviceID == selectedDeviceID }) ?? devices.first,
              let payloads = eyescanPayloads() else {
            statusMessage = eyescanHelp
            return
        }
        isRunning = true
        // 眼图要 Maskrom + 自带 downloadBoot 序列 → 拆掉焊接测试的常驻持久句柄。
        tearDownActiveTransport()
        defer { isRunning = false }

        ensureStep(Self.eyescanStepName)          // step tracks STATE only (drives the pane header)
        setStepState(Self.eyescanStepName, .running)
        appendEyescanText("开始眼图 / 裕量扫描…\n")

        do {
            let transport = try makeTransport()
            // async 回调:EyescanRunner 会 `await` 它跑完再读下一段,所以逐段
            // 严格有序(不再用 fire-and-forget 的 Task,那会乱序)。
            let outcome = try await EyescanRunner().run(
                transport: transport, device: device,
                ddrBin: payloads.trainOnly, ddrTestTool: payloads.dtt, itemBin: payloads.item,
                itemBase: payloads.itemBase,
                timeout: 120,
                rebootBin: payloads.reboot,
                onProgress: { [weak self] chunk in
                    await self?.appendEyescanLines(chunk)
                })
            let transcript = outcome.transcript
            try? transport.close()
            flushEyescanLineCarry()   // 冲掉最后一行不带换行的残余

            lastEyescanTranscript = transcript
            // 判读全部来自 DDRCore:固件自己的 all result: 汇总 + 传输侧结论。
            let report = EyescanVerdict.parse(transcript)
            let conclusion = RunConclusion.eyescan(report: report, wedged: outcome.wedged,
                                                   completedViaStatus: outcome.completedViaStatus)
            overallConclusion = conclusion
            setStepState(Self.eyescanStepName, conclusion == .passed ? .passed : .failed)
            statusMessage = Self.statusLine(conclusion)
            if let line = report.displayLine {
                appendEyescanText("固件判定:\(line)\n")
            }
            appendEyescanText("结论:\(Self.statusLine(conclusion))\n")
            // 跑完了但板子没真正复位 → 下一轮的 0x471 下载会失败,先提示。
            if conclusion != .inconclusive(.deviceWedged), outcome.returnedToMaskrom == false {
                appendEyescanText("注意:设备未复位回 Maskrom,下次开始前请重新插拔\n")
            }
        } catch {
            setStepState(Self.eyescanStepName, .failed)
            overallConclusion = .inconclusive(.transport)
            appendEyescanText("眼图未测出结论:\(error.localizedDescription)\n")
            appendEyescanText("请确认设备处于 Maskrom(若刚跑过焊接测试,需重新插拔),再重试\n")
            statusMessage = Self.statusLine(.inconclusive(.transport))
        }

        // 眼图跑完设备自复位回 Maskrom → 交给设备监视器(pollDevices)处理重枚举
        // (重置连接门闩、刷新设备列表)。pollDevices 不再清日志,所以结果一直留到
        // 下次点「开始」——不必在这里做任何保留处理。
    }

    /// 把眼图 transcript 的每个 chunk 按行灌进「眼图测试」步骤卡片(复用焊接
    /// 那套 printf 流式展示 + 自动滚动)。readPrintf 返回的字节不按行对齐——
    /// 一行可能跨 chunk——所以用 `eyescanLineCarry` 缓冲未完成的最后一行,只在
    /// 遇到换行时才落一条完整消息,避免同一行被切成两条。
    private func appendEyescanLines(_ chunk: String) {
        var lines = (eyescanLineCarry + chunk).components(separatedBy: "\n")
        eyescanLineCarry = lines.removeLast()   // 末段可能不完整(无结尾换行)→ 留到下段
        let batch = lines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !batch.isEmpty else { return }
        appendEyescanText(batch.joined(separator: "\n") + "\n")   // O(delta) append to shared storage
    }

    /// 扫描结束后冲掉行缓冲里最后一行不带换行的残余(如末尾的完成标记)。
    /// 追加一个换行,让残余走 `appendEyescanLines` 的同一条落行路径。
    private func flushEyescanLineCarry() {
        appendEyescanLines("\n")
    }

    // MARK: - Eye-scan cfg

    /// 刷新眼图 cfg 缓存(在 `selectedSoc` 变化时调用,不在渲染路径上跑)。定位共用 DDRCore 的
    /// `CfgRepository.eyescanCfgURL(forSoc:)`(和 CLI `--eyescan` 同一套)。
    private func refreshEyescanCfgURL() {
        eyescanCfgURL = selectedSoc.flatMap {
            CfgRepository(rootURL: CfgRepository.makeDefaultRootURL()).eyescanCfgURL(forSoc: $0)
        }
    }

    /// 解析缓存的眼图 cfg,取出眼图 payload(Boot/eyescan/trainonly?/reboot + base)。共用
    /// `CfgTestPlan.eyescanPayloads()`(和 CLI `--eyescan` 同一套),不再各写一份。
    private func eyescanPayloads() -> EyescanPayloads? {
        guard let url = eyescanCfgURL, let plan = try? parser.parse(url: url) else { return nil }
        return plan.eyescanPayloads()
    }

    /// 「开始测试」按钮入口。本次连接尚未探测且设备适用自动探测 → 探测+测
    /// 一气呵成；否则测当前选中的 cfg（没选中则提示选择）。
    func startTest() async {
        guard let device = devices.first(where: { $0.deviceID == selectedDeviceID }) else {
            statusMessage = "未连接设备"
            return
        }
        if autoDetectEnabled,
           DetectProfiles.forPID(device.productID) != nil,
           !hasDetectedForCurrentDevice {
            await performDetectThenTest(device)
            return
        }
        guard selectedFileID != nil else {
            statusMessage = "请先选择配置文件"
            return
        }
        await runSolderTest()
    }

    /// 「保存结果」是否可点(按当前模式:眼图存 transcript,焊接存 ExecutionResult)。
    var canSaveResult: Bool {
        guard !isRunning else { return false }
        return mode == .eyescan ? lastEyescanTranscript != nil : lastResult != nil
    }

    func saveResult(to outputURL: URL) {
        // 眼图:直接写完整 transcript(无 ExecutionResult)。
        if mode == .eyescan {
            guard let transcript = lastEyescanTranscript else {
                statusMessage = "无眼图结果可保存"
                return
            }
            do {
                try transcript.write(to: outputURL, atomically: true, encoding: .utf8)
                statusMessage = "已保存眼图日志:\(outputURL.lastPathComponent)"
            } catch {
                statusMessage = error.localizedDescription
            }
            return
        }

        guard let lastResult,
              let selected = testFiles.first(where: { $0.id == selectedFileID }) else {
            statusMessage = "No result to save"
            return
        }

        do {
            _ = try logWriter.write(result: lastResult, sourceCfgPath: selected.absolutePath, outputURL: outputURL)
            statusMessage = "Saved result: \(outputURL.lastPathComponent)"
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    /// Applies DDR auto-detect results to selection state: preselects the
    /// highest-ranked candidate that actually exists among the loaded
    /// `testFiles` (a candidate can be ranked from a stale/partial file list),
    /// setting both `selectedFileID` and `selectedSoc`. Returns the chosen file
    /// id, or nil if none of the candidates are present (caller keeps the
    /// current selection / falls back to manual).
    ///
    /// The actual "does this candidate exist" decision is delegated to
    /// `CfgAutoSelect.firstAvailable` (DDRCore, pure, unit-tested) — this
    /// wrapper only exists to apply the result to `@Published` state, since
    /// this app target itself isn't unit-testable (executable, not a library).
    func applyDetectCandidates(_ candidates: [CfgAutoSelect.Candidate]) -> String? {
        guard let entry = CfgAutoSelect.firstAvailable(candidates, in: testFiles) else { return nil }
        selectedFileID = entry.id
        selectedSoc = entry.socName
        return entry.id
    }

    func onDeviceSelectionChanged() {
        guard let deviceID = selectedDeviceID,
              let device = devices.first(where: { $0.deviceID == deviceID }),
              let soc = device.socName else { return }
        if selectedSoc != soc {
            selectedSoc = soc
            selectedFileID = nil
        }
    }

    // MARK: - Step Tracking

    private func updateStepsFromLog(_ entry: ExecutionLogEntry) {
        let code = entry.code
        let message = entry.message

        switch code {
        case "INFO_DOWNLOADBOOT_START":
            ensureStep("Boot")
            setStepState("Boot", .downloading)
            appendStepMessage("Boot", message)

        case "INFO_DOWNLOADBOOT_OK":
            setStepState("Boot", .passed)
            appendStepMessage("Boot", message)

        case "ERROR_DOWNLOADBOOT_FAIL":
            setStepState("Boot", .failed)
            appendStepMessage("Boot", message)

        case "INFO_DOWNLOADITEM_START":
            if let name = entry.itemName ?? extractItemName(from: message) {
                ensureStep(name)
                setStepState(name, .downloading)
                appendStepMessage(name, message)
            }

        case "INFO_DOWNLOADITEM_OK":
            if let name = entry.itemName ?? extractItemName(from: message) {
                appendStepMessage(name, message)
            }

        case "INFO_DOWNLOADITEMPARAM_START":
            if let name = entry.itemName ?? extractItemName(from: message) {
                appendStepMessage(name, message)
            }

        case "INFO_RUNITEM_START":
            if let name = entry.itemName ?? extractItemName(from: message) {
                setStepState(name, .running)
                appendStepMessage(name, message)
            }

        case "INFO_RUNITEM_OK":
            if let name = entry.itemName ?? extractItemName(from: message) {
                setStepState(name, .passed)
                appendStepMessage(name, message)
            }

        case "ERROR_DOWNLOADITEM_FAIL", "ERROR_DOWNLOADITEMPARAM_FAIL", "ERROR_RUNITEM_FAIL":
            markCurrentRunningStepFailed(message)

        case "INFO_PRINTF":
            handlePrintf(message)

        case "INFO_TESTDDR_OK":
            markAllPendingStepsPassed()

        default:
            break
        }
    }

    private func handleExecutionLog(_ entry: ExecutionLogEntry) {
        updateStepsFromLog(entry)
    }

    private func ensureStep(_ name: String) {
        if !testSteps.contains(where: { $0.name == name }) {
            testSteps.append(TestStep(name: name))
        }
    }

    private func setStepState(_ name: String, _ state: StepState) {
        if let idx = testSteps.firstIndex(where: { $0.name == name }) {
            testSteps[idx].state = state
        }
    }

    private func appendStepMessage(_ name: String, _ message: String) {
        if let idx = testSteps.firstIndex(where: { $0.name == name }) {
            testSteps[idx].messages.append(message)
            totalMessageCount += 1
        }
    }

    /// Fallback item-name recovery from log prose. Prefer the structured
    /// `entry.itemName` (set by the engine for item-scoped codes); this is kept
    /// only as a safety net for entries without it.
    private func extractItemName(from message: String) -> String? {
        // "Start to download test item forceinit..." → "forceinit"
        // "Start to run test item connect"          → "connect"
        // "Running test item forceinit ok"          → "forceinit"
        guard let range = message.range(of: "test item ") else { return nil }
        let rest = message[range.upperBound...]
        // Item name = the leading run of non-space, non-dot characters, so both
        // "forceinit ok" and "forceinit..." resolve to "forceinit".
        let name = rest.prefix { !$0.isWhitespace && $0 != "." }
        let trimmed = String(name).trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func handlePrintf(_ message: String) {
        // Printf is display-only. Step pass/fail is driven by the engine's
        // INFO_RUNITEM_OK / ERROR_RUNITEM_FAIL / INFO_TESTDDR_OK codes (which
        // come from the device's RKU_TestDeviceReady status/result), not from
        // scanning this text — matching DDR_UserTool's failure detection.
        let idx = testSteps.lastIndex(where: { $0.state == .running })
            ?? testSteps.lastIndex(where: { $0.state == .downloading })
            ?? testSteps.indices.last
        guard let idx else { return }

        // Strip protocol tags and display all lines
        let cleaned = message
            .replacingOccurrences(of: "<>", with: "")
            .replacingOccurrences(of: "</N>", with: "")
        for line in cleaned.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            testSteps[idx].messages.append(trimmed)
            totalMessageCount += 1
        }
    }


    private func markCurrentRunningStepFailed(_ message: String) {
        if let idx = testSteps.lastIndex(where: { $0.state == .downloading || $0.state == .running }) {
            testSteps[idx].state = .failed
            testSteps[idx].messages.append(message)
            totalMessageCount += 1
        }
    }

    private func markAllPendingStepsPassed() {
        for i in testSteps.indices {
            if testSteps[i].state == .running || testSteps[i].state == .downloading {
                testSteps[i].state = .passed
            }
        }
    }

    // MARK: - Private

    private func defaultRootURL() -> URL {
        CfgRepository.makeDefaultRootURL()
    }

    private func makeTransport() throws -> UsbTransport {
        return try RkUsbTransportLibusb()
    }

    /// Release the persistent test transport. Called on device-set change
    /// (unplug/replug) and device-selection change so the next test re-opens a
    /// fresh handle bound to the current device — never reusing a stale handle
    /// for a device that's gone.
    private func tearDownActiveTransport() {
        stopKeepAlive()
        try? activeTransport?.close()
        activeTransport = nil
        activeTransportDeviceID = nil
    }

    // MARK: - Idle Keep-Alive

    /// Start the idle keep-alive reader on the currently held transport. No-op
    /// if no transport is held or it isn't open. Idempotent — restarts cleanly.
    private func startKeepAlive() {
        stopKeepAlive()
        guard let transport = activeTransport, transport.isOpen else { return }
        keepAliveTask = Task.detached { [weak self] in
            var consecutiveFails = 0
            while !Task.isCancelled {
                guard self != nil else { return }
                let alive = transport.probeAlive()
                if alive {
                    consecutiveFails = 0
                } else {
                    consecutiveFails += 1
                    // ~1s of sustained no-response => device gone/unplugged.
                    // Tear down so the device monitor resumes enumeration and
                    // catches the replug; re-arms the boot-needed latch.
                    if consecutiveFails >= 3 {
                        await self?.handleDeviceLost()
                        return
                    }
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }

    private func stopKeepAlive() {
        keepAliveTask?.cancel()
        keepAliveTask = nil
    }

    /// Reset all connection-scoped latches after the current device goes away,
    /// so a replug is treated as a fresh connection: drop the held handle,
    /// require a boot, clear selection, and re-arm auto-test. Shared by both
    /// loss-detection paths (the keep-alive reader's `handleDeviceLost` and
    /// `pollDevices`' device-removal branch) so the two can't drift.
    private func resetConnectionState() {
        tearDownActiveTransport()
        setDeviceNeedsBoot(true)
        selectedDeviceID = nil
        hasDetectedForCurrentDevice = false
        carryDetectStepIntoTest = false
    }

    /// Called from the keep-alive reader when the device stops responding
    /// (unplugged or wedged). Resets connection state and refreshes the device
    /// list so the monitor detects the removal immediately and catches the replug.
    @MainActor
    private func handleDeviceLost() {
        resetConnectionState()
        Task { try? await refreshDevices() }
    }

    // MARK: - Device Monitoring

    private func startDeviceMonitor() {
        deviceMonitorTimer?.invalidate()
        deviceMonitorTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor [weak self] in
                self?.pollDevices()
            }
        }
    }

    private func pollDevices() {
        guard !isRunning else { return }
        guard !isDetecting else { return }
        guard activeTransport == nil else { return }
        do {
            let transport = try makeTransport()
            let newDevices = try transport.discoverDevices()
            let changed = newDevices.map(\.deviceID).sorted() != devices.map(\.deviceID).sorted()

            if changed {
                let deviceRemoved = !devices.isEmpty && newDevices.isEmpty
                devices = newDevices

                if deviceRemoved {
                    // Current device gone → fresh-connection reset so a replug
                    // re-boots and re-runs auto-test.
                    resetConnectionState()
                } else {
                    setDeviceNeedsBoot(true)
                    // 不在这里清日志区:每个「开始」入口(runSolderTest /
                    // performDetectThenTest / startEyescan)在开跑前自己清。这样设备
                    // 重枚举——尤其眼图自复位回 Maskrom——不会把刚出的结果冲掉,
                    // 结果一直留到下次点「开始」。(避免了之前一次性标记赌时序的脆弱。)

                    if let currentID = selectedDeviceID,
                       !devices.contains(where: { $0.deviceID == currentID }) {
                        selectedDeviceID = devices.first?.deviceID
                    }
                    if selectedDeviceID == nil {
                        selectedDeviceID = devices.first?.deviceID
                    }
                    if let device = devices.first(where: { $0.deviceID == selectedDeviceID }),
                       let soc = device.socName {
                        if selectedSoc != soc {
                            selectedSoc = soc
                            selectedFileID = nil            // 不默认选第一个
                        }
                    }

                    // 自动测试开：插入即用与「开始测试」按钮相同的编排(探测+测/测)。
                    // 关：插入什么都不做,等按钮。settle 让刚插上的 bootrom 就绪。
                    if autoTestEnabled {
                        Task {
                            try? await Task.sleep(nanoseconds: 1_000_000_000)
                            await startTest()
                        }
                    }
                }
            }
        } catch {
            // Silently ignore — device enumeration can fail transiently
        }
    }

    private func setDeviceNeedsBoot(_ newValue: Bool) {
        deviceNeedsBoot = newValue
    }

    /// 探测 + 测试 原子操作（按钮路径与自动测试插入路径共用）。探测唯一命中
    /// （粗匹配或 tie-break，一视同仁）→ 选好 cfg、等 Boot 空闲后接着测；
    /// 多规格/未识别 → 不选、提示手动选、停（不测）。探测失败 → 提示、停。
    @MainActor
    private func performDetectThenTest(_ device: UsbDevice) async {
        hasDetectedForCurrentDevice = true
        isDetecting = true
        statusMessage = "正在检测内存…"
        stopKeepAlive()
        defer { isDetecting = false }
        Self.dlog("detect start: device=\(device.deviceID) pid=0x\(String(format: "%04X", device.productID))")
        beginNewRun()
        ensureStep(Self.detectStepName)
        setStepState(Self.detectStepName, .running)
        appendStepMessage(Self.detectStepName, "开始探测…")
        carryDetectStepIntoTest = true
        do {
            if activeTransport == nil || activeTransportDeviceID != selectedDeviceID {
                tearDownActiveTransport()
                activeTransport = try makeTransport()
                activeTransportDeviceID = selectedDeviceID
            }
            let socName = DetectProfiles.forPID(device.productID)?.soc ?? device.socName ?? ""
            let det = DdrDetector(resourcesDir: detectResourcesDir(soc: socName))
            let out = try await det.detect(transport: activeTransport!, device: device,
                                           socFiles: filesForSelectedSoc, reboot: false)
            Self.dlog("detect done: \(out.geometry.summary()) matches=\(out.candidates.count) tier=\(out.matchTier)")
            setDeviceNeedsBoot(false)   // Boot 常驻，测试跳过 boot

            // 采纳与否由 DDRCore 的 DetectVerdict 决定(铁律:非唯一命中绝不自动跑);
            // tier 在此只用来决定给操作员看哪句话。
            switch DetectVerdict.decide(out.matchTier) {
            case .adopt:
                guard applyDetectCandidates(out.candidates) != nil else {
                    setStepState(Self.detectStepName, .failed)
                    appendStepMessage(Self.detectStepName, "已识别 \(out.geometry.summary())，但库中无对应配置 — 请手动选择")
                    statusMessage = "已识别内存但库中无对应配置，请手动选择配置文件"
                    startKeepAlive()
                    return
                }
                let cfgName = out.candidates.first?.entry.displayName ?? "(cfg)"
                setStepState(Self.detectStepName, .passed)
                appendStepMessage(Self.detectStepName, "检测到 \(out.geometry.summary())")
                appendStepMessage(Self.detectStepName, "已选配置: \(cfgName)")
                statusMessage = "已识别内存，开始测试…"
                // 等常驻 Boot 回到空闲命令循环再让测试下发 forceinit：osregdump
                // 探测刚结束时 Boot 可能仍忙，固定短延时会竞争 → 首个 downloadItem
                // 偶发 bulk IN timeout。probeAlive() 成功即表示 Boot 已能服务命令。
                let t = activeTransport
                await Task.detached {
                    for _ in 0..<30 {                       // 最多 ~3s
                        try? await Task.sleep(nanoseconds: 100_000_000)
                        if t?.probeAlive() == true { break }
                    }
                }.value
                isDetecting = false
                await runSolderTest()

            case .manual:
                switch out.matchTier {
                case .ambiguous:
                    setStepState(Self.detectStepName, .passed)
                    appendStepMessage(Self.detectStepName, "检测到 \(out.geometry.summary())")
                    appendStepMessage(Self.detectStepName, "有多种同规格配置，请选择后再点开始测试")
                    statusMessage = "检测到 \(out.geometry.summary())，有多种同规格配置，请选择后开始测试"
                default:
                    setStepState(Self.detectStepName, .failed)
                    appendStepMessage(Self.detectStepName, "未能识别内存(\(out.geometry.summary()))")
                    appendStepMessage(Self.detectStepName, "请手动选择配置文件后再点开始测试")
                    statusMessage = "未能自动识别内存，请手动选择配置文件后开始测试"
                }
                startKeepAlive()
            }
        } catch {
            setStepState(Self.detectStepName, .failed)
            appendStepMessage(Self.detectStepName, "探测失败:\(error)")
            appendStepMessage(Self.detectStepName, "请重新插拔设备，或手动选择配置文件")
            tearDownActiveTransport()
            setDeviceNeedsBoot(true)
            statusMessage = "自动检测失败，请重新插拔或手动选择配置文件"
            Self.dlog("detect FAILED: \(error)")
        }
    }

    /// Diagnostic log to stderr for the DDR auto-detect flow (mirrors
    /// CfgRepository's stderr logging). Visible when the GUI is launched from a
    /// terminal; keeps the detect path observable without a UI console.
    private static func dlog(_ message: String) {
        fputs("[DDRDetect] \(message)\n", stderr)
    }

    /// Directory holding the single self-contained DDR auto-detect cfg
    /// (`DetectProfile.detectCfgName`, e.g. `DDR自动探测.cfg`), which packages
    /// every payload the detect flow needs (rkbin DDR bin, Boot, osregdump,
    /// reboot). It lives in the SoC's `DDRTestFiles/<soc>/` dir alongside the
    /// real test cfgs, so it is discovered and bundled by the exact same path as
    /// every other cfg (`CfgRepository.makeDefaultRootURL()` → bundle or dev CWD,
    /// and `scripts/package.sh` already copies `DDRTestFiles/` into the `.app`).
    private func detectResourcesDir(soc: String) -> URL {
        CfgRepository.makeDefaultRootURL().appendingPathComponent(soc)
    }
}
