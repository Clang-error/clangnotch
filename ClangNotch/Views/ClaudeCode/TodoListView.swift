//
//  TodoListView.swift
//  ClangNotch
//
//  Displays Claude Code's current todo list parsed from TodoWrite tool calls
//

import SwiftUI

struct TodoListView: View {
    let todos: [ClaudeTodoItem]
    var maxItems: Int = 5

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(todos.prefix(maxItems))) { todo in
                TodoItemRow(todo: todo)
            }

            if todos.count > maxItems {
                Text("+\(todos.count - maxItems)개 더")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.5))
                    .padding(.leading, 16)
            }
        }
    }
}

struct TodoItemRow: View {
    let todo: ClaudeTodoItem

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: iconName)
                .font(.system(size: 9))
                .foregroundColor(iconColor)
                .frame(width: 12)

            Text(todo.content)
                .font(.system(size: 10, weight: fontWeight))
                .foregroundColor(textColor)
                .lineLimit(1)
                .strikethrough(todo.status == .completed)

            Spacer()
        }
    }

    private var iconName: String {
        switch todo.status {
        case .pending:
            return "circle"
        case .inProgress:
            return "circle.lefthalf.filled"
        case .completed:
            return "checkmark.circle.fill"
        }
    }

    private var iconColor: Color {
        switch todo.status {
        case .pending:
            return .white.opacity(0.4)
        case .inProgress:
            return .orange
        case .completed:
            return .green
        }
    }

    private var textColor: Color {
        switch todo.status {
        case .pending:
            return .white.opacity(0.6)
        case .inProgress:
            return .white.opacity(0.9)
        case .completed:
            return .white.opacity(0.5)
        }
    }

    private var fontWeight: Font.Weight {
        todo.status == .inProgress ? .medium : .regular
    }
}

#Preview {
    let sampleTodos = [
        ClaudeTodoItem(content: "Fix authentication bug", status: .completed),
        ClaudeTodoItem(content: "Implement JSONL parser", status: .inProgress),
        ClaudeTodoItem(content: "Add permission detection", status: .pending),
        ClaudeTodoItem(content: "Create UI components", status: .pending),
        ClaudeTodoItem(content: "Test multi-session support", status: .pending),
        ClaudeTodoItem(content: "Update documentation", status: .pending)
    ]

    VStack(spacing: 20) {
        TodoListView(todos: sampleTodos)
            .padding()
            .background(Color.black.opacity(0.8))
            .cornerRadius(8)
    }
    .padding()
}
