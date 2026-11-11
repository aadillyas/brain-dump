import AppKit

if !Headless.runIfRequested(CommandLine.arguments) {
    BrainDumpApp.main()
} else {
    dispatchMain()
}
