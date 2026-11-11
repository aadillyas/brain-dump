import SwiftUI

struct CanvasView: View {
    @Environment(AppModel.self) private var model
    @FocusState private var focused: Bool
    let ns: Namespace.ID

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            Group {
                if model.isDictating {
                    liveText
                } else {
                    TextEditor(text: $model.text)
                        .font(Theme.writing)
                        .lineSpacing(Theme.lineSpacing)
                        .scrollContentBackground(.hidden)
                        .focused($focused)
                        .onChange(of: model.text) { model.typed() }
                }
            }
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity)
            .padding(.top, 40)
            RecorderPanel()
        }
        .background {
            RoundedRectangle(cornerRadius: 28)
                .fill(Theme.card)
                .shadow(color: .black.opacity(0.06), radius: 12, y: 3)
                .matchedGeometryEffect(id: "dumpCard", in: ns)
        }
        .overlay(alignment: .topLeading) {
            if model.text.isEmpty && !model.isDictating && model.elapsed == 0 {
                Button { withAnimation { model.goHome() } } label: { Label("Home", systemImage: "chevron.left") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .padding(20)
            }
        }
        .padding(16)
        .onAppear { focused = true }
        .onChange(of: model.isDictating) { _, dictating in if !dictating { focused = true } }
    }

    private var liveText: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text("\(Text(model.displayText))\(Text(volatileTail).foregroundColor(.secondary.opacity(0.65)))")
                        .font(Theme.writing)
                        .lineSpacing(Theme.lineSpacing)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 8)
                        .textSelection(.enabled)
                    Color.clear.frame(height: 1).id("end")
                }
            }
            .onChange(of: model.dictation.volatile) { proxy.scrollTo("end", anchor: .bottom) }
            .onChange(of: model.displayText) { proxy.scrollTo("end", anchor: .bottom) }
        }
    }

    private var volatileTail: String {
        let v = model.dictation.volatile
        guard !v.isEmpty else { return "" }
        let base = model.displayText
        return base.isEmpty || base.last?.isWhitespace == true ? v : " " + v
    }
}

/// A big record button wrapped in a ring that drains over the target time, with the clock and a live word count.
struct RecorderPanel: View {
    @Environment(AppModel.self) private var model
    @State private var pulse = false

    private let size: CGFloat = 148

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle().stroke(ringColor.opacity(0.15), lineWidth: 8)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(ringColor, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 1), value: progress)
                recordButton
            }
            .frame(width: size, height: size)

            Text(clock)
                .font(.system(size: 40, weight: .light, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(model.isOvertime ? Theme.overtime : .primary)
                .contentTransition(.numericText())
                .contextMenu {
                    Button(model.timerRunning ? "Pause timer" : "Resume timer", action: model.toggleTimer)
                    Button("Reset timer", action: model.resetTimer)
                }

            Text(message)
                .font(.system(size: 14, design: .serif))
                .foregroundStyle(model.isOvertime ? Theme.overtime : .secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .frame(minHeight: 20)

            HStack(spacing: 18) {
                timerPicker
                Text("\(model.wordCount) words").monospacedDigit()
                Button("Done", action: model.done)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(model.text.isEmpty && !model.isDictating)
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity)
    }

    private var progress: CGFloat {
        guard model.timerSeconds > 0 else { return 0 }
        return model.isOvertime ? 1 : CGFloat(model.remaining) / CGFloat(model.timerSeconds)
    }

    private var ringColor: Color { model.isOvertime ? Theme.overtime : Theme.accent }

    private var clock: String {
        if model.isOvertime { return "+" + Self.format(model.overtime) }
        return Self.format(model.timerSeconds > 0 ? model.remaining : model.elapsed)
    }

    static func format(_ s: Int) -> String { String(format: "%d:%02d", s / 60, s % 60) }

    private var message: String {
        if case .preparing(let p) = model.dictation.state {
            return p > 0 && p < 1 ? "Preparing speech model \(Int(p * 100))%" : "Preparing speech model…"
        }
        if let error = model.dictation.errorMessage { return error }
        if model.isOvertime { return "You've gone past your target — keep going!" }
        if model.dictation.isRecording { return "Listening… say whatever is on your mind." }
        if model.elapsed > 0 { return "Paused. Tap to keep talking, or press Done." }
        return "Tap to start talking, or just type."
    }

    private var timerPicker: some View {
        Picker("Timer", selection: Binding(get: { model.timerSeconds }, set: { model.setTimer($0) })) {
            ForEach(Prefs.timerChoices, id: \.seconds) { Text($0.label).tag($0.seconds) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .help("Target time. Brain Dump never stops you at the end.")
    }

    private var recordButton: some View {
        let recording = model.dictation.isRecording
        return Button(action: model.toggleRecording) {
            ZStack {
                Circle()
                    .fill(recording ? Color.red : Theme.accent)
                    .scaleEffect(recording && pulse ? 1.04 : 1)
                Image(systemName: recording ? "stop.fill" : "mic.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(.white)
            }
            .frame(width: size - 28, height: size - 28)
        }
        .buttonStyle(.plain)
        .keyboardShortcut("r", modifiers: .command)
        .help(recording ? "Stop" : "Record")
        .disabled(model.dictation.state == .finishing || model.dictation.state != .idle && !recording)
        .onChange(of: recording) { _, on in
            if on {
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { pulse = true }
            } else {
                withAnimation(.default) { pulse = false }
            }
        }
    }
}
