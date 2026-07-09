import DDRCore
import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = MainViewModel()

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
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

            Toggle("自动探测", isOn: $viewModel.autoDetectEnabled)
                .toggleStyle(.checkbox)
                .help("开启后，点「开始测试」会先自动探测 DDR 并选好匹配的配置文件，再接着测试（默认开启，仅本次运行有效）。关闭则使用你手动选择的配置文件。")

            Toggle("自动测试", isOn: $viewModel.autoTestEnabled)
                .toggleStyle(.checkbox)
                .help("开启后，插入设备即自动开始（探测+测试），适合大批量连续测试；关闭则需点「开始测试」。")

            Button {
                Task { await viewModel.startTest() }
            } label: {
                Text("开始测试")
                    .frame(minWidth: 80)
            }
            .keyboardShortcut(.return)
            .disabled(viewModel.isRunning || viewModel.isDetecting || viewModel.devices.isEmpty)
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
                        Text("DDR 焊接质量测试")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 4) {
                            Label("连接设备（Maskrom 状态）", systemImage: "1.circle")
                            Label("点「开始测试」：自动识别 DDR 并选好配置", systemImage: "2.circle")
                            Label("查看焊接质量结果", systemImage: "3.circle")
                        }
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            }

            if let outcome = viewModel.overallOutcome {
                resultBadge(outcome)
                    .padding(16)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Status Bar

    private var statusBar: some View {
        HStack {
            Spacer()

            Button("保存测试结果") {
                let panel = NSSavePanel()
                panel.allowedContentTypes = [.plainText]
                panel.nameFieldStringValue = "DDR_Test_Result.txt"
                panel.begin { response in
                    guard response == .OK, let url = panel.url else { return }
                    viewModel.saveResult(to: url)
                }
            }
            .disabled(viewModel.lastResult == nil || viewModel.isRunning)
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
