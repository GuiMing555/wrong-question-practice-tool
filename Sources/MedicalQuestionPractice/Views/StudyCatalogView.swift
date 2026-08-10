import SwiftUI
import QuestionBankCore

enum StudyCatalogDestination: Hashable {
    case education
    case medicalComprehensive
    case politics
    case english
    case civilService
    case xingce
    case xingceCategory(XingceCategory)
    case civilServiceEssay
    case civilServiceInterview
}

struct StudyCatalogRootView: View {
    let open: (StudyCatalogDestination) -> Void
    private let hasCivilServiceBank = CivilServiceQuestionBankImporter.isBundledPackageAvailable()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("考试题本练习")
                        .font(.largeTitle.weight(.semibold))
                    Text("选择考试类型后，再进入对应科目和练习方式。")
                        .foregroundStyle(.secondary)
                }

                Text("选择考试类型")
                    .font(.title2.weight(.semibold))

                HStack(alignment: .top, spacing: 16) {
                    CatalogCard(
                        title: "升学考试",
                        detail: "包含医学综合、政治和英语，每个科目使用独立题本。",
                        status: "三科入口已建立",
                        icon: "graduationcap.fill",
                        isAvailable: true
                    ) {
                        open(.education)
                    }

                    CatalogCard(
                        title: "公务员考试",
                        detail: hasCivilServiceBank
                            ? "行测五大分类已接入独立题库；申论和面试暂时保留入口。"
                            : "行测五大分类接口已建立；开源安装包不内置题库数据。",
                        status: hasCivilServiceBank ? "行测已接入" : "需自行提供题库",
                        icon: "building.columns.fill",
                        isAvailable: true
                    ) {
                        open(.civilService)
                    }
                }
            }
            .padding(32)
            .frame(maxWidth: 1080, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("考试题本练习")
        .catalogSettingsToolbar()
    }
}

struct CivilServiceSelectionView: View {
    let open: (StudyCatalogDestination) -> Void
    private let hasBundledBank = CivilServiceQuestionBankImporter.isBundledPackageAvailable()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("公务员考试")
                        .font(.largeTitle.weight(.semibold))
                    Text("行测使用独立的人工录入题库，不读取截图题本。")
                        .foregroundStyle(.secondary)
                }

                HStack(alignment: .top, spacing: 16) {
                    CatalogCard(
                        title: "行测",
                        detail: hasBundledBank
                            ? "五大分类分别记录普通练习、错题和复习状态。"
                            : "五大分类数据库接口已建立；当前安装包未附带题库内容。",
                        status: hasBundledBank ? "可练习" : "题库未内置",
                        icon: "list.clipboard.fill",
                        isAvailable: hasBundledBank
                    ) { open(.xingce) }

                    CatalogCard(
                        title: "申论",
                        detail: "当前仅保留科目入口，题本和训练方式尚未接入。",
                        status: "入口预留",
                        icon: "square.and.pencil",
                        isAvailable: false
                    ) { open(.civilServiceEssay) }

                    CatalogCard(
                        title: "面试",
                        detail: "当前仅保留科目入口，题本和训练方式尚未接入。",
                        status: "入口预留",
                        icon: "person.2.wave.2.fill",
                        isAvailable: false
                    ) { open(.civilServiceInterview) }
                }
            }
            .padding(32)
            .frame(maxWidth: 1080, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("公务员考试")
        .catalogSettingsToolbar()
    }
}

struct XingceCategorySelectionView: View {
    let open: (StudyCatalogDestination) -> Void
    private let hasBundledBank = CivilServiceQuestionBankImporter.isBundledPackageAvailable()
    private let columns = [
        GridItem(.flexible(), spacing: 16),
        GridItem(.flexible(), spacing: 16),
        GridItem(.flexible(), spacing: 16)
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("行测")
                        .font(.largeTitle.weight(.semibold))
                    Text("选择分类后进入普通模式或错题模式；五类作答状态分别保存。")
                        .foregroundStyle(.secondary)
                }

                LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                    ForEach(XingceCategory.allCases, id: \.self) { category in
                        CatalogCard(
                            title: category.displayName,
                            detail: hasBundledBank
                                ? "人工录入题库，共 \(category.bundledQuestionCount.formatted()) 题。"
                                : "数据库与练习入口已建立，开源安装包不附带题目。",
                            status: hasBundledBank ? "普通 / 错题模式" : "等待导入",
                            icon: category.systemImage,
                            isAvailable: hasBundledBank
                        ) { open(.xingceCategory(category)) }
                    }
                }
            }
            .padding(32)
            .frame(maxWidth: 1080, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("行测")
        .catalogSettingsToolbar()
    }
}

private extension XingceCategory {
    var systemImage: String {
        switch self {
        case .politicsAndCommonSense: return "building.columns"
        case .verbalUnderstanding: return "text.quote"
        case .quantitativeRelations: return "function"
        case .judgmentReasoning: return "square.stack.3d.up"
        case .dataAnalysis: return "chart.bar.xaxis"
        }
    }
}

struct EducationSubjectSelectionView: View {
    let open: (StudyCatalogDestination) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("升学考试")
                        .font(.largeTitle.weight(.semibold))
                    Text("选择需要练习的科目。")
                        .foregroundStyle(.secondary)
                }

                Text("选择科目")
                    .font(.title2.weight(.semibold))

                HStack(alignment: .top, spacing: 16) {
                    CatalogCard(
                        title: "医学综合",
                        detail: "进入普通模式或错题模式，作答记录实时保存。",
                        status: "可练习",
                        icon: "cross.case.fill",
                        isAvailable: true
                    ) {
                        open(.medicalComprehensive)
                    }

                    CatalogCard(
                        title: "政治",
                        detail: "使用独立题本，提供普通模式和错题模式。",
                        status: "普通 / 错题模式",
                        icon: "text.book.closed.fill",
                        isAvailable: true
                    ) {
                        open(.politics)
                    }

                    CatalogCard(
                        title: "英语",
                        detail: "使用独立题本，提供普通模式和错题模式。",
                        status: "普通 / 错题模式",
                        icon: "character.book.closed.fill",
                        isAvailable: true
                    ) {
                        open(.english)
                    }
                }
            }
            .padding(32)
            .frame(maxWidth: 1080, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("升学考试")
        .catalogSettingsToolbar()
    }
}

struct PendingStudyEntryView: View {
    let title: String
    let detail: String
    let icon: String

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: icon)
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.largeTitle.weight(.semibold))
            Text("入口已预留")
                .font(.title3.weight(.medium))
            Text(detail)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
        .navigationTitle(title)
        .catalogSettingsToolbar()
    }
}

private struct CatalogCard: View {
    let title: String
    let detail: String
    let status: String
    let icon: String
    let isAvailable: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Image(systemName: icon)
                        .font(.system(size: 30))
                        .foregroundStyle(isAvailable ? Color.accentColor : Color.secondary)
                    Spacer()
                    Text(status)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(
                            (isAvailable ? Color.accentColor : Color.secondary).opacity(0.12),
                            in: Capsule()
                        )
                }

                Text(title)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 8)
                Label("进入", systemImage: "chevron.right")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(isAvailable ? Color.accentColor : Color.secondary)
            }
            .padding(20)
            .frame(maxWidth: .infinity, minHeight: 230, alignment: .topLeading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .stroke(
                        isHovering ? Color.accentColor.opacity(0.55) : Color(nsColor: .separatorColor).opacity(0.6),
                        lineWidth: isHovering ? 1.5 : 1
                    )
            }
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel("\(title)，\(status)")
        .accessibilityHint("打开\(title)入口")
    }
}

private extension View {
    func catalogSettingsToolbar() -> some View {
        toolbar {
            Button {
                SettingsOpener.open()
            } label: {
                Label("设置", systemImage: "gearshape")
            }
        }
    }
}
