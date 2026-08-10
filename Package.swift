// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "WrongQuestionDailyOrganizer",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "WrongQuestionDailyOrganizer", targets: ["WrongQuestionDailyOrganizer"]),
        .executable(name: "MedicalQuestionPractice", targets: ["MedicalQuestionPractice"]),
        .library(name: "QuestionBankCore", targets: ["QuestionBankCore"])
    ],
    targets: [
        .systemLibrary(
            name: "CSQLite",
            path: "Sources/CSQLite",
            pkgConfig: "sqlite3",
            providers: [
                .brew(["sqlite3"]),
                .apt(["libsqlite3-dev"])
            ]
        ),
        .target(
            name: "QuestionBankCore",
            dependencies: ["CSQLite"],
            path: "Sources/QuestionBankCore",
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        .executableTarget(
            name: "WrongQuestionDailyOrganizer",
            dependencies: ["QuestionBankCore"],
            path: "Sources/WrongQuestionCapture",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("Vision"),
                .linkedFramework("ImageIO"),
                .linkedFramework("WebKit")
            ]
        ),
        .executableTarget(
            name: "MedicalQuestionPractice",
            dependencies: ["QuestionBankCore"],
            path: "Sources/MedicalQuestionPractice",
            linkerSettings: [
                .linkedFramework("AppKit")
            ]
        ),
        .testTarget(
            name: "QuestionBankCoreTests",
            dependencies: ["QuestionBankCore"],
            path: "Tests/QuestionBankCoreTests"
        )
    ],
    swiftLanguageVersions: [.v5]
)
