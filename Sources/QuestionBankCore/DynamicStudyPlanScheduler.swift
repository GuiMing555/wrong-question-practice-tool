import Foundation

enum DynamicStudyPlanScheduler {
    static func dailyTarget(workload: Int, daysRemaining: Int) -> Int {
        guard workload > 0 else { return 0 }
        let days = max(1, daysRemaining)
        return (workload + days - 1) / days
    }

    static func arrange(
        newQuestionIDs: [String],
        wrongQuestionRemaining: [String: Int],
        wrongOccurrenceLimit: Int,
        seed: UInt64
    ) -> [String] {
        var generator = DynamicPlanRandomNumberGenerator(seed: seed)
        var newQuestions = Array(Set(newQuestionIDs)).sorted()
        newQuestions.shuffle(using: &generator)

        var remaining = wrongQuestionRemaining
            .filter { $0.value > 0 }
        var wrongOccurrences: [String] = []
        let occurrenceLimit = max(0, wrongOccurrenceLimit)
        while wrongOccurrences.count < occurrenceLimit, !remaining.isEmpty {
            var round = remaining.keys.sorted()
            round.shuffle(using: &generator)
            for questionID in round where wrongOccurrences.count < occurrenceLimit {
                guard let count = remaining[questionID], count > 0 else { continue }
                wrongOccurrences.append(questionID)
                if count == 1 {
                    remaining.removeValue(forKey: questionID)
                } else {
                    remaining[questionID] = count - 1
                }
            }
        }

        var arranged: [String] = []
        arranged.reserveCapacity(newQuestions.count + wrongOccurrences.count)
        while !newQuestions.isEmpty || !wrongOccurrences.isEmpty {
            let total = newQuestions.count + wrongOccurrences.count
            let preferNew = !newQuestions.isEmpty && (
                wrongOccurrences.isEmpty
                    || Int.random(in: 0..<total, using: &generator) < newQuestions.count
            )
            if preferNew {
                arranged.append(newQuestions.removeFirst())
            } else {
                let last = arranged.last
                if let index = wrongOccurrences.firstIndex(where: { $0 != last }) {
                    arranged.append(wrongOccurrences.remove(at: index))
                } else if !wrongOccurrences.isEmpty {
                    arranged.append(wrongOccurrences.removeFirst())
                } else {
                    arranged.append(newQuestions.removeFirst())
                }
            }
        }
        return arranged
    }
}

private struct DynamicPlanRandomNumberGenerator: RandomNumberGenerator {
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
