import Foundation

public enum QuestionWorkbookWriter {
    public static func write(rows: [QuestionWorkbookRow], to outputURL: URL) throws {
        let fileManager = FileManager.default
        let subject = StudySubject.allCases.first {
            outputURL.lastPathComponent == $0.workbookFilename
        } ?? .medicalComprehensive
        try fileManager.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let root = fileManager.temporaryDirectory.appendingPathComponent("question-workbook-\(UUID().uuidString)", isDirectory: true)
        let archive = fileManager.temporaryDirectory.appendingPathComponent("question-workbook-\(UUID().uuidString).xlsx")
        defer {
            try? fileManager.removeItem(at: root)
            try? fileManager.removeItem(at: archive)
        }

        try writePackage(rows: rows, subject: subject, root: root)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.arguments = ["-q", "-r", archive.path, "."]
        process.currentDirectoryURL = root
        let errorPipe = Pipe()
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw QuestionBankError.database("生成题本工作簿失败：\(message)")
        }
        try Data(contentsOf: archive).write(to: outputURL, options: .atomic)
    }

    private static func writePackage(
        rows: [QuestionWorkbookRow],
        subject: StudySubject,
        root: URL
    ) throws {
        let fileManager = FileManager.default
        let directories = [
            root.appendingPathComponent("_rels", isDirectory: true),
            root.appendingPathComponent("docProps", isDirectory: true),
            root.appendingPathComponent("xl/_rels", isDirectory: true),
            root.appendingPathComponent("xl/worksheets", isDirectory: true)
        ]
        for directory in directories {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        try write(contentTypes, to: root.appendingPathComponent("[Content_Types].xml"))
        try write(rootRelations, to: root.appendingPathComponent("_rels/.rels"))
        try write(appProperties, to: root.appendingPathComponent("docProps/app.xml"))
        try write(coreProperties(subject: subject), to: root.appendingPathComponent("docProps/core.xml"))
        try write(workbook, to: root.appendingPathComponent("xl/workbook.xml"))
        try write(workbookRelations, to: root.appendingPathComponent("xl/_rels/workbook.xml.rels"))
        try write(styles, to: root.appendingPathComponent("xl/styles.xml"))
        try write(questionSheet(rows), to: root.appendingPathComponent("xl/worksheets/sheet1.xml"))
        try write(categorySheet(subject: subject), to: root.appendingPathComponent("xl/worksheets/sheet2.xml"))
    }

    private static func write(_ value: String, to url: URL) throws {
        guard let data = value.data(using: .utf8) else {
            throw QuestionBankError.database("生成题本工作簿时无法编码 XML")
        }
        try data.write(to: url, options: .atomic)
    }

    private static func questionSheet(_ rows: [QuestionWorkbookRow]) -> String {
        let headers = [
            "序号", "一级分类", "二级分类", "题型", "题干",
            "选项A", "选项B", "选项C", "选项D", "选项E", "选项F",
            "正确答案", "解析", "知识点标题", "背诵内容", "易错辨析", "当前错题本", "累计答错次数",
            "累计作答次数", "连续答对次数", "最近作答时间", "来源图片", "更新时间"
        ]
        var rowXML = row(cells: headers.enumerated().map { textCell(column: $0.offset, row: 1, value: $0.element, style: 1) }, index: 1, height: 28)
        for (offset, item) in rows.enumerated() {
            let rowIndex = offset + 2
            let values = [
                String(offset + 1),
                item.curriculumSection,
                item.curriculumChapter,
                item.questionType,
                item.stem,
                option(item.options, at: 0),
                option(item.options, at: 1),
                option(item.options, at: 2),
                option(item.options, at: 3),
                option(item.options, at: 4),
                option(item.options, at: 5),
                item.correctAnswer,
                item.explanation,
                item.knowledgePoints.joined(separator: "；"),
                item.memoryTexts.joined(separator: "\n"),
                item.pitfalls.joined(separator: "\n"),
                item.isInWrongBook ? "是" : "否"
            ]
            var cells = values.enumerated().map { index, value in
                textCell(column: index, row: rowIndex, value: value, style: (index == 1 || index == 2) ? 2 : 0)
            }
            cells.append(numberCell(column: 17, row: rowIndex, value: item.wrongAttempts))
            cells.append(numberCell(column: 18, row: rowIndex, value: item.totalAttempts))
            cells.append(numberCell(column: 19, row: rowIndex, value: item.consecutiveCorrect))
            cells.append(textCell(column: 20, row: rowIndex, value: format(item.lastAnsweredAt), style: 0))
            cells.append(textCell(column: 21, row: rowIndex, value: item.sourceImagePath, style: 0))
            cells.append(textCell(column: 22, row: rowIndex, value: format(item.updatedAt), style: 0))
            rowXML += row(cells: cells, index: rowIndex)
        }
        let lastRow = max(rows.count + 1, 2)
        return xmlHeader + """
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
          <sheetPr><pageSetUpPr fitToPage="1"/></sheetPr>
          <dimension ref="A1:W\(lastRow)"/>
          <sheetViews><sheetView showGridLines="0" workbookViewId="0"><pane ySplit="1" topLeftCell="A2" activePane="bottomLeft" state="frozen"/><selection pane="bottomLeft" activeCell="A2" sqref="A2"/></sheetView></sheetViews>
          <sheetFormatPr defaultRowHeight="18"/>
          <cols>
            <col min="1" max="1" width="8" customWidth="1"/><col min="2" max="3" width="27" customWidth="1"/>
            <col min="4" max="4" width="10" customWidth="1"/><col min="5" max="5" width="52" customWidth="1"/>
            <col min="6" max="11" width="28" customWidth="1"/><col min="12" max="12" width="11" customWidth="1"/>
            <col min="13" max="13" width="52" customWidth="1"/><col min="14" max="14" width="28" customWidth="1"/>
            <col min="15" max="16" width="44" customWidth="1"/><col min="17" max="20" width="13" customWidth="1"/>
            <col min="21" max="21" width="20" customWidth="1"/><col min="22" max="22" width="42" customWidth="1"/>
            <col min="23" max="23" width="20" customWidth="1"/>
          </cols>
          <sheetData>\(rowXML)</sheetData>
          <autoFilter ref="A1:W\(lastRow)"/>
          <dataValidations count="3">
            <dataValidation type="list" allowBlank="1" showErrorMessage="1" sqref="B2:B1048576"><formula1>&apos;分类字典&apos;!$D$2:$D$5</formula1></dataValidation>
            <dataValidation type="list" allowBlank="1" showErrorMessage="1" sqref="C2:C1048576"><formula1>&apos;分类字典&apos;!$B$2:$B$40</formula1></dataValidation>
            <dataValidation type="list" allowBlank="0" showErrorMessage="1" sqref="D2:D1048576"><formula1>&quot;单选题,多选题,判断题,论述题&quot;</formula1></dataValidation>
          </dataValidations>
          <pageMargins left="0.25" right="0.25" top="0.5" bottom="0.5" header="0.2" footer="0.2"/>
          <pageSetup orientation="landscape" fitToWidth="1" fitToHeight="0" paperSize="9"/>
        </worksheet>
        """
    }

    private static func categorySheet(subject: StudySubject) -> String {
        var values: [[String]] = [["一级分类", "二级分类", "", "一级分类下拉"]]
        let sections: [MedicalCurriculumSection]
        switch subject {
        case .medicalComprehensive:
            sections = MedicalCurriculumTaxonomy.sections
        case .politics:
            sections = PoliticalCurriculumTaxonomy.sections
        case .english:
            sections = [MedicalCurriculumSection(name: "英语", chapters: EnglishCurriculumTaxonomy.sections)]
        }
        for section in sections {
            for chapter in section.chapters { values.append([section.name, chapter, "", ""]) }
        }
        for (index, section) in sections.enumerated() {
            let target = index + 1
            if values.indices.contains(target) { values[target][3] = section.name }
        }
        var rows = ""
        for (index, values) in values.enumerated() {
            let rowIndex = index + 1
            rows += row(cells: values.enumerated().map {
                textCell(column: $0.offset, row: rowIndex, value: $0.element, style: rowIndex == 1 ? 1 : 0)
            }, index: rowIndex, height: rowIndex == 1 ? 26 : nil)
        }
        return xmlHeader + """
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
          <dimension ref="A1:D\(values.count)"/>
          <sheetViews><sheetView showGridLines="0" workbookViewId="0"><pane ySplit="1" topLeftCell="A2" activePane="bottomLeft" state="frozen"/></sheetView></sheetViews>
          <cols><col min="1" max="1" width="31" customWidth="1"/><col min="2" max="2" width="31" customWidth="1"/><col min="3" max="3" width="3" customWidth="1"/><col min="4" max="4" width="31" customWidth="1"/></cols>
          <sheetData>\(rows)</sheetData>
          <autoFilter ref="A1:B\(values.count)"/>
        </worksheet>
        """
    }

    private static func row(cells: [String], index: Int, height: Int? = nil) -> String {
        let heightAttribute = height.map { " ht=\"\($0)\" customHeight=\"1\"" } ?? ""
        return "<row r=\"\(index)\"\(heightAttribute)>\(cells.joined())</row>"
    }

    private static func textCell(column: Int, row: Int, value: String, style: Int) -> String {
        let reference = "\(columnName(column))\(row)"
        return "<c r=\"\(reference)\" s=\"\(style)\" t=\"inlineStr\"><is><t xml:space=\"preserve\">\(escape(value))</t></is></c>"
    }

    private static func numberCell(column: Int, row: Int, value: Int) -> String {
        "<c r=\"\(columnName(column))\(row)\" s=\"3\" t=\"n\"><v>\(value)</v></c>"
    }

    private static func option(_ values: [String], at index: Int) -> String {
        values.indices.contains(index) ? values[index] : ""
    }

    private static func columnName(_ zeroBasedIndex: Int) -> String {
        var value = zeroBasedIndex + 1
        var output = ""
        while value > 0 {
            value -= 1
            output = String(UnicodeScalar(65 + value % 26)!) + output
            value /= 26
        }
        return output
    }

    private static func format(_ date: Date?) -> String {
        guard let date else { return "" }
        return dateFormatter.string(from: date)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    private static func escape(_ value: String) -> String {
        let valid = value.unicodeScalars.filter { scalar in
            scalar.value == 9 || scalar.value == 10 || scalar.value == 13 || scalar.value >= 32
        }
        return String(String.UnicodeScalarView(valid))
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static let xmlHeader = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
    private static let contentTypes = xmlHeader + """
    <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
      <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
      <Default Extension="xml" ContentType="application/xml"/>
      <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
      <Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
      <Override PartName="/xl/worksheets/sheet2.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
      <Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>
      <Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>
      <Override PartName="/docProps/app.xml" ContentType="application/vnd.openxmlformats-officedocument.extended-properties+xml"/>
    </Types>
    """
    private static let rootRelations = xmlHeader + """
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
      <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
      <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>
      <Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties" Target="docProps/app.xml"/>
    </Relationships>
    """
    private static let workbook = xmlHeader + """
    <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
      <bookViews><workbookView xWindow="0" yWindow="0" windowWidth="22000" windowHeight="12000"/></bookViews>
      <sheets><sheet name="题本" sheetId="1" r:id="rId1"/><sheet name="分类字典" sheetId="2" r:id="rId2"/></sheets>
      <calcPr calcId="191029" fullCalcOnLoad="1"/>
    </workbook>
    """
    private static let workbookRelations = xmlHeader + """
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
      <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>
      <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet2.xml"/>
      <Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
    </Relationships>
    """
    private static let styles = xmlHeader + """
    <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
      <fonts count="2"><font><sz val="11"/><name val="PingFang SC"/><family val="2"/></font><font><b/><color rgb="FFFFFFFF"/><sz val="11"/><name val="PingFang SC"/><family val="2"/></font></fonts>
      <fills count="4"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill><fill><patternFill patternType="solid"><fgColor rgb="FF1F4E78"/><bgColor indexed="64"/></patternFill></fill><fill><patternFill patternType="solid"><fgColor rgb="FFFFF2CC"/><bgColor indexed="64"/></patternFill></fill></fills>
      <borders count="2"><border><left/><right/><top/><bottom/><diagonal/></border><border><left/><right/><top/><bottom style="thin"><color rgb="FFD9E2F3"/></bottom><diagonal/></border></borders>
      <cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>
      <cellXfs count="4"><xf numFmtId="0" fontId="0" fillId="0" borderId="1" xfId="0" applyAlignment="1"><alignment vertical="top" wrapText="1"/></xf><xf numFmtId="0" fontId="1" fillId="2" borderId="0" xfId="0" applyAlignment="1"><alignment horizontal="center" vertical="center" wrapText="1"/></xf><xf numFmtId="0" fontId="0" fillId="3" borderId="1" xfId="0" applyAlignment="1"><alignment vertical="top" wrapText="1"/></xf><xf numFmtId="1" fontId="0" fillId="0" borderId="1" xfId="0" applyAlignment="1"><alignment horizontal="center" vertical="top"/></xf></cellXfs>
      <cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles>
    </styleSheet>
    """
    private static let appProperties = xmlHeader + """
    <Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties" xmlns:vt="http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes"><Application>考试题本整理</Application></Properties>
    """
    private static func coreProperties(subject: StudySubject) -> String {
        xmlHeader + """
        <cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"><dc:title>\(subject.displayName)题本</dc:title><dc:creator>考试题本整理</dc:creator></cp:coreProperties>
        """
    }
}
