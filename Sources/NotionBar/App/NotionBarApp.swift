import AppKit

/// NotionBar: your unfinished Notion tasks and steps, in the menu bar.
///
/// Normal launch needs no arguments. For trying things without a token:
///
///     NotionBar --demo [--show]                 run on the bundled sample data
///     NotionBar --selftest                      check the logic and the Notion calls
///     NotionBar --dump                          print the sections as text
///     NotionBar --snapshot out.png [--state s] [--dark]   draw the panel to an image
@main
enum NotionBarMain {
    // Kept alive for the life of the process (NSApplication only holds its delegate weakly).
    @MainActor private static var delegate: AppDelegate?

    @MainActor
    static func main() {
        let options = LaunchOptions()
        if options.selfTest { SelfTest.runAndExit() }
        if options.dump { Dump.runAndExit(options) }

        let app = NSApplication.shared
        let delegate = AppDelegate(options: options)
        NotionBarMain.delegate = delegate
        app.delegate = delegate
        // Menu bar only: no Dock icon, no main window. (Info.plist says the same with LSUIElement.)
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
