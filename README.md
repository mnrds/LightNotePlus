# LightNote+

A lightweight macOS text editor built with SwiftUI. LightNote+ provides a
tabbed editing workspace for plain-text and source files. 

> **Note:** LightNote+ is still under development. Features and
> behavior may change. The app only supports macOS. 

Designed to be a simple notepad, the app has no update checks, cloud sync, or
other online features. App won't ask you update or show popup windows to user. It's free to use. 

## Download for macOS 

**Latest release:** 1.0  
[Download the latest release](https://mnrds.org/light-note-plus/).

## Features

- No update checks or popup windows, no cloud sync, or online features—just a notepad
- Minimalistic look: Switch between light and dark themes
- Open and edit multiple files in tabs
- Open files through the File menu or by dragging them into the app
- Save and Save As
- Confirm before closing a tab with unsaved changes
- Automatically save modified files after 30 seconds without further edits
- Restore tabs and their contents from the previous session
- Choose UTF-8, UTF-16, UTF-16 LE, or UTF-16 BE encoding
- Show word and character counts in the editor status bar
- Zoom the editor text in and out 
- Find and replace function 
- Indent selected lines by four spaces
- Register `.txt`, `.css`, and `.html` as supported document types
- Create and organize Markdown notes in the Notes view using app-only headings;
  drag notes onto headings to organize them without moving their files on disk

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

Zoom shortcuts use the keys that produce `+` and `-` in the active keyboard
layout.

## File encodings

The editor defaults to UTF-8 and detects UTF-8/UTF-16 byte-order marks when
opening files. It also attempts to recognize BOM-less UTF-16. The encoding
selector is shown at the bottom of the editor. Changing the selection marks
the current tab as edited; saving then writes the file using that encoding.

## Session restore

The app stores the current tabs and selected tab when it quits. On the next
launch, **Session Restore** can recover that state. It is disabled after
editing content, creating a tab, or opening a file in the current launch.

## Current limitations

- Syntax highlighting is not implemented yet; the editor currently displays
  plain text.
- The native Find navigator requires macOS 26 or later.
- Autosave applies only to tabs associated with a file. Untitled tabs are not
  autosaved.
- The repository currently has no Xcode project, workspace, or Swift package
  manifest, so a fresh clone does not include a buildable project
  configuration.

## Requirements

- macOS 26.6 or newer - Tested on macOS 27.0.1 
- Building requires Xcode and a macOS development environment. The repository
  needs an Xcode project configuration before it can be built from a fresh
  clone.
