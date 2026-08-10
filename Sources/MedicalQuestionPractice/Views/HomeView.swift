import SwiftUI
import QuestionBankCore

struct HomeView: View {
    @ObservedObject var store: PracticeAppStore
    let scope: PracticeScope

    private var canStartWrongBook: Bool {
        let dashboard = store.dashboard
        return dashboard.wrongBookQuestions > 0
            && (dashboard.wrongBookQuestions >= 5 || dashboard.unseenQuestions == 0)
    }

    private var wrongBookCountText: String {
        let dashboard = store.dashboard
        if dashboard.wrongBookQuestions == 0 { return "暂无错题" }
        if dashboard.unseenQuestions > 0, dashboard.wrongBookQuestions < 5 {
            return "\(dashboard.wrongBookQuestions) 道错题，本轮 \(dashboard.wrongBookSessionQuestions) 题；满 5 道或刷完普通题后开启"
        }
        return "\(dashboard.wrongBookQuestions) 道错题，本轮 \(dashboard.wrongBookSessionQuestions) 题（每题 3 遍）"
    }

    private var dynamicPlanCountText: String {
        let plan = store.dashboard.dynamicPlan
        if !plan.isEnabled { return "请先在设置中启用并选择结束日期" }
        if plan.isFullyMastered { return "首轮题目与全部错题均已完成" }
        if plan.totalRemainingToday == 0 { return "今天的计划已经完成" }
        return "本学科今日还需 \(plan.firstPassRemainingToday) 道新题、\(plan.reviewQuestionsRemainingToday) 道复习题，并修正 \(plan.correctionQuestionsRemainingToday) 道错题"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                if scope.supportsDynamicPlan {
                    dailyPlanSection
                }
                modeSection
                statisticsSection
            }
            .padding(32)
            .frame(maxWidth: 1080, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    Task { await store.refreshDashboard() }
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(store.isLoading)

                if scope.supportsDynamicPlan {
                    Button {
                        Task { await store.buildCurrentWrongKnowledgeDocument() }
                    } label: {
                        Label("当前错题知识点整合", systemImage: "doc.text.magnifyingglass")
                    }
                    .disabled(store.isBuildingKnowledgeDocument)
                }

                Button {
                    SettingsOpener.open()
                } label: {
                    Label("设置", systemImage: "gearshape")
                }
            }
        }
        .navigationTitle(scope.displayName)
        .task(id: scope) {
            switch scope {
            case .education(let subject): await store.selectSubject(subject)
            case .xingce(let category): await store.selectXingceCategory(category)
            }
        }
        .overlay {
            if store.isLoading || store.isBuildingKnowledgeDocument {
                ProgressView(
                    store.isBuildingKnowledgeDocument
                        ? "正在补充缺失知识点并重建 Word…"
                        : "正在读取题本…"
                )
                    .padding(18)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(scope.displayName)
                .font(.largeTitle.weight(.semibold))
            Text("每道题提交后立即保存，退出当前练习时自动交卷。")
                .foregroundStyle(.secondary)
        }
    }

    private var modeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("选择练习模式")
                .font(.title2.weight(.semibold))

            LazyVGrid(
                columns: Array(
                    repeating: GridItem(.flexible(), spacing: 16),
                    count: scope.supportsDynamicPlan ? 3 : 2
                ),
                alignment: .leading,
                spacing: 16
            ) {
                if scope.supportsDynamicPlan {
                    PracticeModeCard(
                        mode: .dynamicPlan,
                        detail: "三科新题与 7—14 天到期复习题混排；错题修正另行计算并自动结转。",
                        countText: dynamicPlanCountText,
                        isEnabled: store.dashboard.dynamicPlan.isEnabled
                            && store.dashboard.dynamicPlan.totalRemainingToday > 0
                    ) {
                        Task { await store.start(.dynamicPlan) }
                    }
                }

                PracticeModeCard(
                    mode: .normal,
                    detail: "练习未做过的题，以及已经到复习时间的题。",
                    countText: "\(store.dashboard.unseenQuestions + store.dashboard.dueQuestions) 道可练习",
                    isEnabled: store.dashboard.unseenQuestions + store.dashboard.dueQuestions > 0
                ) {
                    Task { await store.start(.normal) }
                }

                PracticeModeCard(
                    mode: .wrongBook,
                    detail: "每道错题在本轮出现 3 次，采用动态间距的约束随机排列；连续做对指定次数后自动移出。",
                    countText: wrongBookCountText,
                    isEnabled: canStartWrongBook
                ) {
                    Task { await store.start(.wrongBook) }
                }
            }
        }
    }

    @ViewBuilder
    private var dailyPlanSection: some View {
        let plan = store.dashboard.dynamicPlan
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("今日动态计划")
                    .font(.title2.weight(.semibold))
                Spacer()
                if let targetDate = plan.targetDate, plan.isEnabled {
                    Text("目标：\(targetDate, format: .dateTime.year().month().day())")
                        .font(.callout)
                        .foregroundStyle(plan.isOverdue ? Color.red : Color.secondary)
                }
            }

            if plan.isEnabled {
                HStack(spacing: 18) {
                    PlanMetric(
                        title: "三科新题",
                        completed: min(plan.combinedFirstPassCompleted, plan.combinedFirstPassTarget),
                        target: plan.combinedFirstPassTarget,
                        remaining: plan.unseenRemaining
                    )
                    PlanMetric(
                        title: "三科轮转复习",
                        completed: min(plan.combinedReviewsCompleted, plan.combinedReviewTarget),
                        target: plan.combinedReviewTarget,
                        remaining: max(0, plan.combinedReviewTarget - plan.combinedReviewsCompleted)
                    )
                    PlanMetric(
                        title: "三科错题修正",
                        completed: min(plan.combinedCorrectionsCompleted, plan.combinedCorrectionTarget),
                        target: plan.combinedCorrectionTarget,
                        remaining: plan.currentWrongQuestions
                    )
                }

                Text("\(scope.displayName)今日分配：新题 \(plan.todayFirstPassCompleted) / \(plan.todayFirstPassTarget)，轮转复习 \(plan.todayReviewsCompleted) / \(plan.todayReviewTarget)；错题已修正 \(plan.todayCorrectionQuestionsCompleted) / \(plan.todayCorrectionQuestionTarget)，剩余需作答 \(plan.todayCorrectionAttemptsRemaining) 次。")
                    .font(.callout.weight(.medium))

                Text("按历史首轮错误率 \(plan.estimatedWrongProbability, format: .percent.precision(.fractionLength(1))) 预计还会新增约 \(plan.estimatedFutureWrongQuestions) 道错题，已预留 \(plan.reservedCorrectionDays) 个修正日；首轮计划按 \(plan.effectiveFirstPassDays) 天提前完成。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    if plan.isScheduleOverloaded {
                        Label("计划超载：按每日最多修正 100 道计算，当前日期可能不足", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    } else if plan.isFullyMastered {
                        Label("计划目标已全部完成", systemImage: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                    } else if plan.totalRemainingToday == 0 {
                        Label("今日计划已完成", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Text("本学科今日剩余 \(plan.firstPassRemainingToday) 道新题、\(plan.reviewQuestionsRemainingToday) 道复习题、\(plan.correctionQuestionsRemainingToday) 道错题修正")
                            .fontWeight(.medium)
                    }
                    Spacer()
                    Text(plan.isOverdue ? "目标日期已过，剩余任务按今天完成计算" : "含今天剩余 \(plan.daysRemaining) 天")
                        .foregroundStyle(plan.isOverdue ? Color.red : Color.secondary)
                }
                .font(.callout)
            } else {
                HStack {
                    Text("尚未设置共同目标日期。医学综合和政治优先安排，每天至少 200 道新题；英语仅在不足时补位且最多 30 道。另混入 7—14 天到期复习题，错题每日最多修正 100 道。")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("打开设置") { SettingsOpener.open() }
                }
            }
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 1)
        }
    }

    private var statisticsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("练习概况")
                .font(.title2.weight(.semibold))

            HStack(spacing: 12) {
                StatTile(title: "题本总数", value: store.dashboard.totalQuestions, icon: "books.vertical")
                StatTile(title: "未做过", value: store.dashboard.unseenQuestions, icon: "sparkles")
                StatTile(title: "已到复习时间", value: store.dashboard.dueQuestions, icon: "clock.arrow.circlepath")
                StatTile(title: "当前错题", value: store.dashboard.wrongBookQuestions, icon: "exclamationmark.circle")
                StatTile(title: "今日已答", value: store.dashboard.answeredToday, icon: "checkmark.circle")
            }
        }
    }
}

private struct PracticeModeCard: View {
    let mode: PracticeMode
    let detail: String
    let countText: String
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: mode.systemImage)
                .font(.system(size: 28))
                .foregroundStyle(isEnabled ? Color.accentColor : Color.secondary)

            Text(mode.title)
                .font(.title3.weight(.semibold))
            Text(detail)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(countText)
                .font(.callout.weight(.medium))
                .foregroundStyle(isEnabled ? Color.primary : Color.secondary)

            Spacer(minLength: 4)
            Button("开始\(mode.title)", action: action)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!isEnabled)
                .accessibilityHint(isEnabled ? "" : "当前没有可练习的题目")
        }
        .padding(20)
        .frame(maxWidth: .infinity, minHeight: 230, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 1)
        }
    }
}

private struct StatTile: View {
    let title: String
    let value: Int
    let icon: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon)
                .foregroundStyle(.secondary)
            Text(value.formatted())
                .font(.title.weight(.semibold).monospacedDigit())
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct PlanMetric: View {
    let title: String
    let completed: Int
    let target: Int
    let remaining: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.callout.weight(.medium))
            Text("今日 \(completed) / \(target)")
                .font(.title3.weight(.semibold).monospacedDigit())
            Text("总剩余 \(remaining)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
