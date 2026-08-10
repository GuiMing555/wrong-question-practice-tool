import AppKit
import SwiftUI
import QuestionBankCore

struct SettingsView: View {
    @ObservedObject var store: PracticeAppStore
    @State private var settings = PracticeSettings()
    @State private var useAllEligibleQuestions = true
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var statusMessage: String?
    @State private var swipeThreshold = PracticeInteractionPreferences.defaultSwipeThreshold
    @State private var apiConfiguration = SharedContentServiceConfiguration()

    var body: some View {
        Form {
            Section("当前科目") {
                LabeledContent("设置适用题本") {
                    Text(store.currentScope.displayName)
                        .fontWeight(.medium)
                }
                Text("每个科目的复习间隔、错题移出次数和每轮题数分别保存。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("题目分析 API（两个程序共用）") {
                Toggle("启用题目分析 API", isOn: $apiConfiguration.enabled)
                TextField("接口地址", text: $apiConfiguration.endpoint)
                    .textFieldStyle(.roundedBorder)
                TextField("模型", text: $apiConfiguration.model)
                    .textFieldStyle(.roundedBorder)
                SecureField("访问密钥", text: $apiConfiguration.accessKey)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    TextField("Word 保存位置", text: $apiConfiguration.knowledgeDocumentFolderPath)
                        .textFieldStyle(.roundedBorder)
                    Button("选择…", action: chooseKnowledgeFolder)
                }
                Text("截图整理和练习程序读写同一份本地设置；缺失的错题知识点会在生成 Word 时自动补齐。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if store.currentScope.supportsDynamicPlan {
                Section("升学考试三科动态计划") {
                    Toggle("启用动态计划模式", isOn: dynamicPlanEnabledBinding)
                    if settings.dynamicPlanEnabled {
                        DatePicker(
                            "目标学习结束日期",
                            selection: dynamicPlanTargetDateBinding,
                            displayedComponents: .date
                        )
                        Text("医学综合和政治优先安排，每天合计至少 200 道新题；为保证目标日前完成首轮，时间紧张时自动提高。英语仅在前两科计划不足时补位，每天最多 30 道，且不参与截止日超载判断。上次作答满 7 天的题会混入轮转复习，最迟在第 14 天前安排；错题修正每天最多 100 道，并根据历史首轮错误率预留修正日。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("启用后，三个升学科目共用目标日期，并按各科题本总量动态分配每日题量。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("普通模式") {
                Stepper(value: $settings.normalReviewIntervalDays, in: 1...365) {
                    LabeledContent("重新出题间隔") {
                        Text("\(settings.normalReviewIntervalDays) 天")
                            .monospacedDigit()
                    }
                }
                Text("题目最后一次作答超过该时间后，会再次进入普通模式。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("错题模式") {
                Stepper(value: $settings.wrongRequiredConsecutiveCorrect, in: 1...20) {
                    LabeledContent("自动移出所需连续正确次数") {
                        Text("\(settings.wrongRequiredConsecutiveCorrect) 次")
                            .monospacedDigit()
                    }
                }
                .disabled(settings.dynamicPlanEnabled)
                Text("每轮每道错题出现 3 次；再次答错时，连续正确次数会重置为 0。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if settings.dynamicPlanEnabled {
                    Text("动态计划启用期间固定为连续答对 3 次。")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.orange)
                }
            }

            Section("每轮题数") {
                Toggle("练习全部符合条件的题", isOn: $useAllEligibleQuestions)
                if !useAllEligibleQuestions {
                    Stepper(value: questionLimitBinding, in: 5...500, step: 5) {
                        LabeledContent("每轮上限") {
                            Text("\(settings.questionsPerSession ?? 20) 题")
                                .monospacedDigit()
                        }
                    }
                }
                Text("普通模式按题目数量限制；错题模式按错题数量限制，并展开为每题 3 遍。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("翻页手势") {
                LabeledContent("切换触发距离") {
                    Text("\(Int(swipeThreshold)) 点")
                        .monospacedDigit()
                }
                Slider(value: $swipeThreshold, in: 60...220, step: 10)
                Text("滑动松手时达到该距离才会翻页；数值越小越灵敏。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let statusMessage {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("保存设置") {
                    Task { await save() }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(isLoading || isSaving)
            }
        }
        .formStyle(.grouped)
        .frame(width: 620, height: 860)
        .task { await load() }
        .overlay {
            if isLoading {
                ProgressView()
            }
        }
    }

    private var questionLimitBinding: Binding<Int> {
        Binding(
            get: { settings.questionsPerSession ?? 20 },
            set: { settings.questionsPerSession = $0 }
        )
    }

    private var dynamicPlanEnabledBinding: Binding<Bool> {
        Binding(
            get: { settings.dynamicPlanEnabled },
            set: { enabled in
                settings.dynamicPlanEnabled = enabled
                if enabled {
                    settings.wrongRequiredConsecutiveCorrect = 3
                    if settings.dynamicPlanTargetDate == nil {
                        settings.dynamicPlanTargetDate = Calendar.current.date(
                            byAdding: .day,
                            value: 30,
                            to: Date()
                        ) ?? Date()
                    }
                }
            }
        )
    }

    private var dynamicPlanTargetDateBinding: Binding<Date> {
        Binding(
            get: {
                settings.dynamicPlanTargetDate
                    ?? Calendar.current.date(byAdding: .day, value: 30, to: Date())
                    ?? Date()
            },
            set: { settings.dynamicPlanTargetDate = $0 }
        )
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            settings = try await store.loadSettings()
            apiConfiguration = SharedContentServiceConfigurationStore.load()
            useAllEligibleQuestions = settings.questionsPerSession == nil
            let savedThreshold = UserDefaults.standard.double(
                forKey: PracticeInteractionPreferences.swipeThresholdKey
            )
            swipeThreshold = savedThreshold > 0
                ? savedThreshold
                : PracticeInteractionPreferences.defaultSwipeThreshold
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        do {
            if useAllEligibleQuestions {
                settings.questionsPerSession = nil
            } else if settings.questionsPerSession == nil {
                settings.questionsPerSession = 20
            }
            if settings.dynamicPlanEnabled {
                settings.wrongRequiredConsecutiveCorrect = 3
                if settings.dynamicPlanTargetDate == nil {
                    settings.dynamicPlanTargetDate = Date()
                }
            }
            try SharedContentServiceConfigurationStore.save(apiConfiguration)
            try await store.saveSettings(settings)
            UserDefaults.standard.set(
                swipeThreshold,
                forKey: PracticeInteractionPreferences.swipeThresholdKey
            )
            statusMessage = "设置已保存。"
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func chooseKnowledgeFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "选择"
        if !apiConfiguration.knowledgeDocumentFolderPath.isEmpty {
            panel.directoryURL = URL(
                fileURLWithPath: apiConfiguration.knowledgeDocumentFolderPath,
                isDirectory: true
            )
        }
        if panel.runModal() == .OK, let url = panel.url {
            apiConfiguration.knowledgeDocumentFolderPath = url.standardizedFileURL.path
        }
    }
}
