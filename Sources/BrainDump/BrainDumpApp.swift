import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct BrainDumpApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("Brain Dump") {
            RootView()
                .environment(model)
                .frame(minWidth: 980, minHeight: 640)
        }
        .defaultSize(width: 1180, height: 760)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Notes") { model.section = .notes; model.notesShowGraph = false }.keyboardShortcut("l", modifiers: .command)
                Button("Graph") { model.openGraph() }.keyboardShortcut("g", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .help) {
                Button("How to use Brain Dump") { model.showIntro = true }
            }
        }

        Settings {
            SettingsView()
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Namespace private var ns

    var body: some View {
        @Bindable var model = model
        return NavigationSplitView {
            List(selection: $model.section) {
                Label {
                    HStack {
                        Text("Dump")
                        if model.phase == .review {
                            Circle().fill(Theme.accent).frame(width: 8, height: 8).help("A review is waiting")
                        }
                    }
                } icon: { Image(systemName: "mic") }
                    .tag(AppSection.dump)
                Label("Review", systemImage: "calendar.badge.checkmark").tag(AppSection.review)
                Label("Notes", systemImage: "note.text").tag(AppSection.notes)
                Label("Journal", systemImage: "book").tag(AppSection.journal)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 240)
        } detail: {
            ZStack {
                Theme.paper.ignoresSafeArea()
                switch model.section {
                case .dump: dump
                case .review: WeeklyReviewView()
                case .notes: NotesView()
                case .journal: JournalView()
                }
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Button { model.showIntro = true } label: { Label("Help", systemImage: "questionmark.circle") }
                    .help("How to use Brain Dump")
                SettingsLink { Label("Settings", systemImage: "gearshape") }
                    .help("Settings")
            }
        }
        .sheet(isPresented: $model.showIntro) { IntroView() }
    }

    private var dump: some View {
        ZStack {
            switch model.phase {
            case .home: HomeView(ns: ns)
            case .canvas: CanvasView(ns: ns)
            case .processing: SplitReviewView()
            case .failed(let message): FailureView(message: message)
            case .review: SplitReviewView()
            case .summary: SummaryView()
            }
        }
        .animation(.easeInOut(duration: 0.25), value: model.phase)
    }
}

enum Theme {
    static let paper = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0.105, green: 0.105, blue: 0.115, alpha: 1)
            : NSColor(red: 0.980, green: 0.972, blue: 0.955, alpha: 1)
    })
    static let accent = Color(red: 0.25, green: 0.58, blue: 0.62)
    static let overtime = Color(red: 0.30, green: 0.70, blue: 0.45)
    static let card = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0.155, green: 0.155, blue: 0.170, alpha: 1)
            : NSColor(red: 1, green: 1, blue: 0.995, alpha: 1)
    })
    static let writing = Font.system(size: 19, design: .serif)
    static let body = Font.system(size: 16, design: .serif)
    static let lineSpacing: CGFloat = 8
}
