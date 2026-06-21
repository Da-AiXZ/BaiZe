---
name: commit-push
description: 提交并推送代码改动到远程仓库
triggers:
  - 提交并推送
  - commit and push
  - commit-push
  - git提交推送
priority: 10
---

# Commit & Push 工作流

当用户要求提交并推送代码时，按以下步骤执行：

## 步骤 1：检查当前改动状态
- 执行 `git status` 查看工作区状态
- 执行 `git diff --stat` 查看改动概览
- 如果没有改动，告知用户"没有需要提交的改动"并结束

## 步骤 2：暂存所有改动
- 执行 `git add -A` 暂存所有改动（包括新增、修改、删除的文件）
- 如果用户指定了特定文件，则只 `git add <指定文件>`

## 步骤 3：生成提交消息
- 根据 `git diff --cached` 分析改动内容
- 生成简洁清晰的提交消息，格式遵循 Conventional Commits：
  - `feat: 新功能描述`
  - `fix: 修复描述`
  - `refactor: 重构描述`
  - `docs: 文档描述`
  - `chore: 杂项描述`
- 如果用户提供了提交消息，直接使用用户提供的消息

## 步骤 4：提交改动
- 执行 `git commit -m "<提交消息>"`
- 如果提交失败（如 pre-commit hook 失败），报告错误并停止

## 步骤 5：推送到远程
- 执行 `git push`
- 如果推送失败（如需要先 pull），尝试 `git pull --rebase` 后再 `git push`
- 如果仍然失败，报告错误让用户处理

## 步骤 6：确认完成
- 执行 `git log --oneline -1` 显示最新提交
- 告知用户提交和推送已完成
