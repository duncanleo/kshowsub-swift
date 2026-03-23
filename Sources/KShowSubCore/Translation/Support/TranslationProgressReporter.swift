import Foundation

actor TranslationProgressReporter {
    private let label: String
    private let total: Int
    private let unitLabel: String
    private let inFlightLabel: String
    private var completed = 0
    private var inFlight = 0

    init(
        label: String,
        total: Int,
        unitLabel: String = "requests",
        inFlightLabel: String = "requests in flight"
    ) {
        self.label = label
        self.total = total
        self.unitLabel = unitLabel
        self.inFlightLabel = inFlightLabel
    }

    func start() {
        render()
    }

    func markCompleted() {
        markCompleted(count: 1)
    }

    func markCompleted(count: Int) {
        completed = min(total, completed + count)
        if inFlight > 0 {
            inFlight -= 1
        }
        render()
    }

    func markStarted(inFlightCount: Int = 1) {
        inFlight += inFlightCount
        render()
    }

    func finish() {
        completed = total
        inFlight = 0
        render(ending: true)
    }

    private func render(ending: Bool = false) {
        let suffix =
            inFlight > 0
            ? " | \(inFlight) \(inFlightLabel)"
            : ""
        if ending {
            fputs("\r\(label): translating \(completed)/\(total) \(unitLabel)...\(suffix)\n", stderr)
        } else {
            fputs("\r\(label): translating \(completed)/\(total) \(unitLabel)...\(suffix)", stderr)
        }
    }
}
