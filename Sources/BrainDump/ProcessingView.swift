import SwiftUI

struct ProcessingView: View {
    let status: String

    var body: some View {
        VStack(spacing: 14) {
            ProgressView().controlSize(.small)
            Text(status)
                .font(.system(size: 17, design: .serif))
                .foregroundStyle(.secondary)
            RotatingQuote().padding(.top, 26)
        }
        .padding(40)
    }
}

/// A journaling quote or tip that crossfades to another every 9 seconds. Shown while the model reads.
struct RotatingQuote: View {
    @State private var quoteIndex = Int.random(in: 0..<Quotes.all.count)

    var body: some View {
        ZStack(alignment: .top) {
            quoteView(Quotes.all[quoteIndex])
                .id(quoteIndex)
                .transition(.opacity)
        }
        .frame(maxWidth: 460, minHeight: 110, alignment: .top)
        .task {
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(9))
                } catch {
                    break
                }
                var next = Int.random(in: 0..<Quotes.all.count)
                while Quotes.all.count > 1 && next == quoteIndex {
                    next = Int.random(in: 0..<Quotes.all.count)
                }
                withAnimation(.easeInOut(duration: 1.0)) {
                    quoteIndex = next
                }
            }
        }
    }

    private func quoteView(_ quote: Quote) -> some View {
        VStack(spacing: 8) {
            Text(quote.text)
                .font(.system(size: 15, design: .serif).italic())
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
            if let author = quote.author {
                Text("— \(author)")
                    .font(.system(size: 12, design: .serif))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: 460)
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
