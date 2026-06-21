import SwiftUI

/// PlanMode 审批弹窗 — 展示 AI 生成的计划，用户批准或拒绝
@MainActor
struct PlanApprovalView: View {
    let plan: String
    let onApprove: () -> Void
    let onReject: (String) -> Void

    @State private var rejectionReason: String = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // 标题
                    HStack(spacing: 8) {
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.title2)
                            .foregroundColor(.baizeAccent)
                        Text("计划审批")
                            .font(.title2.bold())
                    }
                    .padding(.bottom, 4)

                    Text("AI 提交了以下执行计划，请审阅后批准或拒绝。")
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    // 计划文本
                    Text(plan)
                        .font(.system(size: 14))
                        .foregroundColor(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                        .background(Color.baizeCardBackground)
                        .cornerRadius(12)

                    // 拒绝原因输入（可选）
                    VStack(alignment: .leading, spacing: 8) {
                        Text("拒绝原因（可选）")
                            .font(.caption.weight(.medium))
                            .foregroundColor(.secondary)
                        TextField("如需拒绝，请填写原因...", text: $rejectionReason, axis: .vertical)
                            .textFieldStyle(.plain)
                            .font(.system(size: 14))
                            .padding(12)
                            .background(Color.baizeCardBackground)
                            .cornerRadius(8)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.baizeBorder, lineWidth: 1)
                            )
                            .lineLimit(3...6)
                    }

                    // 操作按钮
                    HStack(spacing: 12) {
                        Button(action: {
                            onReject(rejectionReason.isEmpty ? "用户拒绝" : rejectionReason)
                        }) {
                            HStack(spacing: 6) {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 16))
                                Text("拒绝")
                                    .font(.system(size: 15, weight: .semibold))
                            }
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Color.baizeError)
                            .cornerRadius(10)
                        }

                        Button(action: {
                            onApprove()
                        }) {
                            HStack(spacing: 6) {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 16))
                                Text("批准")
                                    .font(.system(size: 15, weight: .semibold))
                            }
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Color.baizeSuccess)
                            .cornerRadius(10)
                        }
                    }
                    .padding(.top, 8)
                }
                .padding(20)
            }
            .navigationTitle("计划审批")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
