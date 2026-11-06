import Foundation
import AppKit
import AVFoundation

public struct AudioConfig {
    public static let sampleRate: Double = 48000.0
    public static let bitsPerSample: Int = 16
    public static let channelCount: Int = 2 // Channel 1: Mic (Left), Channel 2: System Audio (Right)
    
    private static let storageBookmarkKey = "SilentSpy_StorageBookmark"
    private static let storagePathKey = "SilentSpy_StoragePath"

    /// Resolved storage folder. Resolving a bookmark can touch the disk or network, so it is done
    /// once and cached; it's refreshed only when the user picks a new folder.
    private static var cachedStorageDirectory: URL? // guarded by storageLock
    private static let storageLock = NSLock()

    /// Output settings for `AVCaptureAudioDataOutput`: Core Audio converts whatever the device
    /// delivers (any rate, bit depth or layout) to Float32 @ `sampleRate`.
    public static func captureOutputSettings(channels: Int) -> [String: Any] {
        return [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: true,
            AVLinearPCMIsBigEndianKey: false,
        ]
    }

    public static var defaultStorageDirectory: URL {
        let musicDir = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Music")
        return musicDir.appendingPathComponent("SilenSpy-Recordings")
    }
    
    /// The app is not sandboxed, so plain (non security-scoped) bookmarks are used: they just track the
    /// folder across renames/moves. The path is stored as well, as a fallback.
    public static var storageDirectory: URL {
        get {
            storageLock.lock()
            defer { storageLock.unlock() }
            if let cached = cachedStorageDirectory {
                return cached
            }
            let resolved = resolveStoredDirectory()
            cachedStorageDirectory = resolved
            return resolved
        }
        set {
            let url = newValue.standardizedFileURL
            storageLock.lock()
            cachedStorageDirectory = url
            storageLock.unlock()
            UserDefaults.standard.set(url.path, forKey: storagePathKey)
            if let bookmarkData = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
                UserDefaults.standard.set(bookmarkData, forKey: storageBookmarkKey)
            }
        }
    }

    private static func resolveStoredDirectory() -> URL {
        let defaults = UserDefaults.standard
        if let bookmarkData = defaults.data(forKey: storageBookmarkKey) {
            var isStale = false
            // Never show UI or mount a volume just to resolve the folder.
            if let url = try? URL(resolvingBookmarkData: bookmarkData, options: [.withoutUI, .withoutMounting],
                                  relativeTo: nil, bookmarkDataIsStale: &isStale) {
                if isStale, let fresh = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
                    defaults.set(fresh, forKey: storageBookmarkKey)
                    defaults.set(url.path, forKey: storagePathKey)
                }
                return url
            }
        }
        if let savedPath = defaults.string(forKey: storagePathKey) {
            return URL(fileURLWithPath: savedPath, isDirectory: true)
        }
        return defaultStorageDirectory
    }

    /// Cheap, side-effect-free check (no disk writes, never creates the folder): is the folder there and
    /// writable, or — if missing — could it be created? Safe to call often, but still does file-system
    /// metadata calls, so keep it off the main thread when the folder may be on a slow/network volume.
    public static func quickStoragePermissionCheck(for url: URL = storageDirectory) -> Bool {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: url.path, isDirectory: &isDir) {
            return isDir.boolValue && fm.isWritableFile(atPath: url.path)
        }
        // Missing: creatable if the nearest existing ancestor is a writable directory.
        var parent = url.deletingLastPathComponent()
        while parent.path != "/" && !fm.fileExists(atPath: parent.path) {
            parent = parent.deletingLastPathComponent()
        }
        return fm.isWritableFile(atPath: parent.path)
    }

    /// Authoritative check used right before recording: creates the folder if needed and proves it is
    /// writable with a probe file. Performs disk I/O — call off the main thread.
    public static func checkStoragePermission(for url: URL = storageDirectory) -> Bool {
        let path = url.path
        var isDir: ObjCBool = false
        if !FileManager.default.fileExists(atPath: path, isDirectory: &isDir) {
            do {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            } catch {
                return false
            }
        } else if !isDir.boolValue {
            return false
        }

        // Check if actually writable by creating and removing a tiny test probe
        let probeFile = url.appendingPathComponent(".silentspy_permission_probe_\(UUID().uuidString)")
        do {
            try "probe".write(to: probeFile, atomically: false, encoding: .utf8)
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
        // Fixed Gregorian/POSIX formatting: file names must not depend on the user's calendar or locale.
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd_HH-mm"
        let timestamp = formatter.string(from: Date())
        let baseFilename = "\(prefix)_\(timestamp)"
        let directory = storageDirectory
        var candidateURL = directory.appendingPathComponent("\(baseFilename).m4a")
        
        var counter = 1
        while FileManager.default.fileExists(atPath: candidateURL.path) {
            candidateURL = directory.appendingPathComponent("\(baseFilename)_\(counter).m4a")
            counter += 1
        }
        return candidateURL
    }
}
