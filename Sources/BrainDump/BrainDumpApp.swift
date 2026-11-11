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
                .frame(minWidth: 640, minHeight: 480)
        }
        .defaultSize(width: 900, height: 700)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Library") { model.showLibrary = true }.keyboardShortcut("l", modifiers: .command)
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
        return ZStack {
            Theme.paper.ignoresSafeArea()
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
        .toolbar {
            ToolbarItem {
                if model.phase != .home {
                    Button { model.showLibrary = true } label: { Label("Library", systemImage: "books.vertical") }
                        .help("Open the Library")
                }
            }
        }
        .sheet(isPresented: $model.showLibrary) { LibraryView() }
        .sheet(isPresented: $model.showIntro) { IntroView() }
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
