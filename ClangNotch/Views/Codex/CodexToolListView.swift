import SwiftUI

/// View displaying Codex tool executions with detailed info
struct CodexToolListView: View {
    let tools: [CodexToolExecution]
    let maxItems: Int

    init(tools: [CodexToolExecution], maxItems: Int = 5) {
        self.tools = tools
        self.maxItems = maxItems
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if tools.isEmpty {
                Text("No recent tools")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
            } else {
                ForEach(Array(tools.prefix(maxItems))) { tool in
                    CodexToolRow(tool: tool)
                }
            }
        }
    }
}

struct CodexToolRow: View {
    let tool: CodexToolExecution

    private let codexColor = Color(red: 0.2, green: 0.45, blue: 0.9)

    /// Display text: prefer argument, then workdir
    private var displayTag: String? {
        if let arg = tool.argument, !arg.isEmpty {
            return arg
        }
        if let workdir = tool.workdir, !workdir.isEmpty {
            return URL(fileURLWithPath: workdir).lastPathComponent
        }
        return nil
    }

    var body: some View {
        HStack(spacing: 6) {
            // Activity indicator
            Circle()
                .fill(codexColor)
                .frame(width: 6, height: 6)
                .shadow(color: codexColor.opacity(tool.isRunning ? 0.6 : 0.3), radius: tool.isRunning ? 3 : 1)

            // Tool name
            Text(tool.toolName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.primary)
                .lineLimit(1)

            // Small tag for argument/workdir (inline, not expanding height)
            if let tag = displayTag {
                Text(tag)
                    .font(.system(size: 9))
                    .foregroundColor(.secondary.opacity(0.7))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 120, alignment: .leading)
            }

            Spacer()

            // Duration or spinner
            if tool.isRunning {
                ProgressView()
                    .scaleEffect(0.4)
                    .frame(width: 12, height: 12)
            } else {
                // Exit code badge
                if let exitCode = tool.exitCode {
                    Text("exit \(exitCode)")
                        .font(.system(size: 8, weight: .medium, design: .monospaced))
                        .foregroundColor(exitCode == 0 ? .green : .red)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background((exitCode == 0 ? Color.green : Color.red).opacity(0.15), in: Capsule())
                }

                Text(tool.formattedDuration)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.primary.opacity(0.04))
        )
    }
}

/// Singular detailed view for one Codex tool
struct SingularCodexToolDetailView: View {
    let tool: CodexToolExecution
    let tokenUsage: CodexTokenUsage

    private let codexColor = Color(red: 0.2, green: 0.45, blue: 0.9)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Tool name and status
            HStack(spacing: 8) {
                Circle()
                    .fill(codexColor)
                    .frame(width: 10, height: 10)
                    .shadow(color: codexColor.opacity(tool.isRunning ? 0.6 : 0.3), radius: tool.isRunning ? 4 : 2)

                Text(tool.toolName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.primary)

                Spacer()

                if tool.isRunning {
                    ProgressView()
                        .scaleEffect(0.5)
                        .frame(width: 16, height: 16)
                } else {
                    Text(tool.formattedDuration)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }

            // Argument
            if let arg = tool.argument, !arg.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "terminal")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                    Text(arg)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary.opacity(0.8))
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
            }

            // Exit code if completed
            if let exitCode = tool.exitCode {
                HStack(spacing: 4) {
                    Image(systemName: exitCode == 0 ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundColor(exitCode == 0 ? .green : .red)
                    Text("Exit code: \(exitCode)")
                        .font(.system(size: 10))
                        .foregroundColor(exitCode == 0 ? .green : .red)
                }
            }

            Divider()
                .background(Color.white.opacity(0.1))

            // Token details
            HStack(spacing: 12) {
                // Input tokens
                VStack(alignment: .leading, spacing: 2) {
                    Text("Input")
                        .font(.system(size: 8, weight: .medium))
                        .foregroundColor(.secondary)
                    HStack(spacing: 2) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundColor(.green.opacity(0.8))
                        Text(formatTokens(tokenUsage.inputTokens))
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundColor(.primary)
                    }
                }

                // Output tokens
                VStack(alignment: .leading, spacing: 2) {
                    Text("Output")
                        .font(.system(size: 8, weight: .medium))
                        .foregroundColor(.secondary)
                    HStack(spacing: 2) {
                        Image(systemName: "arrow.down")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundColor(.blue.opacity(0.8))
                        Text(formatTokens(tokenUsage.outputTokens))
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundColor(.primary)
                    }
                }

                // Cached tokens
                if tokenUsage.cachedInputTokens > 0 {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Cached")
                            .font(.system(size: 8, weight: .medium))
                            .foregroundColor(.secondary)
                        HStack(spacing: 2) {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundColor(.green.opacity(0.8))
                            Text(formatTokens(tokenUsage.cachedInputTokens))
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundColor(.green)
                        }
                    }
                }

                Spacer()

                // Total tokens
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Total")
                        .font(.system(size: 8, weight: .medium))
                        .foregroundColor(.secondary)
                    Text(formatTokens(tokenUsage.totalTokens))
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(.primary)
                }
            }
        }
    }

    private func formatTokens(_ count: Int) -> String {
        if count >= 1000 {
            return String(format: "%.1fk", Double(count) / 1000.0)
        }
        return "\(count)"
    }
}

#Preview {
    VStack {
        CodexToolListView(tools: [
            {
                var t = CodexToolExecution(id: "1", toolName: "shell", argument: "git status", startTime: Date().addingTimeInterval(-5))
                t.exitCode = 0
                t.endTime = Date()
                return t
            }(),
            {
                var t = CodexToolExecution(id: "2", toolName: "read_file", argument: "package.json", startTime: Date().addingTimeInterval(-2))
                t.endTime = Date()
                return t
            }(),
            CodexToolExecution(id: "3", toolName: "shell", argument: "npm install", startTime: Date())
        ])
    }
    .padding()
    .background(Color.black)
}
