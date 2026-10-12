import SwiftUI

struct TelemetryStatusIndicatorView: View {
    let state: TelemetryState

    var body: some View {
        Circle()
            .fill(statusColor)
            .frame(width: 8, height: 8)
            .shadow(color: statusColor.opacity(state.isActive ? 0.6 : 0.3), radius: state.isActive ? 4 : 2)
    }

    private var statusColor: Color {
        switch state {
        case .stopped:
            return .gray
        case .starting:
            return .yellow
        case .running:
            return .green
        case .error:
            return .red
        }
    }
}

#Preview {
    VStack(spacing: 20) {
        TelemetryStatusIndicatorView(state: .stopped)
        TelemetryStatusIndicatorView(state: .starting)
        TelemetryStatusIndicatorView(state: .running)
        TelemetryStatusIndicatorView(state: .error("Test"))
    }
    .padding()
}
