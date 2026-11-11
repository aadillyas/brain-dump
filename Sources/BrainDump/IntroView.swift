import AVFoundation
import AppKit
import BrainDumpCore
import EventKit
import SwiftUI

struct IntroView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(Prefs.Key.notesPath) private var notesPath = ""
    @State private var step = 0
    @State private var micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    @State private var remindersStatus = EKEventStore.authorizationStatus(for: .reminder)

    private var notesURL: URL { notesPath.isEmpty ? NotesStore.defaultRoot : URL(fileURLWithPath: notesPath) }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Step \(step + 1) of 3").font(.system(size: 11, weight: .semibold)).tracking(1.2).foregroundStyle(.secondary)
            switch step {
            case 0: how
            case 1: permissions
            default: folder
            }
            Spacer(minLength: 0)
            HStack {
                if step > 0 { Button("Back") { step -= 1 } }
                Spacer()
                if step < 2 {
                    Button("Next") { step += 1 }.keyboardShortcut(.defaultAction)
                } else {
                    Button("Get started") { Prefs.introSeen = true; dismiss() }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(32)
        .frame(width: 520, height: 380)
        .interactiveDismissDisabled()
    }

    private var how: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("How it works").font(.system(size: 24, design: .serif))
            Text("Talk or type through your morning for a few minutes. Press Done and a small model on this Mac reads your dump.")
            Text("It finds To-dos, Ideas and Thoughts and shows them beside your words. Approve the ones you want: To-dos go to Reminders, Ideas and Thoughts to notes. Your journal is always saved.")
        }
        .foregroundStyle(.secondary)
    }

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Permissions").font(.system(size: 24, design: .serif))
            Text("Both are optional. Speech is transcribed on this Mac.").foregroundStyle(.secondary)
            row("Microphone", "mic", micStatus == .authorized, denied: micStatus == .denied || micStatus == .restricted) {
                Task {
                    _ = await AVCaptureDevice.requestAccess(for: .audio)
                    micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
                }
            }
            row("Reminders", "checklist", remindersStatus == .fullAccess, denied: remindersStatus == .denied || remindersStatus == .restricted) {
                Task {
                    _ = await RemindersConnector.requestAccess()
                    remindersStatus = EKEventStore.authorizationStatus(for: .reminder)
                }
            }
        }
    }

    private func row(_ name: String, _ icon: String, _ granted: Bool, denied: Bool, action: @escaping () -> Void) -> some View {
        HStack {
            Label(name, systemImage: icon)
            Spacer()
            if granted {
                Label("Allowed", systemImage: "checkmark").foregroundStyle(.green)
            } else if denied {
                Text("Denied. Change in System Settings.").font(.system(size: 12)).foregroundStyle(.orange)
            } else {
                Button("Allow \(name)", action: action)
            }
        }
    }

    private var folder: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Notes folder").font(.system(size: 24, design: .serif))
            Text("Journal entries, ideas and thoughts are saved here as markdown files.").foregroundStyle(.secondary)
            Text(notesURL.path).font(.system(size: 12)).textSelection(.enabled)
            HStack {
                Button("Use default (~/BrainDump)") { notesPath = "" }
                Button("Choose existing folder…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.canCreateDirectories = true
                    if panel.runModal() == .OK, let url = panel.url { notesPath = url.path }
                }
            }
        }
    }
}
