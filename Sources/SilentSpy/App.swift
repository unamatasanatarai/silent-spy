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
    
    func applicationWillTerminate(_ notification: Notification) {
        if let manager = self.manager, manager.isRecording {
            manager.stopRecording()
        }
    }
}
