import SwiftUI

/// Current Tasks 카드: the selected Claude session's task list, in the order Claude made it.
/// Done tasks stay, struck through, so the list reads as progress.
struct TodoListView: View {
    let todos: [ClaudeTodoItem]
    var maxItems = 5

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(todos.prefix(maxItems)) { TodoRow(todo: $0) }
            if todos.count > maxItems {
                Text(L("+\(todos.count - maxItems)개 더", "+\(todos.count - maxItems) more"))
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.5))
                    .padding(.leading, 18)
            }
        }
    }
}

private struct TodoRow: View {
    let todo: ClaudeTodoItem

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 9))
                .foregroundStyle(tint)
                .frame(width: 12)
            Text(todo.content)
                .font(.system(size: 10, weight: todo.status == .inProgress ? .medium : .regular))
                .foregroundStyle(.white.opacity(todo.status == .inProgress ? 0.9 : todo.status == .pending ? 0.6 : 0.45))
                .strikethrough(todo.status == .completed)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
    }

    private var symbol: String {
        switch todo.status {
        case .pending: "circle"
        case .inProgress: "circle.lefthalf.filled"
        case .completed: "checkmark.circle.fill"
        }
    }

    private var tint: Color {
        switch todo.status {
        case .pending: .white.opacity(0.4)
        case .inProgress: .orange
        case .completed: .green
        }
    }
}
