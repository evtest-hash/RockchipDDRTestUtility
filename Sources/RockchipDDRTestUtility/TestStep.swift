import DDRCore

// The step cards the log pane renders. These are presentation state — they lived
// in DDRCore, but neither the core nor the CLI ever referenced them; only this
// target does. `TestStep` isn't even Sendable, which is the giveaway.

enum StepState: Sendable {
    case pending
    case downloading
    case running
    case passed
    case failed
}

struct TestStep: Identifiable {
    let id: String
    let name: String
    var state: StepState
    var messages: [String]

    init(name: String, state: StepState = .pending) {
        self.id = name
        self.name = name
        self.state = state
        self.messages = []
    }
}
