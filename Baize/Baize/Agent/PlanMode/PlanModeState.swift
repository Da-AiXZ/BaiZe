import Foundation

/// PlanMode 状态机 — 管理计划模式的进入/退出/审批流程
///
/// 状态流转：
/// idle → enter() → planning → exit(plan:) → awaitingApproval → approve() → approved
///                                                            → reject(reason:) → rejected
///
/// 计划模式下：
/// - AI 只能做只读操作（read_file/list_directory/search 等）
/// - 禁止写操作（write_file/edit_file/execute_command 等）
/// - AI 生成计划后请求用户审批
/// - 用户批准后才退出计划模式，开始执行
actor PlanModeState {

    // MARK: - Phase

    /// 计划模式阶段
    enum PlanModePhase: Sendable {
        /// 空闲（未进入计划模式）
        case idle
        /// 规划中（AI 正在收集信息、生成计划）
        case planning
        /// 等待审批（AI 已提交计划，等待用户批准/拒绝）
        case awaitingApproval
        /// 已批准（用户批准了计划）
        case approved
        /// 已拒绝（用户拒绝了计划）
        case rejected
    }

    // MARK: - Properties

    /// 当前阶段
    private var phase: PlanModePhase = .idle

    /// AI 生成的计划文本
    private var plan: String? = nil

    /// 拒绝原因（用户拒绝时记录）
    private var rejectionReason: String? = nil

    /// 等待审批的 continuation（exit 时挂起，approve/reject 时恢复）
    private var approvalContinuation: CheckedContinuation<Bool, Never>? = nil

    // MARK: - Initialization

    init() {
        planModeLogger.info("PlanModeState initialized (idle)")
    }

    // MARK: - State Transitions

    /// 进入计划模式
    /// 从 idle 转为 planning，重置计划文本
    func enter() {
        guard phase == .idle else {
            planModeLogger.warning("PlanModeState: cannot enter from phase \(String(describing: self.phase), privacy: .public)")
            return
        }
        phase = .planning
        plan = nil
        rejectionReason = nil
        planModeLogger.info("PlanModeState: entered planning mode")
    }

    /// 退出计划模式，提交计划等待审批
    /// 从 planning 转为 awaitingApproval，挂起等待用户 approve/reject
    /// - Parameter plan: AI 生成的计划文本
    /// - Returns: true=用户批准，false=用户拒绝
    func exit(plan: String) async -> Bool {
        guard phase == .planning else {
            planModeLogger.warning("PlanModeState: cannot exit from phase \(String(describing: self.phase), privacy: .public)")
            return false
        }

        self.plan = plan
        self.phase = .awaitingApproval
        planModeLogger.info("PlanModeState: plan submitted, awaiting approval")

        // 挂起等待审批结果
        return await withCheckedContinuation { continuation in
            self.approvalContinuation = continuation
        }
    }

    /// 用户批准计划
    /// 从 awaitingApproval 转为 approved，恢复 continuation
    func approve() {
        guard phase == .awaitingApproval else {
            planModeLogger.warning("PlanModeState: cannot approve from phase \(String(describing: self.phase), privacy: .public)")
            return
        }
        phase = .approved
        planModeLogger.info("PlanModeState: plan approved")
        approvalContinuation?.resume(returning: true)
        approvalContinuation = nil
    }

    /// 用户拒绝计划
    /// 从 awaitingApproval 转为 rejected，恢复 continuation
    /// - Parameter reason: 拒绝原因
    func reject(reason: String) {
        guard phase == .awaitingApproval else {
            planModeLogger.warning("PlanModeState: cannot reject from phase \(String(describing: self.phase), privacy: .public)")
            return
        }
        phase = .rejected
        rejectionReason = reason
        planModeLogger.info("PlanModeState: plan rejected — \(reason)")
        approvalContinuation?.resume(returning: false)
        approvalContinuation = nil
    }

    /// 重置到 idle 状态（审批完成后调用）
    func reset() {
        phase = .idle
        plan = nil
        rejectionReason = nil
        approvalContinuation = nil
        planModeLogger.info("PlanModeState: reset to idle")
    }

    // MARK: - Querying

    /// 当前是否在计划模式中（planning 或 awaitingApproval）
    func isInPlanMode() -> Bool {
        phase == .planning || phase == .awaitingApproval
    }

    /// 是否可以执行写操作（非计划模式时允许）
    func canExecuteWrite() -> Bool {
        !isInPlanMode()
    }

    /// 获取当前阶段
    func getPhase() -> PlanModePhase {
        phase
    }

    /// 获取计划文本
    func getPlan() -> String? {
        plan
    }

    /// 获取拒绝原因
    func getRejectionReason() -> String? {
        rejectionReason
    }
}
