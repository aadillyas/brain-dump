import SwiftUI

struct ProcessingView: View {
    let status: String

    var body: some View {
        VStack(spacing: 14) {
            ProgressView().controlSize(.small)
            Text(status)
                .font(.system(size: 17, design: .serif))
                .foregroundStyle(.secondary)
        }
    }
}

struct FailureView: View {
    @Environment(AppModel.self) private var model
    let message: String

    var body: some View {
        VStack(spacing: 18) {
            Text("Something went wrong")
                .font(.system(size: 20, design: .serif))
            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
                .textSelection(.enabled)
            HStack {
                Button("Retry", action: model.retry).keyboardShortcut(.defaultAction)
                if model.journalURL != nil {
                    Button("Skip to journal", action: model.skipToJournal)
                }
            }
            if model.journalURL == nil {
                Button("Back to canvas") { model.phase = .canvas }.buttonStyle(.link)
            }
        }
        .padding(40)
    }
}
