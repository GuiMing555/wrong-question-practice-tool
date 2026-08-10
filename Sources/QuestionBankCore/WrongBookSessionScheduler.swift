import Foundation

public enum WrongBookSessionPolicy {
    public static let repetitionsPerQuestion = 3

    public static func expandedQuestionCount(uniqueQuestionCount: Int) -> Int {
        max(0, uniqueQuestionCount) * repetitionsPerQuestion
    }

    public static func targetMinimumPositionDistance(uniqueQuestionCount: Int) -> Int {
        guard uniqueQuestionCount > 1 else { return 1 }
        let divisor = max(1, repetitionsPerQuestion - 1)
        return max(2, (uniqueQuestionCount + divisor - 1) / divisor)
    }
}

enum WrongBookSessionScheduler {
    static func arrange(questionIDs: [String], seed: UInt64) -> [String] {
        var seen = Set<String>()
        var uniqueIDs = questionIDs.filter { seen.insert($0).inserted }
        guard !uniqueIDs.isEmpty else { return [] }
        guard uniqueIDs.count > 1 else {
            return Array(repeating: uniqueIDs[0], count: WrongBookSessionPolicy.repetitionsPerQuestion)
        }

        var generator = WrongBookSeededRandomNumberGenerator(seed: seed)
        uniqueIDs.shuffle(using: &generator)

        var arranged = Array(
            repeating: uniqueIDs,
            count: WrongBookSessionPolicy.repetitionsPerQuestion
        ).flatMap { $0 }
        var positions = positionsByQuestion(in: arranged)
        let minimumDistance = WrongBookSessionPolicy.targetMinimumPositionDistance(
            uniqueQuestionCount: uniqueIDs.count
        )

        // 从稳定、无冲突的基线开始做大量带约束随机交换。结果可由 seed 复现，
        // 但不会形成固定轮次或固定间隔；同题间距始终不低于动态安全距离。
        let mixingAttempts = max(400, arranged.count * 120)
        for _ in 0..<mixingAttempts {
            let first = Int.random(in: arranged.indices, using: &generator)
            let second = Int.random(in: arranged.indices, using: &generator)
            guard first != second else { continue }
            _ = swapIfValid(
                first,
                second,
                in: &arranged,
                positions: &positions,
                minimumDistance: minimumDistance
            )
        }

        if !hasVariableIntervals(arranged), uniqueIDs.count >= 3 {
            forceOneVariableInterval(
                in: &arranged,
                positions: &positions,
                minimumDistance: minimumDistance
            )
        }
        return arranged
    }

    private static func positionsByQuestion(in arranged: [String]) -> [String: [Int]] {
        Dictionary(grouping: arranged.indices, by: { arranged[$0] })
            .mapValues { $0.sorted() }
    }

    @discardableResult
    private static func swapIfValid(
        _ first: Int,
        _ second: Int,
        in arranged: inout [String],
        positions: inout [String: [Int]],
        minimumDistance: Int
    ) -> Bool {
        let firstID = arranged[first]
        let secondID = arranged[second]
        guard firstID != secondID,
              let firstPositions = positions[firstID],
              let secondPositions = positions[secondID]
        else { return false }

        let movedFirst = replacing(first, with: second, in: firstPositions)
        let movedSecond = replacing(second, with: first, in: secondPositions)
        guard respectsMinimumDistance(movedFirst, minimumDistance: minimumDistance),
              respectsMinimumDistance(movedSecond, minimumDistance: minimumDistance)
        else { return false }

        arranged.swapAt(first, second)
        positions[firstID] = movedFirst
        positions[secondID] = movedSecond
        return true
    }

    private static func replacing(_ oldPosition: Int, with newPosition: Int, in positions: [Int]) -> [Int] {
        var result = positions
        guard let index = result.firstIndex(of: oldPosition) else { return positions }
        result[index] = newPosition
        return result.sorted()
    }

    private static func respectsMinimumDistance(_ positions: [Int], minimumDistance: Int) -> Bool {
        zip(positions, positions.dropFirst()).allSatisfy { current, next in
            next - current >= minimumDistance
        }
    }

    private static func hasVariableIntervals(_ arranged: [String]) -> Bool {
        let gaps = positionsByQuestion(in: arranged).values.flatMap { positions in
            zip(positions, positions.dropFirst()).map { current, next in next - current }
        }
        return Set(gaps).count > 1
    }

    private static func forceOneVariableInterval(
        in arranged: inout [String],
        positions: inout [String: [Int]],
        minimumDistance: Int
    ) {
        guard arranged.count >= 2 else { return }
        for first in arranged.indices {
            for second in arranged.indices where second > first {
                var candidate = arranged
                var candidatePositions = positions
                guard swapIfValid(
                    first,
                    second,
                    in: &candidate,
                    positions: &candidatePositions,
                    minimumDistance: minimumDistance
                ), hasVariableIntervals(candidate)
                else { continue }
                arranged = candidate
                positions = candidatePositions
                return
            }
        }
    }
}

private struct WrongBookSeededRandomNumberGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58476D1CE4E5B9
        value = (value ^ (value >> 27)) &* 0x94D049BB133111EB
        return value ^ (value >> 31)
    }
}
