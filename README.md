<p align="center">
  <img src="Textream/Textream/Assets.xcassets/AppIcon.appiconset/icon_256x256.png" width="128" height="128" alt="Textream icon">
</p>

<h1 align="center">Textream</h1>

<p align="center">
  <strong>A free macOS teleprompter that highlights your script in real-time as you speak.</strong>
</p>

<p align="center">
  Built for streamers, interviewers, presenters, and podcasters.
</p>

<p align="center">
  <a href="#download">Download</a> · <a href="#features">Features</a> · <a href="#how-it-works">How It Works</a> · <a href="#building-from-source">Build</a>
</p>

<p align="center">
  <img src="docs/video.gif" width="600" alt="Textream demo">
</p>

---

## What is Textream?

Textream is a free, open-source macOS app that listens to your voice and highlights your script in real-time. It displays your text in a sleek **Dynamic Island-style overlay** at the top of your screen, a **draggable floating window**, or **fullscreen on a Sidecar iPad** — visible only to you, invisible to your audience.

Paste your script, hit play, and start speaking. Words light up as you say them. When you're done, the overlay closes automatically.

## Download

**[Download the latest .dmg from Releases](https://github.com/f/textream/releases/latest)**

Or install with Homebrew:

```bash
brew install f/textream/textream
```

> Requires **macOS 15 Sequoia** or later. Works on Apple Silicon and Intel.

### First launch

Since Textream is distributed outside the Mac App Store, macOS may block it on first open. Run this once in Terminal:

```bash
xattr -cr /Applications/Textream.app
```

Then right-click the app → **Open**. After the first launch, macOS remembers your choice.

## Features

- **Real-time voice tracking** — On-device speech recognition highlights words as you say them. No cloud, no latency, works offline.
- **Dynamic Island overlay** — A notch-shaped floating overlay at the top of your screen, inspired by the MacBook Dynamic Island. Sits above all apps.
- **Floating window mode** — Switch from the pinned notch to a draggable floating window you can place anywhere on screen.
- **Glass effect** — Enable a translucent frosted glass background for the floating window with adjustable opacity.
- **External display / Sidecar** — Show a fullscreen teleprompter on an external display or Sidecar iPad. Includes a mirror mode for use with prompter mirror rigs.
- **Font customization** — Choose from font size presets (S, M, L, XL) and color presets (white, yellow, blue, green, pink).
- **Live waveform** — Visual voice activity indicator so you always know the mic is picking you up.
- **Tap to jump** — Tap any word in the overlay to jump the tracker to that position.
- **Pause & resume** — Go off-script, take a break, come back. The tracker picks up where you left off.
- **Adjustable size** — Resize the overlay width and text height from Settings (⌘,) to fit your screen.
- **Language selection** — Choose your preferred speech recognition language. The current language is shown in the title bar.
- **Completely private** — All processing happens on-device. No accounts, no tracking, no data leaves your Mac.
- **Open source** — MIT licensed. Contributions welcome.

## Who it's for

| Use case | How Textream helps |
|---|---|
| **Streamers** | Read sponsor segments, announcements, and talking points without looking away from the camera. |
| **Interviewers** | Keep your questions visible while maintaining natural eye contact with your guest. |
| **Presenters** | Deliver keynotes, demos, and talks with confidence. Never lose your place. |
| **Podcasters** | Follow show notes, ad reads, and topic outlines hands-free while recording. |

## How It Works

1. **Paste your script** — Drop your talking points, interview questions, or full script into the text editor.
2. **Hit play** — The Dynamic Island overlay slides down from the top of your screen.
3. **Start speaking** — Words highlight in real-time as you read. When you finish, the overlay closes automatically.

## Building from Source

### Requirements

- macOS 15+
- Xcode 16+
- Swift 5.0+

### Build

```bash
git clone https://github.com/f/textream.git
cd textream/Textream
open Textream.xcodeproj
```

Build and run with ⌘R in Xcode.

### Project structure

```
Textream/
├── Textream.xcodeproj
├── Info.plist
└── Textream/
    ├── TextreamApp.swift              # App entry point, deep link handling
    ├── ContentView.swift              # Main text editor UI + About view
    ├── TextreamService.swift          # Service layer, URL scheme handling
    ├── SpeechRecognizer.swift         # On-device speech recognition engine
    ├── NotchOverlayController.swift   # Dynamic Island + floating overlay
    ├── ExternalDisplayController.swift # Sidecar / external display output
    ├── NotchSettings.swift            # User preferences and presets
    ├── SettingsView.swift             # Tabbed settings UI
    ├── MarqueeTextView.swift          # Word flow layout and highlighting
    └── Assets.xcassets/               # App icon and colors
```

## URL Scheme

Textream supports the `textream://` URL scheme for launching directly into the overlay:

```
textream://read?text=Hello%20world
```

It also registers as a macOS Service, so you can select text in any app and send it to Textream via the Services menu.

## License

MIT

---

<p align="center">
  Original idea by <a href="https://x.com/semihdev">Semih Kışlar</a> — thanks to him!<br>
  Made by <a href="https://fka.dev">Fatih Kadir Akin</a>
</p>
