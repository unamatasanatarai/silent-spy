import AppKit
import SwiftUI

@main
final class SilentSpyApp: NSObject, NSApplicationDelegate {
    private var manager: RecordingManager?
    private var menuBarController: MenuBarController?
    
    static func main() {
        let app = NSApplication.shared
        let delegate = SilentSpyApp()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        _ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
    }
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let iconImage = Bundle.main.image(forResource: "leaf-app-icon") ?? Bundle.main.image(forResource: "AppIcon") {
            NSApplication.shared.applicationIconImage = iconImage
        }
        
        let recManager = RecordingManager()
        self.manager = recManager
        
        let menuController = MenuBarController(manager: recManager)
        self.menuBarController = menuController
        
        // Open main UI window
        menuController.showMainWindow()
    }
    
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Keep running in menu bar even if window is closed
        return false
    }
    
    /// Never let the process exit while a recording is open or still being finalized: an M4A only
    /// becomes playable once its `moov` index is written on close. Delay termination until done.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let manager = manager, manager.hasUnfinalizedRecordings else {
            return .terminateNow
        }

        var replied = false
        let reply = {
            guard !replied else { return }
            replied = true
            sender.reply(toApplicationShouldTerminate: true)
        }
        manager.finalizeAll(completion: reply)
        // Backstop: never hang shutdown/logout indefinitely if the encoder wedges.
        DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: reply)
        return .terminateLater
    }
}
