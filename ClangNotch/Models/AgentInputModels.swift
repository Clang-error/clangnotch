import Foundation

struct AgentInputOption: Equatable {
    let label: String
    let description: String
}

struct AgentInputQuestion: Equatable {
    let header: String
    let question: String
    let options: [AgentInputOption]
    var multiSelect = false
}

