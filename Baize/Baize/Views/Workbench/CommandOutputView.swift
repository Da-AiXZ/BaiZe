import SwiftUI

/// 命令输出查看 — 展示 Agent 执行的命令历史输出
@MainActor
struct CommandOutputView: View {
    @ObservedObject var appState: AppState

    var body: some View {
        if let terminalVM = appState.terminalViewModel {
            if terminalVM.outputLines.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "terminal")
                        .font(.system(size: 28))
                        .foregroundColor(.secondary)
                    Text("暂无命令输出")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
            } else {
                // 滚动文本输出
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(terminalVM.outputLines) { line in
                                Text(line.content)
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundColor(line.type == .error ? .baizeError : .primary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            Color.clear
                                .frame(height: 1)
                                .id("commandOutputBottom")
                        }
                        .padding(12)
                    }
                    .onChange(of: terminalVM.outputLines.count) { _ in
                        withAnimation {
                            proxy.scrollTo("commandOutputBottom", anchor: .bottom)
                        }
                    }
                }
                .frame(minHeight: 120, maxHeight: 240)
            }
        } else {
            Text("终端未初始化")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding()
        }
    }
}
