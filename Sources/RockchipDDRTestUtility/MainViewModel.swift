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

    @Published var overallOutcome: TestOutcome?
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
        overallOutcome = nil
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
    private var activeTransport: RkUsbTransportLibusb?
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

    private var settings: ConfigSettings = .default
    private let parser = CfgBinaryParser()
    private let logWriter = ResultLogWriter()
    private(set) var lastResult: ExecutionResult?
    /// 最近一次眼图扫描的完整 transcript(供「保存结果」写出;眼图不产生
    /// `ExecutionResult`,所以单独存)。
    @Published private(set) var lastEyescanTranscript: String?
    /// The eye-scan log as ONE growing string (not a 592-element message array). The eye-scan is a
    /// single large log; its own display pane renders this via a native NSTextView. Kept separate
    /// from the step-message model, which is for the multi-item solder test.
    @Published private(set) var eyescanLog = ""
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

            let loaded = try repo.loadSettings()
            settings = loaded.settings

            testFiles = try repo.discoverTestFiles()

            try await refreshDevices()

            // Fallback: if no device detected, pick first SoC. `selectedFileID`
            // is deliberately left nil here — `resolveDefaultTestFile` itself
            // falls back to "first cfg" when config.ini has no explicit default,
            // which is exactly the silent-wrong-cfg default this task removes.
            if selectedSoc == nil {
                selectedSoc = socNames.first
            }

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

        // Auto-select SoC from detected device
        if let device = devices.first(where: { $0.deviceID == selectedDeviceID }),
           let soc = device.socName, !soc.isEmpty {
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
            overallOutcome = nil
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

            // If any step ended in failure, the overall outcome is failure
            // regardless (its verdict came from the device's status/result).
            if testSteps.contains(where: { $0.state == .failed }) {
                overallOutcome = .failed
            } else {
                overallOutcome = result.outcome
            }
            statusMessage = overallOutcome == .passed ? "Test finished: PASS" : "Test finished: FAIL"
        } catch {
            overallOutcome = .failed
            statusMessage = error.localizedDescription
        }

        isRunning = false
        // Transport is still held (keepTransportOpen); resume the idle
        // keep-alive so the device doesn't get suspended before the next click.
        startKeepAlive()
    }

    static let eyescanStepName = "眼图测试"

    /// 眼图判定标准(与设备固件一致):
    /// - `all result:` 的**条数随 SoC 拓扑而变**:RK3576 双通道 / RK3588 四通道 → 每通道各一条;
    ///   RK3568 单通道 → 只一条(固件把 cs0/cs1 两个片选汇总进这一条)。末尾接 `all dq eye scan done`。
    /// **完全采用固件自己的汇总判定,HOST 不加额外判断逻辑**:
    ///   (a) **完成标记** `all dq eye scan done`:确认真跑完(否则 → 未完成,不下 pass/fail 结论)。
    ///   (b) **`all result:` 全 pass**:这是固件扫完所有 DQ 后打的**自身汇总判定行**(pass / `  fail`)。
    ///       多通道(RK3576 双 / RK3588 四)每通道各打一条 → 忠实读取**每一条**,全 pass 才 PASS。
    ///       这不是 host 额外逻辑,只是不遗漏任一通道的固件判定(旧代码只看最后一条会把某通道的
    ///       失败被后一通道的 pass 掩盖)。RK3568 单通道只一条(固件把 cs0/cs1 汇总进它)。
    /// - 无完成标记 → **未完成**(超时 / 设备异常 / 未处于 Maskrom / 训练中止),不下 pass/fail 结论。
    private func eyescanVerdict(_ transcript: String)
        -> (done: Bool, pass: Bool, resultLine: String?) {
        let done = transcript.contains("all dq eye scan done")
        let resultLines = transcript
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { $0.contains("all result:") }
            .map { $0.trimmingCharacters(in: .whitespaces) }
        // 完成标记 + 每条固件汇总 all result: 都 pass(≥1 条)才判 PASS。
        let pass = !resultLines.isEmpty && resultLines.allSatisfy { $0.contains("pass") }
        // 展示:优先给出错的那条(定位是哪个通道),全 pass 时自然落到末条。
        let resultLine = resultLines.first(where: { !$0.contains("pass") }) ?? resultLines.last
        return (done, pass, resultLine)
    }

    /// 眼图测试入口。3 步全在设备端:train-only 眼图 bin(自训练 DDR + 定几何)→
    /// DDR Test Tool(常驻 0x80 服务)→ 重定位测量核。全程无需选配置文件。
    /// 眼图要求设备处于 Maskrom(第①步是 downloadBoot),且自己做整套 boot 序列
    /// 并在结束时自复位回 Maskrom —— 所以不复用焊接测试的常驻 Boot 持久句柄。
    func startEyescan() async {
        // 先清上一轮显示——无论后续是否真正开跑,都不残留旧的通过/失败结论。
        // (这也是眼图的唯一清屏点:pollDevices 不再清,见其注释。)
        beginNewRun()
        lastEyescanTranscript = nil
        eyescanLineCarry = ""
        eyescanLog = ""

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
        eyescanLog += "开始眼图 / 裕量扫描…\n"

        do {
            let transport = try makeTransport()
            // async 回调:EyescanRunner 会 `await` 它跑完再读下一段,所以逐段
            // 严格有序(不再用 fire-and-forget 的 Task,那会乱序)。
            let transcript = try await EyescanRunner().run(
                transport: transport, device: device,
                ddrBin: payloads.trainOnly, ddrTestTool: payloads.dtt, itemBin: payloads.item,
                itemBase: payloads.itemBase,
                timeout: 120,
                rebootBin: payloads.reboot,
                onProgress: { [weak self] chunk in
                    await self?.appendEyescanLines(chunk)
                })
            try? transport.close()
            flushEyescanLineCarry()   // 冲掉最后一行不带换行的残余

            let v = eyescanVerdict(transcript)
            lastEyescanTranscript = transcript
            if v.done {
                setStepState(Self.eyescanStepName, v.pass ? .passed : .failed)
                overallOutcome = v.pass ? .passed : .failed
                eyescanLog += "判定:\(v.resultLine ?? "all result: (缺失)")\n"
                statusMessage = v.pass ? "眼图完成:PASS(所有 DQ 裕量达标)"
                                       : "眼图完成:FAIL(存在裕量不足的 DQ)"
            } else {
                // overallOutcome 已在开头置 nil,未完成不下 pass/fail 结论,保持 nil。
                setStepState(Self.eyescanStepName, .failed)
                eyescanLog += "扫描未出现完成标记(all dq eye scan done)—— 可能超时或设备异常\n"
                statusMessage = "眼图未完成,请检查设备"
            }
        } catch {
            setStepState(Self.eyescanStepName, .failed)
            eyescanLog += "眼图失败:\(error.localizedDescription)\n"
            eyescanLog += "请确认设备处于 Maskrom(若刚跑过焊接测试,需重新插拔),再重试\n"
            statusMessage = "眼图失败,请确认 Maskrom 后重试"
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
        eyescanLog += batch.joined(separator: "\n") + "\n"   // append to the one growing log string
    }

    /// 扫描结束后冲掉行缓冲里最后一行不带换行的残余(如末尾的完成标记)。
    /// 追加一个换行,让残余走 `appendEyescanLines` 的同一条落行路径。
    private func flushEyescanLineCarry() {
        appendEyescanLines("\n")
    }

    // MARK: - Eye-scan cfg

    /// 眼图三件套(解密后的明文 payload):train-only bin、DDR Test Tool、测量核。
    private struct EyescanPayloads { let trainOnly: Data; let dtt: Data; let item: Data; let itemBase: UInt32; let reboot: Data? }

    /// 刷新眼图 cfg 缓存(在 `selectedSoc` 变化时调用,不在渲染路径上跑)。
    private func refreshEyescanCfgURL() {
        eyescanCfgURL = selectedSoc.flatMap { locateEyescanCfg(soc: $0) }
    }

    /// 定位某 SoC 的眼图 cfg:`DDRTestFiles/<soc>/…眼图.cfg`。眼图 cfg 与焊接
    /// cfg、detect cfg 走完全相同的发现/打包路径(`package.sh` 已拷 DDRTestFiles),
    /// 无需单独的资源目录。缺失 → nil。
    private func locateEyescanCfg(soc: String) -> URL? {
        guard let files = try? FileManager.default.contentsOfDirectory(
                at: detectResourcesDir(soc: soc), includingPropertiesForKeys: nil) else { return nil }
        return files.first { $0.pathExtension.lowercased() == "cfg"
            && $0.lastPathComponent.contains(CfgRepository.eyescanCfgMarker) }
    }

    /// 解析缓存的眼图 cfg,按名字取出三件套(CfgBinaryParser 已把非 Boot 记录 RC4
    /// 解密回明文)。任一缺失 → nil。与 `DdrDetector` 从 detect cfg 取 payload 同法
    /// (共用 `CfgTestPlan.payload(named:)`)。
    private func eyescanPayloads() -> EyescanPayloads? {
        guard let url = eyescanCfgURL, let plan = try? parser.parse(url: url) else { return nil }
        guard let trainOnly = plan.payload(named: "trainonly"),
              let dtt = plan.payload(named: "Boot"),
              let item = plan.payload(named: "eyescan") else { return nil }
        // itemBase = the cfg's download-base (per-SoC): RK3568=0xFDCC4000, RK3576=0x3FF84000.
        // reboot: optional 4th record — auto-return to maskrom after the scan so the operator
        // can run again without a manual replug. nil for cfgs that don't package it (no-op then).
        return EyescanPayloads(trainOnly: trainOnly, dtt: dtt, item: item,
                               itemBase: plan.downloadBaseAddress,
                               reboot: plan.payload(named: "reboot"))
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
            _ = try logWriter.write(result: lastResult, sourceCfgPath: selected.absolutePath, outputURL: outputURL, outcome: overallOutcome)
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

    private func makeTransport() throws -> RkUsbTransportLibusb {
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

            switch out.matchTier {
            case .uniqueByCoarse, .uniqueByTieBreak:
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

            case .ambiguous:
                setStepState(Self.detectStepName, .passed)
                appendStepMessage(Self.detectStepName, "检测到 \(out.geometry.summary())")
                appendStepMessage(Self.detectStepName, "有多种同规格配置，请选择后再点开始测试")
                statusMessage = "检测到 \(out.geometry.summary())，有多种同规格配置，请选择后开始测试"
                startKeepAlive()

            case .none:
                setStepState(Self.detectStepName, .failed)
                appendStepMessage(Self.detectStepName, "未能识别内存(\(out.geometry.summary()))")
                appendStepMessage(Self.detectStepName, "请手动选择配置文件后再点开始测试")
                statusMessage = "未能自动识别内存，请手动选择配置文件后开始测试"
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
