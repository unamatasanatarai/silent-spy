# SilentSpy 🎙️🔊

A native macOS application designed for dual-channel audio capture. It records your microphone (voice) and computer sounds (system audio) simultaneously onto separate audio channels, streaming compressed AAC audio directly to disk into `~/Music/SilenSpy-Recordings` on the fly with zero memory buildup.

---

## ✨ Features

- **Dual-Channel Audio Separation (Stereo M4A)**:
  - **Channel 1 (Left)**: Microphone / Voice.
  - **Channel 2 (Right)**: Computer Sounds / System Audio (captured via macOS ScreenCaptureKit).
- **Direct-to-Disk M4A/AAC Streaming (Zero Memory Buildup)**:
  - Audio samples are encoded into standard AAC `.m4a` files in real-time.
  - Memory consumption remains minimal (~few megabytes) even during multi-hour recordings.
- **Dedicated Target Directory**:
  - Automatically saves timestamped recordings to `~/Music/SilenSpy-Recordings/Recording_YYYY-MM-DD_HH-mm-ss.m4a`.
  - Easy folder picker to change the target destination at any time.
  - Quick action buttons to "Open Folder" or "Reveal File in Finder".
- **Modern macOS Interface**:
  - Live VU level meters with peak hold indicators for both channels.
  - Dynamic responsive animated sound wave visualizer.
  - Live recording timer and file size tracker.
- **macOS Menu Bar Integration**:
  - Status item with live pulsing recording indicator.
  - Global shortcuts to start/stop recording and view recorder window.

---

## 🚀 How to Run

### Build & Launch
To build and launch the app immediately:

```bash
make run
```

### Other Makefile Targets
- `make` — Builds the `SilentSpy.app` bundle in `./build/`
- `make run` — Builds and launches `SilentSpy.app`
- `make reset-perms` — Resets Microphone & Screen Capture permissions
- `make install` — Installs `SilentSpy.app` directly into `/Applications/`
- `make clean` — Cleans up build artifacts

---

## 🔒 Permissions Setup

On first launch, macOS requires two permissions for audio recording:
1. **Microphone**: Allows SilentSpy to record your microphone input.
2. **Screen & System Audio Recording**: Required by macOS ScreenCaptureKit to record computer sound output.

The app includes interactive permission status cards with direct buttons to request or verify access in **System Settings > Privacy & Security**.

---

## 🛠️ Technical Specifications

| Parameter | Value |
| :--- | :--- |
| **Platform** | macOS 13.0+ / 14.0+ (Apple Silicon & Intel) |
| **Audio Format** | 48,000 Hz, MPEG-4 AAC (.m4a) |
| **Channel Layout** | Stereo (Ch 1 / Left: Mic, Ch 2 / Right: System Audio) |
| **Storage Destination** | `~/Music/SilenSpy-Recordings/` (configurable) |
| **Capture Engines** | `AVAudioEngine` (Mic) + `ScreenCaptureKit` (System Audio) |

