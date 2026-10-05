import SwiftUI

public struct MainWindowView: View {
    @ObservedObject public var manager: RecordingManager
    public var onClose: (() -> Void)?
    
    // Core 3-Color Palette
    private let amberColor = Color(red: 1.0, green: 0.65, blue: 0.2)
    private let redColor = Color(red: 1.0, green: 0.25, blue: 0.25)
    
    public init(manager: RecordingManager, onClose: (() -> Void)? = nil) {
        self.manager = manager
        self.onClose = onClose
    }
    
    // MARK: - Dynamic Icon States
    @State private var isCloseHovered: Bool = false
    @State private var isFolderHovered: Bool = false
    @State private var isTopFolderHovered: Bool = false
    @State private var isEditFolderHovered: Bool = false
    @State private var isMicPermHovered: Bool = false
    @State private var isScreenPermHovered: Bool = false
    @State private var isStoragePermHovered: Bool = false
    // MARK: - Dynamic Icon States (Only animate color to white when recording; no animation when idle)
    private var isRecordingActive: Bool {
        manager.isRecording
    }
    
    private var idleIconColor: Color {
        Color.white.opacity(0.35)
    }
    
    private var micIconColor: Color {
        if isRecordingActive {
            return manager.micLevel > 0.05 ? Color.white : Color.white.opacity(0.35)
        } else {
            return Color.white.opacity(0.35)
        }
    }
    
    private var micShadowColor: Color {
        if isRecordingActive && manager.micLevel > 0.05 {
            return Color.white.opacity(0.4)
        } else {
            return Color.clear
        }
    }
    
    private var systemIconColor: Color {
        if isRecordingActive {
            return manager.systemLevel > 0.05 ? Color.white : Color.white.opacity(0.35)
        } else {
            return Color.white.opacity(0.35)
        }
    }
    
    private var systemShadowColor: Color {
        if isRecordingActive && manager.systemLevel > 0.05 {
            return Color.white.opacity(0.4)
        } else {
            return Color.clear
        }
    }
    
    public var body: some View {
        VStack(spacing: 10) {
            // Unified Header: Live Pulsating Indicators, Timer & Utility Actions
            headerView
                .zIndex(100)
            
            // Quit Prompt Toast if active
            if manager.quitPromptActive {
                HStack(spacing: 5) {
                    Image(systemName: "command")
                        .font(.system(size: 8, weight: .bold))
                    Text("Press ⌘Q again to quit")
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .fill(Color.white.opacity(0.13))
                        .overlay(
                            RoundedRectangle(cornerRadius: 13, style: .continuous)
                                .stroke(Color.white.opacity(0.20), lineWidth: 0.8)
                        )
                )
                .transition(.opacity.combined(with: .scale(scale: 0.95)))
                .zIndex(30)
            }
            
            // Error Banner if present
            if let error = manager.errorMessage {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.octagon.fill")
                        .foregroundColor(redColor)
                    Text(error)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(redColor)
                        .lineLimit(2)
                    Spacer()
                    Button(action: { manager.errorMessage = nil }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.white.opacity(0.6))
                    }
                    .buttonStyle(.plain)
                    .focusable(false)
                    .focusEffectDisabled()
                }
                .padding(8.5)
                .background(
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .fill(redColor.opacity(0.15))
                        .overlay(
                            RoundedRectangle(cornerRadius: 13, style: .continuous)
                                .stroke(redColor.opacity(0.35), lineWidth: 0.8)
                        )
                )
                .zIndex(20)
            }
            
            // Permissions Banner if needed
            if !manager.hasMicPermission || !manager.hasScreenPermission || !manager.hasStoragePermission {
                permissionsCard
                    .zIndex(10)
            }
            
            // Action Button: Unified Record / Stop HUD Button (24% bigger: 52x52 ring, 22x22 record circle, 18.5x18.5 stop square)
            Button(action: {
                if manager.isRecording {
                    manager.stopRecording()
                } else {
                    manager.startRecording()
                }
            }) {
                ZStack {
                    Circle()
                        .fill(redColor.opacity(0.18))
                        .frame(width: 52, height: 52)
                        .overlay(
                            Circle()
                                .stroke(redColor.opacity(manager.isRecording ? 0.65 : 0.45), lineWidth: 1.2)
                        )
                        .shadow(color: redColor.opacity(0.25), radius: 6, y: 1)
                    
                    if manager.isRecording {
                        // Stop Icon (Solid Red Square matching Record core)
                        RoundedRectangle(cornerRadius: 4.2, style: .continuous)
                            .fill(redColor)
                            .frame(width: 18.5, height: 18.5)
                            .shadow(color: redColor.opacity(0.6), radius: 3)
                    } else {
                        // Record Icon (Solid Red Circle)
                        Circle()
                            .fill(redColor)
                            .frame(width: 22.3, height: 22.3)
                            .shadow(color: redColor.opacity(0.6), radius: 3)
                    }
                }
            }
            .buttonStyle(.plain)
            .focusable(false)
            .focusEffectDisabled()
            .help(manager.isRecording ? "Stop Recording" : "Start Recording")
            .frame(maxWidth: .infinity)
            .padding(.top, 1)
            .zIndex(1)
        }
        .padding(.horizontal, 10)
        .padding(.top, 9)
        .padding(.bottom, 14)
        .frame(width: 184)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color(red: 0.09, green: 0.09, blue: 0.11))
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(
                            LinearGradient(
                                colors: [Color.white.opacity(0.18), Color.white.opacity(0.04)],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: 1
                        )
                )
                .shadow(color: Color.black.opacity(0.5), radius: 16, x: 0, y: 6)
        )
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
    
    // MARK: - Header
    private var headerView: some View {
        HStack(spacing: 6) {
            // Microphone Icon (Fixed size, animates color to white when active during recording)
            Image(systemName: "mic.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(micIconColor)
                .shadow(color: micShadowColor, radius: 3)
                .animation(.easeOut(duration: 0.08), value: micIconColor)
                .frame(width: 14)
            
            // System Audio Icon (Fixed size, animates color to white when active during recording)
            Image(systemName: "speaker.wave.3.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(systemIconColor)
                .shadow(color: systemShadowColor, radius: 3)
                .animation(.easeOut(duration: 0.08), value: systemIconColor)
                .frame(width: 14)
            
            // Live Duration Timer
            Text(manager.formattedDuration)
                .font(.system(size: 11, weight: .regular, design: .monospaced))
                .foregroundColor(Color.white.opacity(0.55))
                .lineLimit(1)
                .fixedSize()
            
            Spacer()
            
            // Storage Folder Controls (Slide-down menu on hover)
            folderControls
            
            // Close Button
            if let onClose = onClose {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .heavy))
                        .foregroundColor(isCloseHovered ? .white.opacity(0.8) : idleIconColor)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(isCloseHovered ? Color.white.opacity(0.10) : Color.white.opacity(0.05)))
                }
                .buttonStyle(.plain)
                .focusable(false)
                .focusEffectDisabled()
                .help("Hide HUD (Open from Menu Bar)")
                .onHover { hovering in
                    isCloseHovered = hovering
                }
            }
        }
    }
    
    // MARK: - Folder Controls (Hover Expansion)
    private var folderControls: some View {
        Color.clear
            .frame(width: 22, height: 22)
            .overlay(alignment: .top) {
                VStack(spacing: 4) {
                    // Top Button: Open Storage Folder in Finder
                    Button(action: {
                        manager.openStorageFolder()
                    }) {
                        ZStack {
                            Circle()
                                .fill(isFolderHovered ? Color.white.opacity(isTopFolderHovered ? 0.22 : 0.16) : Color.white.opacity(0.05))
                                .frame(width: 22, height: 22)
                            
                            if isFolderHovered {
                                openFolderIcon
                            } else {
                                Image(systemName: "folder.fill")
                                    .font(.system(size: 10.5))
                                    .foregroundColor(idleIconColor)
                            }
                        }
                        .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.plain)
                    .focusable(false)
                    .focusEffectDisabled()
                    .help(isFolderHovered ? "Open Storage Folder in Finder" : "Storage Folder: \(manager.storageDirectoryURL.path)")
                    .onHover { h in
                        isTopFolderHovered = h
                    }
                    
                    // Bottom Button: Edit / Change Storage Folder (Slides down on hover)
                    if isFolderHovered {
                        Button(action: {
                            manager.requestStoragePermission()
                        }) {
                            ZStack {
                                Circle()
                                    .fill(Color(red: 0.11, green: 0.11, blue: 0.13))
                                    .frame(width: 22, height: 22)
                                Circle()
                                    .fill(Color.white.opacity(isEditFolderHovered ? 0.24 : 0.14))
                                    .frame(width: 22, height: 22)
                                    .overlay(
                                        Circle()
                                            .stroke(Color.white.opacity(0.25), lineWidth: 0.8)
                                    )
                                    .shadow(color: Color.black.opacity(0.6), radius: 5, y: 2)
                                
                                editFolderIcon
                            }
                            .frame(width: 22, height: 22)
                            .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .focusable(false)
                        .focusEffectDisabled()
                        .help("Change Storage Folder...")
                        .onHover { h in
                            isEditFolderHovered = h
                        }
                        .transition(
                            .asymmetric(
                                insertion: .move(edge: .top).combined(with: .opacity),
                                removal: .move(edge: .top).combined(with: .opacity)
                            )
                        )
                    }
                }
                .frame(width: 32, height: isFolderHovered ? 54 : 22, alignment: .top)
                .contentShape(Rectangle())
                .onHover { hovering in
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.78)) {
                        isFolderHovered = hovering
                        if !hovering {
                            isTopFolderHovered = false
                            isEditFolderHovered = false
                        }
                    }
                }
            }
            .zIndex(100)
    }
    
    // MARK: - Open Folder Icon
    private var openFolderIcon: some View {
        ZStack(alignment: .bottom) {
            Path { p in
                p.move(to: CGPoint(x: 1, y: 11))
                p.addLine(to: CGPoint(x: 1, y: 3))
                p.addLine(to: CGPoint(x: 4.5, y: 3))
                p.addLine(to: CGPoint(x: 6, y: 4.5))
                p.addLine(to: CGPoint(x: 13, y: 4.5))
                p.addLine(to: CGPoint(x: 13, y: 11))
                p.closeSubpath()
            }
            .fill(Color.white.opacity(0.65))
            
            RoundedRectangle(cornerRadius: 0.8)
                .fill(amberColor)
                .frame(width: 8, height: 5)
                .offset(y: -4.5)
            
            Path { p in
                p.move(to: CGPoint(x: 0, y: 11))
                p.addLine(to: CGPoint(x: 1.5, y: 6))
                p.addLine(to: CGPoint(x: 12.5, y: 6))
                p.addLine(to: CGPoint(x: 14, y: 11))
                p.closeSubpath()
            }
            .fill(Color.white.opacity(0.95))
        }
        .frame(width: 14, height: 11)
    }
    
    // MARK: - Folder with Edit Icon
    private var editFolderIcon: some View {
        ZStack(alignment: .bottomTrailing) {
            Image(systemName: "folder.fill")
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.85))
            Image(systemName: "pencil")
                .font(.system(size: 6, weight: .bold))
                .foregroundColor(amberColor)
                .offset(x: 2.5, y: 2)
        }
    }
    
    // MARK: - Permissions Card
    private var permissionsCard: some View {
        HStack(spacing: 10) {
            if !manager.hasMicPermission {
                Button(action: { manager.requestMicPermission() }) {
                    ZStack {
                        Circle()
                            .fill(isMicPermHovered ? Color.white.opacity(0.18) : Color.white.opacity(0.05))
                            .frame(width: 24, height: 24)
                        
                        Image(systemName: "mic.slash.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(isMicPermHovered ? .white : idleIconColor)
                    }
                    .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .focusable(false)
                .focusEffectDisabled()
                .help("Grant Microphone Permission")
                .onHover { h in
                    withAnimation(.easeInOut(duration: 0.15)) {
                        isMicPermHovered = h
                    }
                }
            }
            
            if !manager.hasScreenPermission {
                Button(action: { manager.requestScreenPermission() }) {
                    ZStack {
                        Circle()
                            .fill(isScreenPermHovered ? Color.white.opacity(0.18) : Color.white.opacity(0.05))
                            .frame(width: 24, height: 24)
                        
                        Image(systemName: "speaker.slash.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(isScreenPermHovered ? .white : idleIconColor)
                    }
                    .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .focusable(false)
                .focusEffectDisabled()
                .help("Grant System Audio Permission")
                .onHover { h in
                    withAnimation(.easeInOut(duration: 0.15)) {
                        isScreenPermHovered = h
                    }
                }
            }
            
            if !manager.hasStoragePermission {
                Button(action: { manager.requestStoragePermission() }) {
                    ZStack {
                        Circle()
                            .fill(isStoragePermHovered ? Color.white.opacity(0.18) : Color.white.opacity(0.05))
                            .frame(width: 24, height: 24)
                        
                        Image(systemName: "folder.badge.minus")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(isStoragePermHovered ? .white : idleIconColor)
                    }
                    .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .focusable(false)
                .focusEffectDisabled()
                .help("Select Storage Folder")
                .onHover { h in
                    withAnimation(.easeInOut(duration: 0.15)) {
                        isStoragePermHovered = h
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }
}


