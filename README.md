# mac-screen-rec

A tiny Mac app that records **a region of your screen together with system audio** — straight to MP4 (H.264 + AAC). Free, open source, no watermark, no time limit.

![macOS 13+](https://img.shields.io/badge/macOS-13%2B-Ventura%2B-success)

## Requirements

- macOS 13 (Ventura) or later, Apple Silicon or Intel
- Screen Recording permission (macOS prompts you on first use)

## Install

1. Download the latest `MacScreenRec-…-universal-macos.zip` from [Releases](https://github.com/robtandy/mac-screen-rec/releases)
2. Unzip it and drag **MacScreenRec** into `/Applications`
3. Right-click the app and choose **Open** (releases are unsigned — see below), then click **Open** in the dialog
4. On first recording, macOS asks for **Screen & System Audio Recording** permission — enable it for Mac Screen Recorder, then click Record again

> **Updating to a new version?** The app is unsigned, so macOS pins the Screen Recording
> permission to one exact build — a toggle that still shows “on” won't apply to the new
> version (and toggling it doesn't re-bind it). Run this in Terminal, relaunch the app,
> and approve the prompt:
>
> ```sh
> tccutil reset ScreenCapture com.robtandy.MacScreenRec
> ```

## Use

1. Click **Select Region…** and drag over the part of the screen you want
2. Click **Record** — a floating bar shows the timer
3. Stop with the **stop hotkey** (Esc by default, works from any app), the bar's **Stop** button, or ⌘↩
4. The MP4 is saved to `~/Movies` (there's a **Reveal in Finder** button) and the region frame clears

To change the stop hotkey, click it in the main window and press a new combination (Esc, a function key, or any key with ⌘/⌥/⌃/⇧).

The region frame and floating bar are visible on your screen but are excluded from the recording. System audio = whatever your Mac is playing (music, browser, calls…); the microphone is not recorded. The region must live on a single display.

### Known limitations

- **Silent audio with some Bluetooth outputs** — a few Bluetooth devices (e.g. some wireless headphones) don't expose their audio to macOS' loopback tap, so recordings made while they are the active output are silent. This is a macOS/ScreenCaptureKit limitation; switch to the built-in speakers or a wired/USB output for those recordings.
- Videos are 30 fps H.264 with AAC audio.

## Build from source

```sh
make            # build the app into build/MacScreenRec.app
make install    # build + copy to /Applications
make release    # universal build + zip into dist/
```

Requires Xcode Command Line Tools (`xcode-select --install`). Development extras:

```sh
make smoke                                        # launch-and-quit smoke test
build/MacScreenRec.app/Contents/MacOS/MacScreenRec --selftest   # 6 s end-to-end test recording
swift Scripts/Probe.swift <file.mp4>               # inspect a recording's tracks/duration
```

> **Note on permission prompts:** running the binary directly from a terminal
> attributes the Screen Recording permission prompt to your terminal app
> (macOS attributes shell-launched processes to the app that spawned them).
> Launch the app normally (Finder, Dock, or `open`) and the prompt correctly
> names **Mac Screen Recorder**. These are separate grants — a terminal-granted
> permission doesn't carry over to the app, and vice versa.

## Why the "unidentified developer" warning

Release binaries are ad-hoc signed (no Apple Developer ID) because Apple notarization requires a paid developer account. The app is fully open source — build it yourself with `make` if you prefer, or verify the published SHA-256 in the release notes.

## License

[MIT](LICENSE)
