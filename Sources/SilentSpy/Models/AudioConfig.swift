import Foundation
import AppKit

public struct AudioConfig {
    public static let sampleRate: Double = 48000.0
    public static let bitsPerSample: Int = 16
    public static let channelCount: Int = 2 // Channel 1: Mic (Left), Channel 2: System Audio (Right)
    
    private static let storageBookmarkKey = "SilentSpy_StorageBookmark"
    private static let storagePathKey = "SilentSpy_StoragePath"
    
    public static var defaultStorageDirectory: URL {
        let musicDir = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Music")
        return musicDir.appendingPathComponent("SilenSpy-Recordings")
    }
    
    public static var storageDirectory: URL {
        get {
            if let bookmarkData = UserDefaults.standard.data(forKey: storageBookmarkKey) {
                var isStale = false
                if let resolvedURL = try? URL(resolvingBookmarkData: bookmarkData, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale) {
                    if !isStale {
                        _ = resolvedURL.startAccessingSecurityScopedResource()
                        return resolvedURL
                    }
                }
            }
            if let savedPath = UserDefaults.standard.string(forKey: storagePathKey) {
                let url = URL(fileURLWithPath: savedPath)
                if FileManager.default.fileExists(atPath: url.path) {
                    return url
                }
            }
            return defaultStorageDirectory
        }
        set {
            UserDefaults.standard.set(newValue.path, forKey: storagePathKey)
            if let bookmarkData = try? newValue.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
                UserDefaults.standard.set(bookmarkData, forKey: storageBookmarkKey)
            }
        }
    }
    
    public static func checkStoragePermission(for url: URL = storageDirectory) -> Bool {
        let path = url.path
        var isDir: ObjCBool = false
        if !FileManager.default.fileExists(atPath: path, isDirectory: &isDir) {
            do {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            } catch {
                return false
            }
        }
        
        // Check if actually writable by creating and removing a tiny test probe
        let probeFile = url.appendingPathComponent(".silentspy_permission_probe_\(UUID().uuidString)")
        do {
            try "probe".write(to: probeFile, atomically: true, encoding: .utf8)
            try FileManager.default.removeItem(at: probeFile)
            return true
        } catch {
            return false
        }
    }
    
    @MainActor
    public static func promptForStorageFolder(window: NSWindow? = nil, completion: @escaping (URL?) -> Void) {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.title = "Select Storage Folder for Recordings"
        panel.message = "Choose a destination folder for SilentSpy recordings:"
        panel.prompt = "Select Folder"
        panel.directoryURL = storageDirectory
        
        let handler: (NSApplication.ModalResponse) -> Void = { response in
            if response == .OK, let selectedURL = panel.url {
                _ = selectedURL.startAccessingSecurityScopedResource()
                self.storageDirectory = selectedURL
                completion(selectedURL)
            } else {
                completion(nil)
            }
        }
        
        if let window = window ?? NSApp.keyWindow ?? NSApp.mainWindow {
            panel.beginSheetModal(for: window, completionHandler: handler)
        } else {
            panel.begin(completionHandler: handler)
        }
    }
    
    public static func generateRecordingURL(prefix: String = "SilentSpy") -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm"
        let timestamp = formatter.string(from: Date())
        let baseFilename = "\(prefix)_\(timestamp)"
        var candidateURL = storageDirectory.appendingPathComponent("\(baseFilename).m4a")
        
        var counter = 1
        while FileManager.default.fileExists(atPath: candidateURL.path) {
            candidateURL = storageDirectory.appendingPathComponent("\(baseFilename)_\(counter).m4a")
            counter += 1
        }
        return candidateURL
    }
}
