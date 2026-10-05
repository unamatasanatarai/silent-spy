import AppKit
import SwiftUI
import Combine

@MainActor
public final class MenuBarController: NSObject, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private let manager: RecordingManager
    private var cancellables = Set<AnyCancellable>()
    private var mainWindowController: NSWindowController?
    
    private var lastQuitPressTime: Date?
    private var quitResetWorkItem: DispatchWorkItem?
    private var localKeyMonitor: Any?
    private var contextMenu: NSMenu?
    
    public init(manager: RecordingManager) {
        self.manager = manager
        super.init()
        setupStatusItem()
        observeRecordingState()
        setupKeyMonitor()
    }
    
    deinit {
        if let monitor = localKeyMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }
    
    private func setupKeyMonitor() {
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "q" {
                self?.handleQuitRequest()
                return nil // Consume event
            }
            return event
        }
    }
    
    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem?.button {
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        updateStatusDisplay(isRecording: false)
        buildMenu()
    }
    
    private func loadStatusIcon(named name: String) -> NSImage? {
        var image: NSImage?
        if let bundleUrl = Bundle.main.url(forResource: name, withExtension: "png"),
           let img = NSImage(contentsOf: bundleUrl) {
            image = img
        } else if let img = NSImage(contentsOfFile: "Resources/\(name).png") {
            image = img
        }
        
        guard let img = image else { return nil }
        
        // Status bar icon sizing (18pt height, maintaining aspect ratio)
        let targetHeight: CGFloat = 18.0
        let origSize = img.size
        let aspectRatio = origSize.height > 0 ? (origSize.width / origSize.height) : 1.0
        let targetWidth = max(10, min(24, targetHeight * aspectRatio))
        img.size = NSSize(width: targetWidth, height: targetHeight)
        img.isTemplate = true
        return img
    }
    
    private func updateStatusDisplay(isRecording: Bool) {
        guard let button = statusItem?.button else { return }
        
        button.title = ""
        button.attributedTitle = NSAttributedString(string: "")
        button.imagePosition = .imageOnly
        
        let iconName = isRecording ? "leaf-recording" : "leaf-idle"
        
        if let icon = loadStatusIcon(named: iconName) {
            button.image = icon
        } else {
            // Fallback to SF Symbol
            let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
            let symbolName = isRecording ? "record.circle.fill" : "waveform.badge.mic"
            let fallback = NSImage(systemSymbolName: symbolName, accessibilityDescription: "SilentSpy")?.withSymbolConfiguration(config)
            fallback?.isTemplate = true
            button.image = fallback
        }
    }
    
    private func observeRecordingState() {
        manager.$isRecording
            .receive(on: RunLoop.main)
            .sink { [weak self] isRec in
                self?.updateStatusDisplay(isRecording: isRec)
            }
            .store(in: &cancellables)
    }
    
    public func buildMenu() {
        let menu = NSMenu()
        menu.delegate = self
        
        let showWindowItem = NSMenuItem(title: "Show Window", action: #selector(showMainWindow), keyEquivalent: "w")
        showWindowItem.target = self
        menu.addItem(showWindowItem)
        
        let quitItem = NSMenuItem(title: "Quit", action: #selector(menuQuitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        
        self.contextMenu = menu
        statusItem?.menu = nil
    }
    
    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }
        
        if event.type == .rightMouseUp || (event.type == .leftMouseUp && event.modifierFlags.contains(.control)) {
            // Right-click: open menu
            if let menu = contextMenu {
                statusItem?.menu = menu
                statusItem?.button?.performClick(nil)
            }
        } else {
            // Left-click: toggle between record and stop
            if manager.isRecording {
                manager.stopRecording()
            } else {
                manager.startRecording()
            }
        }
    }
    
    public func menuDidClose(_ menu: NSMenu) {
        // Clear menu reference so subsequent left-clicks invoke button action
        statusItem?.menu = nil
    }
    
    @objc private func menuQuitApp() {
        if manager.isRecording {
            manager.stopRecording()
        }
        NSApp.terminate(nil)
    }
    
    @objc public func showMainWindow() {
        if let windowController = mainWindowController, let window = windowController.window {
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        
        let window = BorderlessHUDWindow(
            contentRect: NSRect(x: 0, y: 0, width: 184, height: 100),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        
        window.center()
        window.title = "SilentSpy"
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.level = .floating
        window.isMovableByWindowBackground = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isReleasedWhenClosed = false
        
        let contentView = MainWindowView(manager: manager, onClose: { [weak window] in
            window?.orderOut(nil)
        })
        let hostingController = NSHostingController(rootView: contentView)
        hostingController.view.wantsLayer = true
        hostingController.view.layer?.backgroundColor = NSColor.clear.cgColor
        hostingController.view.focusRingType = .none
        window.contentViewController = hostingController
        
        let controller = NSWindowController(window: window)
        self.mainWindowController = controller
        
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    
    @objc public func toggleMainWindow() {
        if let window = mainWindowController?.window, window.isVisible {
            window.orderOut(nil)
        } else {
            showMainWindow()
        }
    }
    
    @objc private func quitApp() {
        handleQuitRequest()
    }
    
    public func handleQuitRequest() {
        let now = Date()
        if let lastTime = lastQuitPressTime, now.timeIntervalSince(lastTime) <= 1.5 {
            // Second press within 1.5s -> terminate
            quitResetWorkItem?.cancel()
            manager.quitPromptActive = false
            if manager.isRecording {
                manager.stopRecording()
            }
            NSApp.terminate(nil)
        } else {
            // First press -> prompt user
            lastQuitPressTime = now
            manager.quitPromptActive = true
            showMainWindow()
            
            quitResetWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                self?.lastQuitPressTime = nil
                self?.manager.quitPromptActive = false
            }
            quitResetWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: workItem)
        }
    }
}

final class BorderlessHUDWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    
    override var initialFirstResponder: NSView? {
        get { nil }
        set { }
    }
    
    override func becomeKey() {
        super.becomeKey()
        // Prevent default macOS blue focus ring from selecting any button
        self.makeFirstResponder(nil)
    }
}


