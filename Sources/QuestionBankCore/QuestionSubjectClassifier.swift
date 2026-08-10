import Foundation

public enum EnglishCurriculumTaxonomy {
    public static let sections = ["语音", "语法与词汇", "完形填空", "阅读理解", "对话", "写作"]

    public static func contains(section: String, chapter: String) -> Bool {
        section == "英语" && sections.contains(chapter)
    }

    public static var promptText: String {
        "英语：\(sections.joined(separator: "、"))"
    }
}

public enum PoliticalCurriculumTaxonomy {
    public static let sections: [MedicalCurriculumSection] = [
        MedicalCurriculumSection(
            name: "第一部分、马克思主义哲学原理",
            chapters: [
                "马克思主义哲学是科学的世界观和方法论",
                "世界多样性与物质统一性",
                "事物的联系、发展及其规律",
                "实践与认识及其发展规律",
                "历史观的基本问题和社会发展的基本规律",
                "社会历史发展的动力"
            ]
        ),
        MedicalCurriculumSection(
            name: "第二部分、毛泽东思想和中国特色社会主义理论体系概论",
            chapters: [
                "马克思主义中国化时代化的历史进程与理论成果",
                "毛泽东思想及其历史地位",
                "新民主主义革命理论",
                "社会主义改造理论",
                "社会主义建设道路初步探索的理论成果",
                "中国特色社会主义理论体系的形成发展",
                "邓小平理论",
                "“三个代表”重要思想",
                "科学发展观"
            ]
        ),
        MedicalCurriculumSection(
            name: "第三部分、新时代中国特色社会主义思想概论",
            chapters: [
                "新时代中国特色社会主义思想的创立",
                "新时代坚持和发展中国特色社会主义",
                "以中国式现代化全面推进中华民族伟大复兴",
                "坚持党的全面领导",
                "坚持以人民为中心",
                "全面深化改革开放",
                "推动高质量发展",
                "社会主义现代化建设的教育、科技、人才战略",
                "发展全过程人民民主",
                "全面依法治国",
                "建设社会主义文化强国",
                "以保障和改善民生为重点加强社会建设",
                "建设社会主义生态文明",
                "维护和塑造国家安全",
                "建设巩固国防和强大人民军队",
                "坚持“一国两制”和推进祖国完全统一",
                "中国特色大国外交和推动构建人类命运共同体",
                "全面从严治党"
            ]
        )
    ]

    public static func contains(section: String, chapter: String) -> Bool {
        sections.first(where: { $0.name == section })?.chapters.contains(chapter) == true
    }

    public static var promptText: String {
        sections.map { section in
            "\(section.name)：\(section.chapters.joined(separator: "、"))"
        }.joined(separator: "\n")
    }
}

public enum QuestionSubjectClassifier {
    /// This is only a local fallback and a hint for the single content request.
    /// The configured service remains authoritative for the fixed curriculum category.
    public static func classifyLocally(question: String, options: [String] = []) -> StudySubject? {
        let stem = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stem.isEmpty, !stem.hasPrefix("[OCR") else { return nil }

        if isPredominantlyEnglish(stem) {
            return .english
        }

        let normalized = (stem + " " + options.joined(separator: " ")).lowercased()
        if weightedScore(in: normalized, terms: englishSectionTerms) >= 4 {
            return .english
        }
        let politicsScore = weightedScore(in: normalized, terms: politicsTerms)
        let medicalScore = weightedScore(in: normalized, terms: medicalTerms)
        if politicsScore >= 4, politicsScore >= medicalScore + 2 { return .politics }
        if medicalScore >= 4, medicalScore >= politicsScore + 2 { return .medicalComprehensive }
        return nil
    }

    private static let politicsTerms: [(String, Int)] = [
        ("马克思", 5), ("恩格斯", 5), ("列宁", 5), ("毛泽东", 5), ("邓小平", 5),
        ("习近平", 5), ("中国共产党", 5), ("中国特色社会主义", 5), ("社会主义", 3),
        ("资本主义", 3), ("共产主义", 4), ("马克思主义哲学", 5), ("辩证唯物主义", 5),
        ("历史唯物主义", 5), ("唯物辩证法", 5), ("矛盾", 2), ("实践", 2), ("认识论", 4),
        ("生产力", 3), ("生产关系", 3), ("经济基础", 3), ("上层建筑", 3), ("社会存在", 3),
        ("社会意识", 3), ("历史人物", 4), ("社会历史", 3), ("客观规律", 3),
        ("人民代表大会", 4), ("民主集中制", 4), ("依法治国", 4),
        ("改革开放", 4), ("新民主主义", 5), ("新时代", 2), ("共同富裕", 3),
        ("宪法", 3), ("法治", 3), ("国家性质", 3), ("基本路线", 3), ("思想政治", 4)
    ]

    private static let medicalTerms: [(String, Int)] = [
        ("患者", 3), ("病人", 3), ("男性", 1), ("女性", 1), ("岁", 1), ("诊断", 3),
        ("症状", 2), ("体征", 3), ("检查", 1), ("治疗", 2), ("病史", 3), ("手术", 3),
        ("解剖", 4), ("生理", 4), ("病理", 4), ("内科", 4), ("外科", 4), ("临床", 3),
        ("细胞", 2), ("组织", 1), ("器官", 2), ("神经", 2), ("激素", 3), ("血压", 3),
        ("血液", 2), ("心脏", 3), ("心肌", 3), ("肺", 2), ("肝", 2), ("肾", 2),
        ("胆囊", 3), ("胰腺", 3), ("感染", 2), ("炎症", 3), ("肿瘤", 3), ("骨折", 3),
        ("动脉", 3), ("静脉", 3), ("呼吸", 2), ("消化", 2), ("尿", 2), ("血清", 3)
    ]

    private static let englishSectionTerms: [(String, Int)] = [
        ("英语", 5), ("语音", 4), ("语法与词汇", 5), ("完形填空", 5),
        ("阅读理解", 5), ("情景对话", 5), ("补全对话", 5), ("书面表达", 4),
        ("下列单词", 4), ("划线部分", 2), ("发音", 2)
    ]

    private static func weightedScore(in text: String, terms: [(String, Int)]) -> Int {
        terms.reduce(into: 0) { score, term in
            if text.contains(term.0) { score += term.1 }
        }
    }

    private static func isPredominantlyEnglish(_ text: String) -> Bool {
        var latinLetters = 0
        var chineseCharacters = 0
        for scalar in text.unicodeScalars {
            if (65...90).contains(scalar.value) || (97...122).contains(scalar.value) {
                latinLetters += 1
            } else if (0x4E00...0x9FFF).contains(scalar.value) {
                chineseCharacters += 1
            }
        }
        let englishWords = text.split { !$0.isLetter }.filter { token in
            token.unicodeScalars.allSatisfy {
                (65...90).contains($0.value) || (97...122).contains($0.value)
            }
        }
        return latinLetters >= 12 && englishWords.count >= 4 && latinLetters >= max(1, chineseCharacters * 2)
    }
}
