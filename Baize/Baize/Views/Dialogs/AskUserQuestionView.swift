import SwiftUI

/// 结构化提问弹窗 — 展示 AI 提出的多问题，用户逐个回答
@MainActor
struct AskUserQuestionView: View {
    let questions: [UserQuestion]
    let onSubmit: ([String]) -> Void

    /// 用户回答数组（与 questions 一一对应）
    @State private var answers: [String]

    init(questions: [UserQuestion], onSubmit: @escaping ([String]) -> Void) {
        self.questions = questions
        self.onSubmit = onSubmit
        self._answers = State(initialValue: Array(repeating: "", count: questions.count))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // 标题
                    HStack(spacing: 8) {
                        Image(systemName: "questionmark.bubble.fill")
                            .font(.title2)
                            .foregroundColor(.baizeAccent)
                        Text("AI 提问")
                            .font(.title2.bold())
                    }

                    // 问题列表
                    ForEach(Array(questions.enumerated()), id: \.offset) { index, question in
                        questionCard(index: index, question: question)
                    }

                    // 提交按钮
                    Button(action: {
                        onSubmit(answers)
                    }) {
                        HStack(spacing: 6) {
                            Image(systemName: "paperplane.fill")
                                .font(.system(size: 16))
                            Text("提交回答")
                                .font(.system(size: 15, weight: .semibold))
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(allAnswered ? Color.baizeAccent : Color.baizeAccent.opacity(0.5))
                        .cornerRadius(10)
                    }
                    .disabled(!allAnswered)
                    .padding(.top, 8)
                }
                .padding(20)
            }
            .navigationTitle("回答问题")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    /// 是否所有问题都已回答
    private var allAnswered: Bool {
        answers.allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// 单个问题卡片
    @ViewBuilder
    private func questionCard(index: Int, question: UserQuestion) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // 问题标题
            HStack(spacing: 6) {
                Text(question.header)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color.baizeAccent)
                    .cornerRadius(6)
                Spacer()
            }

            // 问题正文
            Text(question.question)
                .font(.system(size: 15))
                .foregroundColor(.primary)
                .fixedSize(horizontal: false, vertical: true)

            // 选项按钮 或 自由文本输入
            if let options = question.options, !options.isEmpty {
                // 选项按钮
                VStack(spacing: 8) {
                    ForEach(options, id: \.self) { option in
                        Button(action: {
                            answers[index] = option
                        }) {
                            HStack(spacing: 8) {
                                Image(systemName: answers[index] == option ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 16))
                                    .foregroundColor(answers[index] == option ? .baizeAccent : .secondary)
                                Text(option)
                                    .font(.system(size: 14))
                                    .foregroundColor(.primary)
                                Spacer()
                            }
                            .padding(12)
                            .background(
                                answers[index] == option
                                    ? Color.baizeAccent.opacity(0.1)
                                    : Color.baizeCardBackground
                            )
                            .cornerRadius(8)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(
                                        answers[index] == option ? Color.baizeAccent : Color.baizeBorder,
                                        lineWidth: answers[index] == option ? 2 : 1
                                    )
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            } else {
                // 自由文本输入
                TextField("请输入回答...", text: $answers[index], axis: .vertical)
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
        }
        .padding(16)
        .background(Color.baizeCardBackground.opacity(0.5))
        .cornerRadius(12)
    }
}
