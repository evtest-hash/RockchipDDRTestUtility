import DDRCore
import SwiftUI
import AppKit

struct ContentView: View {
    @StateObject private var viewModel = MainViewModel()

    var body: some View {
        mainContent
            .frame(minWidth: 900, minHeight: 560)
        .navigationTitle("Rockchip DDR Test Utility")
        .task {
            await viewModel.load()
        }
    }

    // MARK: - Main Content

    private var mainContent: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            logArea
            Divider()
            // The verdict gets a fixed row of its own, present even before a run.
            // It used to be a badge floating over the log — covering the last
            // lines of the very output it was summarising.
            verdictBar
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Circle()
                    .fill(viewModel.devices.isEmpty ? Color.red : Color.green)
                    .frame(width: 8, height: 8)
                // One board: just name it. Several: let the operator say WHICH —
                // every path already honours `selectedDeviceID` (the CLI exposes
                // the same choice as --device-id); only this control was missing.
                if viewModel.devices.count > 1 {
                    Picker("", selection: $viewModel.selectedDeviceID) {
                        ForEach(viewModel.devices) { device in
                            Text(viewModel.deviceLabel(device)).tag(Optional(device.deviceID))
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .disabled(viewModel.phase != .idle)
                    .onChange(of: viewModel.selectedDeviceID) { _ in
                        viewModel.onDeviceSelectionChanged()
                    }
                    .help("选择要测试的板子。切换会放弃当前板子的连接状态（下次开始重新 boot、重新探测）。")
                } else {
                    Text(viewModel.devices.isEmpty ? "未连接设备" : (viewModel.selectedSoc ?? "已连接设备"))
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
            }

            // 模式分段：选「测什么」，下面的「开始」按钮按此分派。眼图对不支持
            // 的 SoC 不隐藏（保发现性），改为禁用「开始」+ hover 说明原因。
            Picker("", selection: $viewModel.mode) {
                ForEach(MainViewModel.ToolMode.allCases) { m in
                    Text(m.rawValue).tag(m)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .disabled(viewModel.phase != .idle)

            // 焊接才要 cfg;眼图的几何是探出来的。放在这里而不是结论行,是因为
            // 它是这次测试的输入,不是结果的一部分。
            if viewModel.mode == .solder {
                Picker("", selection: $viewModel.selectedFileID) {
                    if viewModel.selectedFileID == nil {
                        Text("请选择配置").tag(String?.none)
                    }
                    ForEach(viewModel.filesForSelectedSoc) { file in
                        Text(Self.cfgLabel(file.displayName)).tag(Optional(file.id))
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 340)
                .disabled(viewModel.phase != .idle)
                .help(viewModel.filesForSelectedSoc.first { $0.id == viewModel.selectedFileID }?
                        .displayName ?? "选择焊接检测配置文件")
            }

            Spacer(minLength: 8)

            // 自动探测 / 自动测试是焊接流程专属 → 眼图模式下变灰。
            // 名字说的是结果,不只是机制:它替操作员把右边那个配置选好。开着 →
            // 配置由工具填;关掉 → 自己填。两个控件挨着,关系一眼可见。
            Toggle("自动探测配置", isOn: $viewModel.autoDetectEnabled)
                .toggleStyle(.checkbox)
                .fixedSize()
                .disabled(viewModel.mode == .eyescan)
                .help("开启后，点「开始」先读出 DDR 几何并选好匹配的配置文件，再接着测试（默认开启，仅本次运行有效）。关闭则使用你手动选择的配置文件。（焊接模式专用）")

            Button {
                Task {
                    if viewModel.mode == .solder {
                        await viewModel.startTest()
                    } else {
                        await viewModel.startEyescan()
                    }
                }
            } label: {
                Text("开始")
                    .frame(minWidth: 80)
            }
            .keyboardShortcut(.return)
            .buttonStyle(.borderedProminent)
            .disabled(!viewModel.canStart)
            .help(viewModel.mode == .eyescan ? viewModel.eyescanHelp : "")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: - Log Area

    private var logArea: some View {
        ZStack(alignment: .bottomTrailing) {
            if viewModel.testSteps.isEmpty && !viewModel.isRunning {
                VStack(spacing: 16) {
                    Image(systemName: "memorychip")
                        .font(.system(size: 36))
                        .foregroundStyle(.quaternary)
                    VStack(spacing: 8) {
                        Text(viewModel.mode.emptyStateTitle)
                            .font(.headline)
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(viewModel.mode.emptyStateSteps, id: \.text) { step in
                                Label(step.text, systemImage: step.symbol)
                            }
                        }
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.mode == .eyescan {
                // Eye-scan: ONE large log → a single full-height pane (native NSTextView, scrolls
                // internally). NOT the step-card-in-ScrollView model, which is for the multi-item
                // solder test and can't give the log the whole area.
                eyescanLogPane
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(viewModel.testSteps) { step in
                                stepCard(step)
                            }
                        }
                        .padding(16)
                    }
                    // Auto-scroll on any new content: a new step or printf
                    // appended to an existing step both bump totalMessageCount
                    // (new steps are always created with a first message), so
                    // one observer covers both. Snap-scroll, no animation —
                    // printf streams every ~100ms and animating each chunk
                    // thrashes the main thread.
                    .onChange(of: viewModel.totalMessageCount) { _ in
                        guard let last = viewModel.testSteps.last else { return }
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
                // 每轮新测试重建一个全新的 ScrollView(滚动位置回到顶部),避免复用
                // 上一轮滚到底部的偏移导致清空后显示空白。
                .id(viewModel.runToken)
            }

        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Verdict Bar

    /// 结论固定占一行,连未测时也在 —— 位置恒定,眼睛每轮都落在同一处;颜色本身
    /// 就是状态。「保存日志」放这里,因为它保存的正是这一轮的结果。
    private var verdictBar: some View {
        HStack(spacing: 10) {
            if viewModel.phase == .idle {
                Image(systemName: verdictIcon).font(.system(size: 19))
            } else {
                ProgressView().controlSize(.small).frame(width: 19)
            }
            Text(verdictTitle).font(.system(size: 17, weight: .bold))
            if let detail = verdictDetail {
                Text(detail).font(.system(size: 13)).foregroundStyle(.secondary)
            }
            Spacer()
            Button(viewModel.mode.saveButtonLabel) {
                let panel = NSSavePanel()
                panel.allowedContentTypes = [.plainText]
                panel.nameFieldStringValue = viewModel.mode.saveFileName
                panel.begin { response in
                    guard response == .OK, let url = panel.url else { return }
                    viewModel.saveResult(to: url)
                }
            }
            .disabled(!viewModel.canSaveResult)
        }
        .foregroundStyle(verdictTint)
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(verdictTint.opacity(shown == nil ? 0.05 : 0.13))
    }

    /// 跑起来之后上一轮的结论就不再成立 —— 这一行改为报告当前阶段。
    private var shown: RunConclusion? {
        viewModel.phase == .idle ? viewModel.overallConclusion : nil
    }

    private var verdictIcon: String {
        switch shown {
        case .passed: return "checkmark.circle.fill"
        case .deviceFailed: return "xmark.circle.fill"
        case .inconclusive: return "exclamationmark.triangle.fill"
        case nil: return "circle.dashed"
        }
    }

    private var verdictTitle: String {
        switch shown {
        case .passed: return "测试通过"
        case .deviceFailed: return "测试失败"
        case .inconclusive: return "未测出结论"
        case nil:
            switch viewModel.phase {
            case .idle: return "待测"
            case .detecting: return "探测中…"
            case .testing: return "测试中…"
            }
        }
    }

    /// 只有需要操作员做点什么、或需要解释的时候才出这一句。
    private var verdictDetail: String? {
        switch shown {
        case .passed: return nil
        case .deviceFailed: return "设备判定 DDR 不合格"
        case .inconclusive(let reason):
            switch reason {
            case .transport: return "USB 传输失败 —— 检查连接后重测，板子未被判定"
            case .cfg: return "配置文件缺失或无法解析，板子未被判定"
            case .noDevice: return "未找到处于 Maskrom 的设备"
            case .deviceWedged: return "设备中途停止响应 —— 请重新插拔后重试"
            case .scanIncomplete: return "扫描未在时限内完成 —— 板子正常，是耗时超限"
            }
        case nil: return viewModel.devices.isEmpty ? "插入处于 Maskrom 的板子" : nil
        }
    }

    private var verdictTint: Color {
        switch shown {
        case .passed: return .green
        case .deviceFailed: return .red
        case .inconclusive: return .orange
        case nil: return .secondary
        }
    }

    /// 每个 cfg 名都以「焊接检测.cfg」结尾 —— 八个字符每条都一样,却把真正区分
    /// 彼此的部分挤出可视区。
    static func cfgLabel(_ displayName: String) -> String {
        displayName
            .replacingOccurrences(of: "焊接检测.cfg", with: "")
            .replacingOccurrences(of: ".cfg", with: "")
            .trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Eye-scan Log Pane

    /// The eye-scan display: a status header + the full log filling the rest of the area, scrolling
    /// internally via a native NSTextView. Reads `viewModel.eyescanLog` (one growing string).
    private var eyescanLogPane: some View {
        // 没有表头:眼图只有一个步骤,它的状态就是整轮的状态,而那个由底部结论行
        // 报告 —— 表头再说一遍就是同一件事说两处。日志因此占满整个区域。
        VStack(alignment: .leading, spacing: 10) {
            LogView(text: viewModel.eyescanLog)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(nsColor: .textBackgroundColor).opacity(0.25))
                )
        }
        .padding(16)
    }

    // MARK: - Step Card

    private func stepCard(_ step: TestStep) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                stepStateIcon(step.state)
                Text(step.name)
                    .font(.system(size: 14, weight: .medium))
                if let gloss = step.gloss {
                    Text("· \(gloss)")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                stepStateLabel(step.state)
            }

            if !step.messages.isEmpty {
                // Solder steps carry only a handful of status lines — per-line Text is fine here.
                // (The high-volume eye-scan log does NOT use step cards; it has its own pane.)
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(step.messages.enumerated()), id: \.offset) { _, msg in
                        Text(msg)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
                .textSelection(.enabled)
                .padding(.leading, 24)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(stepBackgroundColor(step.state))
        )
        .id(step.id)
    }

    // MARK: - Helpers

    private func stepStateIcon(_ state: StepState) -> some View {
        Group {
            switch state {
            case .pending:
                Image(systemName: "circle")
                    .foregroundStyle(.secondary)
            case .downloading, .running:
                ProgressView().controlSize(.small)
            case .passed:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .failed:
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.red)
            }
        }
        .frame(width: 18, height: 18)
    }

    @ViewBuilder
    private func stepStateLabel(_ state: StepState) -> some View {
        switch state {
        case .pending:
            Text("等待中").font(.caption).foregroundStyle(.secondary)
        case .downloading:
            Text("下载中...").font(.caption).foregroundStyle(.blue)
        case .running:
            Text("运行中...").font(.caption).foregroundStyle(.blue)
        case .passed:
            Text("PASS").font(.caption).fontWeight(.semibold).foregroundStyle(.green)
        case .failed:
            Text("FAIL").font(.caption).fontWeight(.semibold).foregroundStyle(.red)
        }
    }

    private func stepBackgroundColor(_ state: StepState) -> Color {
        state == .running || state == .downloading
            ? .blue.opacity(0.05)
            : Color(nsColor: .controlBackgroundColor)
    }

}

/// Native AppKit text log for LARGE, high-rate streaming content (the eye-scan report). SwiftUI's
/// `Text`/`ForEach` keep every line laid out in the view tree, so once a big log is present every app
/// layout pass re-lays it and the whole app stutters. `NSTextView` lays out only the visible glyphs.
///
/// The LAYOUT is O(delta): while the shown text is an exact prefix of the new text (the streaming
/// case) we `textStorage.append` only the new tail, so TextKit lays out just the new glyphs — the old
/// `tv.string = text` path re-laid-out the whole growing document (O(n²)) and froze the UI. The append
/// DETECTION here (comparing the shown string against the new text's prefix) is O(shown) per update;
/// that's fine because the eyescan log is bounded (~6-20 KB filtered) — a few MB of copy over a whole
/// run. When the shown text is NOT a prefix — a new run cleared the log to "" — we replace once, which
/// is what makes the next scan's pane start empty instead of keeping the previous log. After any change
/// we follow the tail if the reader is parked near the bottom (auto-scroll to the newest line).
struct LogView: NSViewRepresentable {
    let text: String
    private static let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
        .foregroundColor: NSColor.secondaryLabelColor,
    ]

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.drawsBackground = false
        scroll.borderType = .noBorder

        let tv = NSTextView()
        tv.isEditable = false
        tv.isSelectable = true
        tv.drawsBackground = false
        tv.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        tv.textColor = .secondaryLabelColor
        tv.textContainerInset = NSSize(width: 0, height: 2)
        tv.minSize = NSSize(width: 0, height: 0)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.lineFragmentPadding = 0
        tv.autoresizingMask = [.width]
        scroll.documentView = tv
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? NSTextView, let storage = tv.textStorage else { return }
        let shown = tv.string
        if text == shown { return }                      // unchanged
        let ns = text as NSString
        let shownLen = (shown as NSString).length

        let followTail = (tv.frame.height - scroll.contentView.bounds.maxY) < 40
        // Content-based: if what's shown is an exact PREFIX of the new text, this is a pure append —
        // lay out only the tail. Otherwise (a new run cleared the log → the short new text is NOT
        // prefixed by the old log, or any divergence) REPLACE the whole document. This is what makes
        // clicking 开始 for the next scan clear the previous log.
        if ns.length > shownLen && ns.substring(to: shownLen) == shown {
            storage.append(NSAttributedString(string: ns.substring(from: shownLen), attributes: Self.attrs))
        } else {
            storage.setAttributedString(NSAttributedString(string: text, attributes: Self.attrs))
        }
        if followTail {
            tv.layoutManager?.ensureLayout(for: tv.textContainer!)
            tv.scrollToEndOfDocument(nil)
        }
    }
}
