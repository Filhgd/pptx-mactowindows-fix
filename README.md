# PPTX MacToWindows Fix

A small macOS menu bar app that makes images pasted in PowerPoint for Mac (clips copied from a PDF) look sharp when the presentation is opened on Windows. Your original is never changed; the Windows version is saved next to it as `name_windows.pptx`.

![icon](assets/icon.png)

## The problem

When you paste part of a PDF into PowerPoint for Mac, PowerPoint stores it as an EMF image with two versions inside:

- the original PDF, sharp at any size. This is what the Mac shows.
- a low-resolution backup bitmap, usually 400 to 550 pixels wide. This is what Windows shows, because Windows cannot read the PDF.

Enlarged on a slide, that backup ends up at roughly 45 to 75 ppi, which looks pixelated.

## What the app does

1. Finds the EMF images in the presentation that contain a PDF.
2. Renders each PDF as a 300 ppi PNG at the size it is shown on the slide (at most 5000 pixels), using the macOS PDF engine, so it looks the same as on your Mac.
3. Replaces the EMF with that PNG. Position, size and cropping stay the same, and every other part of the file is kept byte for byte.
4. Reads the new file back to check it before saving.

Other images (regular PNG, JPEG) are left alone. A presentation without such clips does not get a Windows version.

## Usage

The app lives in the menu bar as a magic wand icon.

- **Drop:** drop one or more presentations, or a folder, on the menu bar icon or on the app in Finder. A batch gets one summary notification.
- **Automatic:** choose a folder in the menu. Every presentation that lands in that folder (or a subfolder), or is changed there, automatically gets an updated Windows version next to it.
- **Open at Login:** can be turned on in the menu.

Click the "Windows version ready" notification to show the file in Finder.

## Installation

Download `PPTX-MacToWindows-Fix-macOS.zip` from the latest release, unzip it and move the app to Applications. Requires macOS 13 or later (Apple silicon or Intel).

## Building

Requires Xcode or the Command Line Tools.

```
./build_app.sh
tests/run_tests.sh      # needs: pip install python-pptx pillow
```

Command line: `"PPTX MacToWindows Fix.app/Contents/MacOS/PPTXFix" --fix in.pptx [out.pptx]`, or `--fix-all file1.pptx file2.pptx ...`

## Source layout

| File | Contents |
|---|---|
| `Sources/Zip.swift` | Reading and writing ZIP files (no external libraries) |
| `Sources/EMF.swift` | Extracting the PDF from a Mac EMF |
| `Sources/Render.swift` | PDF to PNG with Core Graphics |
| `Sources/Fixer.swift` | Rewriting and checking the presentation |
| `Sources/main.swift` | Menu bar, drag and drop, watched folder, notifications |
| `tests/` | Builds test presentations and checks the results |
