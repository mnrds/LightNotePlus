# LightNote+

LightNote+ is a lightweight macOS app that combines a plain-text editor with a
Markdown notes workspace. Switch between the two views from the toolbar, and
choose which view opens by default in Settings.

The app is inspired by the simplicity of Apple Notes and the Markdown workflow
of Obsidian. This is a side project currently under development, so features
and functionality may change.

## Download

**Latest release:** 1.1
[Download LightNote+ for macOS](https://mnrds.org/light-note-plus/).

>If macOS does not allow you to open the app, go to **System Settings → Privacy
>& Security** and click **Open Anyway**.

## Features

### Text editor

- Edit multiple files in tabs; open files from the File menu or by dragging them
  into the app
- Save and Save As, with a prompt before closing tabs that have unsaved changes
- Automatically save changes to files after 30 seconds without further edits
- Restore tabs and the selected tab from the previous session
- Read and write UTF-8, UTF-16, UTF-16 LE, and UTF-16 BE files
- Syntax highlighting for CSS and HTML
- Show line numbers, word count, and character count
- Find text, indent selected lines, and zoom the editor text

### Markdown notes

- Privacy first: App works totally offline. Note files are saved locally on your computer or you can choose network drive 
- Write and preview Markdown in an editable preview, with formatting tools for
  bold, italic, headings, checklists, quotes, separators, and links
- Organize notes under app-only headings without moving files on disk
- Create and rename notes and headings, move notes between headings, and
  collapse heading contents
- Search note names, heading names, and note contents
- Keep multiple notes open in tabs
- View word and character counts
- Choose a custom notes folder in Settings
- Export and import heading organization, including heading order and note
  assignments; note files themselves are not included

### App settings

- Choose light or dark appearance
- Select the default opening view
- Choose the folder used for Markdown notes
- Export or import notes organization

## Keyboard shortcuts

| Action | Shortcut |
| --- | --- |
| Open | `⌘O` |
| Save | `⌘S` |
| Save As | `⌘⇧S` |
| Find | `⌘F` |
| Indent Selection | `⌘]` |
| Zoom In | `⌘+` |
| Zoom Out | `⌘-` |
| Actual Size | `⌘0` |
| Bold in Notes | `⌘B` |
| Italic in Notes | `⌘I` |

Zoom shortcuts use the keys that produce `+` and `-` on the active keyboard
layout.

## Requirements and building

- macOS 26.0 or newer (the version declared by the app)
- Xcode and a macOS development environment to build from source

This repository currently does not include an Xcode project or workspace, or a
Swift package manifest. A fresh clone therefore does not yet include the
project configuration needed to build the app directly.
