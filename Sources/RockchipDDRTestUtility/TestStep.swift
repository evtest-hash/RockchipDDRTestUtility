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

extension TestStep {
    /// The firmware's own item names appear in the log and in saved files, so they
    /// stay — but on screen they say nothing to whoever is reading. Gloss the ones
    /// that have a meaning; leave anything already Chinese alone.
    var gloss: String? {
        switch name.lowercased() {
        case "boot": return "引导下载"
        case "forceinit": return "强制初始化"
        case "connect": return "焊接连接检查"
        default: return nil
        }
    }
}
