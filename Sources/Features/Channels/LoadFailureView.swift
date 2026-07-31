import SwiftUI

/// Inline load-failure state with a retry action. The message arrives already
/// typed and redacted by the view model — never a raw error description.
struct LoadFailureView: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Retry", action: retry)
        }
        .padding()
    }
}

#Preview("Load failure") {
    LoadFailureView(message: "The panel did not answer. Check your connection and try again.", retry: {})
}
