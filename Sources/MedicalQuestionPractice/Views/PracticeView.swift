import SwiftUI

struct PracticeView: View {
    @ObservedObject var store: PracticeAppStore
    @State private var selectedOptionIDs: Set<String> = []
    @State private var typedAnswer = ""
    @State private var excludedOptionIDsByQuestion: [String: Set<String>] = [:]
    @State private var submittedAsUnknown = false
    @State private var pageOffset: CGFloat = 0
    @State private var isPageAnimating = false
    @AppStorage(PracticeInteractionPreferences.swipeThresholdKey)
    private var swipeThreshold = PracticeInteractionPreferences.defaultSwipeThreshold

    private var session: PracticeSessionState? { store.session }
    private var question: PracticeQuestion? {
        store.reviewedAnswer?.question ?? store.answeredQuestion ?? session?.currentQuestion
    }
    private var displayedFeedback: AnswerFeedback? {
        store.reviewedAnswer?.feedback ?? store.feedback
    }
    private var isReviewingAnswer: Bool { store.reviewedAnswer != nil }

    var body: some View {
        VStack(spacing: 0) {
            practiceHeader
            Divider()

            GeometryReader { geometry in
                ZStack {
                    Color(nsColor: .windowBackgroundColor)
                    practicePage
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .offset(x: pageOffset)
                        .rotation3DEffect(
                            .degrees(Double(pageOffset / max(geometry.size.width, 1)) * 4),
                            axis: (x: 0, y: 1, z: 0),
                            anchor: pageOffset < 0 ? .leading : .trailing,
                            perspective: 0.28
                        )
                        .shadow(
                            color: .black.opacity(min(abs(pageOffset) / 900, 0.16)),
                            radius: min(abs(pageOffset) / 18, 18),
                            x: pageOffset < 0 ? -5 : 5
                        )
                }
                .clipped()
                .background(
                    TrackpadHorizontalSwipeBridge(
                        threshold: CGFloat(swipeThreshold),
                        onProgress: { updatePageOffset($0, pageWidth: geometry.size.width) },
                        onEnded: { direction, crossesThreshold in
                            finishPageSwipe(
                                direction: direction,
                                crossesThreshold: crossesThreshold,
                                pageWidth: geometry.size.width
                            )
                        }
                    )
                )
            }
        }
        .onChange(of: question?.id) { _ in
            selectedOptionIDs = displayedFeedback?.selectedOptionIDs ?? []
            typedAnswer = displayedFeedback?.typedAnswer ?? ""
            submittedAsUnknown = displayedFeedback?.markedAsUnsure == true
        }
        .onDisappear {
            store.leavePractice()
        }
        .navigationTitle(session?.mode.title ?? "练习")
    }

    @ViewBuilder
    private var practicePage: some View {
        VStack(spacing: 0) {
            if let session, session.isComplete, displayedFeedback == nil, !isReviewingAnswer {
                CompletionView(mode: session.mode) {
                    store.leavePractice()
                }
            } else if let question {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        questionHeader(question)
                        QuestionRichContentView(content: question.stem, textFont: .title3)

                        answerArea(for: question)

                        if let feedback = displayedFeedback {
                            FeedbackView(feedback: feedback, question: question)
                        }
                    }
                    .padding(32)
                    .frame(maxWidth: 900, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }

                Divider()
                actionBar
            } else {
                EmptyPracticeView()
            }
        }
    }

    private var practiceHeader: some View {
        HStack(spacing: 14) {
            Button {
                store.leavePractice()
            } label: {
                Label("交卷并返回主页", systemImage: "chevron.left")
            }
            .keyboardShortcut(.escape, modifiers: [])

            if let session {
                Text(session.mode.title)
                    .font(.headline)
                if session.mode == .dynamicPlan {
                    Label(
                        "今日剩余 \(store.dashboard.dynamicPlan.totalRemainingToday)",
                        systemImage: "calendar.badge.clock"
                    )
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
                } else {
                    Label(
                        "错题 \(store.dashboard.wrongBookQuestions)",
                        systemImage: "exclamationmark.circle"
                    )
                    .font(.callout.weight(.medium))
                    .foregroundStyle(store.dashboard.wrongBookQuestions > 0 ? Color.red : Color.secondary)
                }
                Spacer()
                Text("进度 \(progressPercentage(for: session))%")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                ProgressView(
                    value: Double(session.currentIndex),
                    total: Double(max(session.totalCount, 1))
                )
                .frame(width: 150)
                .accessibilityLabel("练习进度")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(.bar)
    }

    @ViewBuilder
    private func questionHeader(_ question: PracticeQuestion) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Text(question.requiresTypedAnswer ? "论述题" : (question.allowsMultipleSelection ? "多选题" : "单选题"))
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.quaternary, in: Capsule())

            if let progress = question.wrongBookProgress {
                Label(
                    "连续做对 \(progress.consecutiveCorrect) / \(progress.requiredCorrect)",
                    systemImage: "target"
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }
        }
    }

    private func answerArea(for question: PracticeQuestion) -> some View {
        VStack(spacing: 10) {
            if question.requiresTypedAnswer {
                VStack(alignment: .leading, spacing: 8) {
                    Text("作答内容")
                        .font(.headline)
                    TextEditor(text: $typedAnswer)
                        .font(.body)
                        .frame(minHeight: 220)
                        .padding(10)
                        .scrollContentBackground(.hidden)
                        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                        .overlay {
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(Color.secondary.opacity(0.28), lineWidth: 1)
                        }
                        .disabled(displayedFeedback != nil || store.isSubmitting)
                }
            } else {
                ForEach(Array(question.options.enumerated()), id: \.element.id) { index, option in
                    optionRow(option, index: index, question: question)
                }
            }

            UnknownAnswerRow(
                isSelected: submittedAsUnknown || displayedFeedback?.markedAsUnsure == true,
                hasFeedback: displayedFeedback != nil,
                isSubmitting: store.isSubmitting
            ) {
                selectedOptionIDs = []
                typedAnswer = ""
                submittedAsUnknown = true
                submitCurrentAnswer([], markAsUnknown: true)
            }
        }
    }

    @ViewBuilder
    private func optionRow(_ option: PracticeOption, index: Int, question: PracticeQuestion) -> some View {
        OptionRow(
            label: optionLabel(index),
            option: option,
            isSelected: selectedOptionIDs.contains(option.id),
            isExcluded: excludedOptionIDs(for: question).contains(option.id),
            feedback: displayedFeedback,
            shortcut: index < 9 ? KeyEquivalent(Character(String(index + 1))) : nil,
            selectionAction: {
                select(
                    option.id,
                    questionID: question.id,
                    allowsMultiple: question.allowsMultipleSelection
                )
            },
            exclusionAction: {
                toggleExclusion(option.id, questionID: question.id)
            }
        )
    }

    private var actionBar: some View {
        HStack {
            Text(actionHint)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()

            if isReviewingAnswer {
                Button("下一题") {
                    store.showNextQuestion()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            } else if store.feedback != nil {
                Button(session?.isComplete == true ? "完成练习" : "下一题") {
                    store.advanceAfterFeedback()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.return, modifiers: [])
            } else if question?.requiresTypedAnswer == true {
                Button {
                    submitCurrentAnswer([], typedAnswer: typedAnswer)
                } label: {
                    if store.isSubmitting {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("正在按解析评分…")
                        }
                    } else {
                        Text("提交论述答案")
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(typedAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.isSubmitting)
            } else if question?.allowsMultipleSelection == false {
                Text("点击字母即提交")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
            } else {
                Button {
                    submitCurrentAnswer(selectedOptionIDs)
                } label: {
                    if store.isSubmitting {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text("提交答案")
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(selectedOptionIDs.isEmpty || store.isSubmitting)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(.bar)
    }

    private func select(_ optionID: String, questionID: String, allowsMultiple: Bool) {
        guard displayedFeedback == nil, !isReviewingAnswer else { return }
        guard excludedOptionIDsByQuestion[questionID]?.contains(optionID) != true else { return }
        if allowsMultiple {
            if selectedOptionIDs.contains(optionID) {
                selectedOptionIDs.remove(optionID)
            } else {
                selectedOptionIDs.insert(optionID)
            }
        } else {
            selectedOptionIDs = [optionID]
            submitCurrentAnswer([optionID])
        }
    }

    private func excludedOptionIDs(for question: PracticeQuestion) -> Set<String> {
        excludedOptionIDsByQuestion[question.id] ?? []
    }

    private func toggleExclusion(_ optionID: String, questionID: String) {
        guard displayedFeedback == nil, !isReviewingAnswer else { return }
        var excluded = excludedOptionIDsByQuestion[questionID] ?? []
        if excluded.contains(optionID) {
            excluded.remove(optionID)
        } else {
            excluded.insert(optionID)
            selectedOptionIDs.remove(optionID)
        }
        if excluded.isEmpty {
            excludedOptionIDsByQuestion.removeValue(forKey: questionID)
        } else {
            excludedOptionIDsByQuestion[questionID] = excluded
        }
    }

    private func submitCurrentAnswer(
        _ selection: Set<String>,
        typedAnswer: String? = nil,
        markAsUnknown: Bool = false
    ) {
        Task {
            await store.submit(
                selectedOptionIDs: selection,
                typedAnswer: typedAnswer,
                markAsUnsure: markAsUnknown
            )
            if markAsUnknown, store.feedback == nil {
                submittedAsUnknown = false
            }
            if store.feedback?.isCorrect == true, question?.requiresTypedAnswer != true {
                store.advanceAfterFeedback()
            }
        }
    }

    private func optionLabel(_ index: Int) -> String {
        guard index < 26 else { return String(index + 1) }
        return String(UnicodeScalar(65 + index)!)
    }

    private var actionHint: String {
        if displayedFeedback != nil {
            return "本题记录已保存·触控板双指左右滑动可切换已答题"
        }
        if question?.requiresTypedAnswer == true {
            return "提交后将按原解析分值逐项评分；接口成功返回后才保存作答"
        }
        return "点击选项文字可排除或恢复·点击字母或按数字键 1–9 作答"
    }

    private func progressPercentage(for session: PracticeSessionState) -> Int {
        guard session.totalCount > 0 else { return 0 }
        let ratio = Double(session.currentIndex) / Double(session.totalCount)
        return Int((min(max(ratio, 0), 1) * 100).rounded())
    }

    private func updatePageOffset(_ rawOffset: CGFloat, pageWidth: CGFloat) {
        guard !isPageAnimating else { return }
        let limitedOffset = max(-pageWidth * 0.72, min(pageWidth * 0.72, rawOffset))
        let directionIsAvailable = limitedOffset < 0
            ? store.canShowNextQuestion
            : store.canShowPreviousQuestion
        var transaction = Transaction()
        transaction.animation = nil
        withTransaction(transaction) {
            pageOffset = directionIsAvailable ? limitedOffset : limitedOffset * 0.18
        }
    }

    private func finishPageSwipe(
        direction: TrackpadSwipeDirection?,
        crossesThreshold: Bool,
        pageWidth: CGFloat
    ) {
        guard !isPageAnimating else { return }
        let canChangePage: Bool
        switch direction {
        case .left: canChangePage = store.canShowNextQuestion
        case .right: canChangePage = store.canShowPreviousQuestion
        case nil: canChangePage = false
        }
        guard crossesThreshold, canChangePage, let direction else {
            withAnimation(.interpolatingSpring(stiffness: 420, damping: 38)) {
                pageOffset = 0
            }
            return
        }

        isPageAnimating = true
        let exitOffset = direction == .left ? -pageWidth : pageWidth
        withAnimation(.easeOut(duration: 0.13)) {
            pageOffset = exitOffset
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.13) {
            switch direction {
            case .left: store.showNextQuestion()
            case .right: store.showPreviousQuestion()
            }

            var transaction = Transaction()
            transaction.animation = nil
            withTransaction(transaction) {
                pageOffset = direction == .left
                    ? min(pageWidth * 0.22, 190)
                    : -min(pageWidth * 0.22, 190)
            }
            withAnimation(.interpolatingSpring(stiffness: 500, damping: 42)) {
                pageOffset = 0
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) {
                isPageAnimating = false
            }
        }
    }
}

private struct UnknownAnswerRow: View {
    let isSelected: Bool
    let hasFeedback: Bool
    let isSubmitting: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 12) {
                Text("?")
                    .font(.callout.weight(.semibold))
                    .frame(width: 28, height: 28)
                    .background(isSelected ? Color.red.opacity(0.18) : Color.secondary.opacity(0.12), in: Circle())
                Text("我不会")
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if isSelected, hasFeedback {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.red)
                }
            }
            .padding(14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(isSelected ? Color.red.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(isSelected ? Color.red : Color.secondary.opacity(0.25), lineWidth: isSelected ? 1.5 : 1)
        }
        .disabled(hasFeedback || isSubmitting)
        .accessibilityLabel("我不会")
        .accessibilityHint("提交本题并加入错题本")
    }
}

private struct OptionRow: View {
    let label: String
    let option: PracticeOption
    let isSelected: Bool
    let isExcluded: Bool
    let feedback: AnswerFeedback?
    let shortcut: KeyEquivalent?
    let selectionAction: () -> Void
    let exclusionAction: () -> Void

    private var isCorrectOption: Bool { feedback?.correctOptionIDs.contains(option.id) == true }
    private var isWrongSelection: Bool {
        feedback != nil && isSelected && !isCorrectOption
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            selectionControl

            Button(action: exclusionAction) {
                QuestionRichContentView(
                    content: option.text,
                    showsStrikethrough: isExcluded
                )
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .opacity(isExcluded ? 0.52 : 1)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(feedback != nil)
            .accessibilityLabel(
                isExcluded
                    ? "取消排除选项 \(label)，\(option.text)"
                    : "排除选项 \(label)，\(option.text)"
            )
            .accessibilityHint(isExcluded ? "再次点击恢复此选项" : "点击后用横线划掉此选项")

            if isCorrectOption {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else if isWrongSelection {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.red)
            }
        }
        .padding(14)
    }

    @ViewBuilder
    private var selectionControl: some View {
        let button = Button(action: selectionAction) {
                Text(label)
                    .font(.callout.weight(.semibold))
                    .frame(width: 28, height: 28)
                    .background(labelBackground, in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(feedback != nil || isExcluded)
        .accessibilityLabel("选择选项 \(label)，\(option.text)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])

        if let shortcut {
            button.keyboardShortcut(shortcut, modifiers: [])
        } else {
            button
        }
    }

    private var labelBackground: Color {
        if isCorrectOption { return .green.opacity(0.18) }
        if isWrongSelection { return .red.opacity(0.18) }
        if isExcluded { return .secondary.opacity(0.08) }
        return isSelected ? .accentColor.opacity(0.18) : .secondary.opacity(0.12)
    }

}

private struct FeedbackView: View {
    let feedback: AnswerFeedback
    let question: PracticeQuestion

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(feedbackTitle, systemImage: feedback.isCorrect ? "checkmark.circle.fill" : "xmark.circle.fill")
            .font(.headline)
            .foregroundStyle(feedback.isCorrect ? Color.green : Color.red)

            if let evaluation = feedback.essayEvaluation {
                Text("总分：\(evaluation.score) / \(evaluation.maximumScore)")
                    .font(.title3.weight(.semibold))
                ForEach(Array(evaluation.criteria.enumerated()), id: \.offset) { _, criterion in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: criterion.passed ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(criterion.passed ? Color.green : Color.orange)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("\(criterion.title)：\(criterion.awardedScore) / \(criterion.maximumScore)")
                                .font(.callout.weight(.semibold))
                            Text(criterion.comment)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Text(evaluation.summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if feedback.removedFromWrongBook {
                Label("已达到连续正确次数，自动移出错题本。", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                    .font(.headline)
            } else if let progress = feedback.wrongBookProgress, feedback.isInWrongBook {
                Label(
                    "错题掌握进度：\(progress.consecutiveCorrect) / \(progress.requiredCorrect)",
                    systemImage: "target"
                )
                .foregroundStyle(.secondary)
            }

            if let explanation = feedback.explanation,
               !explanation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Divider()
                Text("解析")
                    .font(.headline)
                QuestionRichContentView(
                    content: ExplanationOptionLabelMapper.displayText(explanation, options: question.options)
                )
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private var feedbackTitle: String {
        if let evaluation = feedback.essayEvaluation {
            return evaluation.passed ? "论述题评分通过" : "论述题评分未通过"
        }
        return feedback.isCorrect ? "回答正确" : "回答错误"
    }
}

private struct CompletionView: View {
    let mode: PracticeMode
    let action: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.seal")
                .font(.system(size: 48))
                .foregroundStyle(.green)
            Text("本轮练习已完成")
                .font(.title2.weight(.semibold))
            Text("\(mode.title)中的每道作答都已保存。")
                .foregroundStyle(.secondary)
            Button("返回主页", action: action)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: [])
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct EmptyPracticeView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "questionmark.folder")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("无法读取当前题目")
                .font(.title3.weight(.semibold))
            Text("请返回主页刷新题本。")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
