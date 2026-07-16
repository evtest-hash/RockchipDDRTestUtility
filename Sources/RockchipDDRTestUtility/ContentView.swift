import DDRCore
import SwiftUI
import AppKit

struct ContentView: View {
    @StateObject private var viewModel = MainViewModel()

    var body: some View {
        HStack(spacing: 0) {
            // 眼图不选配置文件(几何自动探测)——隐藏侧边 cfg 栏,免得误以为
            // 能选 cfg 做眼图。仅焊接模式显示。
            if viewModel.mode == .solder {
                sidebar
                Divider()
            }
            mainContent
        }
        .frame(minWidth: 860, minHeight: 560)
        .navigationTitle("Rockchip DDR Test Utility")
        .task {
            await viewModel.load()
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            // CFG file list
            ScrollViewReader { proxy in
                List(selection: $viewModel.selectedFileID) {
                    ForEach(viewModel.filesForSelectedSoc) { file in
                        Text(file.displayName)
                            .font(.system(size: 12))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .tag(file.id)
                            .help(file.displayName)
                    }
                }
                .listStyle(.sidebar)
                .disabled(viewModel.isDetecting)
                .onChange(of: viewModel.selectedFileID) { newValue in
                    guard let newValue else { return }
                    proxy.scrollTo(newValue, anchor: .center)
                }
            }
        }
        .frame(minWidth: 260, maxWidth: 320)
    }

    // MARK: - Main Content

    private var mainContent: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            logArea
            Divider()
            statusBar
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Circle()
                    .fill(viewModel.devices.isEmpty ? Color.red : Color.green)
                    .frame(width: 8, height: 8)
                Text(viewModel.devices.isEmpty ? "未连接设备" : (viewModel.selectedSoc ?? "已连接设备"))
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
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
            .disabled(viewModel.isRunning || viewModel.isDetecting)

            Spacer()

            if viewModel.isDetecting || viewModel.isRunning {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text(viewModel.isDetecting ? "探测中…" : "测试中…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // 自动探测 / 自动测试是焊接流程专属 → 眼图模式下变灰。
            Toggle("自动探测", isOn: $viewModel.autoDetectEnabled)
                .toggleStyle(.checkbox)
                .disabled(viewModel.mode == .eyescan)
                .help("开启后，点「开始」会先自动探测 DDR 并选好匹配的配置文件，再接着测试（默认开启，仅本次运行有效）。关闭则使用你手动选择的配置文件。（焊接模式专用）")

            Toggle("自动测试", isOn: $viewModel.autoTestEnabled)
                .toggleStyle(.checkbox)
                .disabled(viewModel.mode == .eyescan)
                .help("开启后，插入设备即自动开始（探测+测试），适合大批量连续测试；关闭则需点「开始」。（焊接模式专用）")

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

            if let outcome = viewModel.overallOutcome {
                resultBadge(outcome)
                    .padding(16)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Eye-scan Log Pane

    /// The eye-scan display: a status header + the full log filling the rest of the area, scrolling
    /// internally via a native NSTextView. Reads `viewModel.eyescanLog` (one growing string).
    private var eyescanLogPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let step = viewModel.testSteps.first {
                HStack(spacing: 8) {
                    stepStateIcon(step.state)
                    Text(step.name)
                        .font(.system(size: 14, weight: .medium))
                    Spacer()
                    stepStateLabel(step.state)
                }
            }
            LogView(text: viewModel.eyescanLog)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(nsColor: .textBackgroundColor).opacity(0.25))
                )
        }
        .padding(16)
    }

    // MARK: - Status Bar

    private var statusBar: some View {
        HStack {
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
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    // MARK: - Step Card

    private func stepCard(_ step: TestStep) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                stepStateIcon(step.state)
                Text(step.name)
                    .font(.system(size: 14, weight: .medium))
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
        switch state {
        case .passed: return .green.opacity(0.06)
        case .failed: return .red.opacity(0.06)
        case .downloading, .running: return .blue.opacity(0.04)
        default: return Color(nsColor: .controlBackgroundColor)
        }
    }

    private func resultBadge(_ outcome: TestOutcome) -> some View {
        let isPass = outcome == .passed
        return HStack(spacing: 8) {
            Image(systemName: isPass ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.title2)
            Text(isPass ? "测试通过" : "测试失败")
                .font(.title3)
                .fontWeight(.bold)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isPass ? .green : .red)
                .shadow(color: Color(isPass ? .green : .red).opacity(0.3), radius: 8, y: 4)
        )
    }
}

/// Native AppKit text log for LARGE content (the eye-scan report, ~592 lines). SwiftUI's
/// `Text`/`ForEach` keep every line laid out in the view tree, so once a big log is present every
/// app layout pass re-lays it and the whole app stutters. `NSTextView` lays out only the visible
/// glyphs (cached layout manager) and scrolls natively — flat cost regardless of log length.
/// Read-only + selectable; the drain is already decoupled from the UI, so string updates here can
/// never affect the USB pipeline.
struct LogView: NSViewRepresentable {
    let text: String

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
        guard let tv = scroll.documentView as? NSTextView, tv.string != text else { return }
        // Was the user parked near the bottom BEFORE this update? (Compare the viewport bottom to
        // the current document height.) If so, follow the newest content; if they scrolled up to
        // read, leave their position alone. Content only changes while streaming, so this pins the
        // live tail without yanking a reader who scrolled back.
        let followTail = (tv.frame.height - scroll.contentView.bounds.maxY) < 40
        tv.string = text
        tv.textColor = .secondaryLabelColor
        if followTail {
            tv.layoutManager?.ensureLayout(for: tv.textContainer!)   // lay out new text first…
            tv.scrollToEndOfDocument(nil)                            // …then pin to the bottom
        }
    }
}
