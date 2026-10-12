//
//  PermissionNeededIndicator.swift
//  ClangNotch
//
//  Pulsing indicator shown when Claude is waiting for user permission
//

import SwiftUI

/// Compact pulsing dot for minimal views
struct PermissionNeededIndicatorCompact: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isPulsing = false

    var body: some View {
        Circle()
            .fill(Color.orange)
            .frame(width: 8, height: 8)
            .scaleEffect(isPulsing ? 1.2 : 0.9)
            .opacity(isPulsing ? 1.0 : 0.6)
            .onAppear {
                // Reduce Motion: hold the bright frame instead of pulsing.
                guard !reduceMotion else { isPulsing = true; return }
                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                    isPulsing = true
                }
            }
    }
}

/// Inline permission indicator with tool name
struct PermissionNeededBadge: View {
    let toolName: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isPulsing = false

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(Color.orange)
                .frame(width: 6, height: 6)
                .scaleEffect(isPulsing ? 1.2 : 0.9)
                .opacity(isPulsing ? 1.0 : 0.6)

            if let tool = toolName {
                Text(tool)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.orange)
            }

            Text("권한 승인 대기")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.orange.opacity(0.8))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.orange.opacity(0.15))
        .cornerRadius(6)
        .onAppear {
            guard !reduceMotion else { isPulsing = true; return }
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                isPulsing = true
            }
        }
    }
}

#Preview {
    VStack(spacing: 20) {
        PermissionNeededIndicatorCompact()
        PermissionNeededBadge(toolName: "Bash")
    }
    .padding()
    .background(Color.black.opacity(0.8))
}
