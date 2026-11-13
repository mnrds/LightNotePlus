# LightNote+

LightNote+ is a lightweight macOS app that combines a plain-text editor with a
Markdown notes workspace. Switch between the two views from the toolbar, and
choose which view opens by default in Settings.

The app is inspired by the simplicity of Apple Notes and the Markdown workflow
of Obsidian. This is a side project currently under development, so features
and functionality may change.

## Download

**Latest release:** 1.2
[Download LightNote+ for macOS](https://mnrds.org/light-note-plus/).

>If macOS does not allow you to open the app, go to **System Settings → Privacy
>& Security** and click **Open Anyway**.

## Features

### Changelog

#### v1.2

>**Notes**
>
>- Fixed various bugs and improved overall stability.
>- Refined the user interface for better clarity and usability.
>- Show the editor and preview side by side; the preview follows your edits.
>- Faster typing and searching in large notes and folders: the sidebar, word
>  count, and preview no longer redraw on every keystroke, and note contents are
>  cached for search, with results updating while you edit.
>- Support for `.markdown` and `.txt` notes in addition to `.md`.
>- Keyboard navigation in the sidebar: arrow keys to browse, Return to start
>  typing, Delete to move a note to the Trash, double-click to rename.
>- Drag notes onto **Unsorted** to remove them from a heading.
>- Toggle checklist items from the keyboard (`⌘↩`) and with VoiceOver, and
>  tick checkboxes directly in the preview.
>- Typing `#`, `>` or `1.` at the start of a line formats it in the preview, as
>  in the editor.
>- Unsaved-changes dot on the note tab; the selected tab scrolls into view.
>- Messages when there are no notes or no search results.
>- Word count ignores Markdown syntax.
>- Notes font size setting; the View zoom commands now apply to notes too.
>- Notes code split into the `NoteView/` folder.
>- Added find in note (`⌘F`).
>
>**Text Editor**
>
>- Fixed various bugs and improved overall stability.
>- The scroll bar is always visible and can be dragged, in both themes.
>- Fixed the text cursor appearing over the Notes sidebar and blocking clicks.
>- Added syntax highlighting for Python, PHP, and JavaScript.
>- Changed the default save format to .txt.
>- Fixed an issue with line numbering when exceeding 1,000 lines.
>
>**Settings**
>
>- Export stores the Notes folder relative to your home folder (no absolute
>  paths). If it differs when importing, you can choose that folder or apply
>  the settings to the current one.


### Text editor

- Edit multiple files in tabs; open files from the File menu or by dragging them
  into the app
- Save and Save As, with a prompt before closing tabs that have unsaved changes
- Automatically save changes to files after 30 seconds without further edits
- Restore tabs and the selected tab from the previous session
- Read and write UTF-8, UTF-16, UTF-16 LE, and UTF-16 BE files
- Syntax highlighting for Swift, Python, JavaScript/TypeScript, PHP, HTML, CSS,
  JSON, XML, and Markdown
- Show line numbers, word count, and character count
- Find text, indent selected lines, and zoom the editor text

### Markdown notes

- Privacy first: the app works fully offline. Notes are saved as files on your
  computer, or in a folder of your choice such as a network drive
- Notes can be `.md`, `.markdown`, or `.txt` files
- Edit Markdown in the source editor, view the rendered preview, or show both
  side by side. Formatting tools cover bold, italic, underline, strikethrough,
  headings, checklists, quotes, separators, and links. Font-size controls are
  omitted to keep saved Markdown portable
- Tick checklist items in the preview, with the keyboard, or with VoiceOver
- Organize notes under app-only headings without moving files on disk
- Store heading organization in a hidden `.lightnote.json` file using paths
  relative to the notes folder, so it travels with the folder
- Detect external note changes and avoid overwriting them with stale edits
- Create and rename notes and headings, move notes between headings by menu or
  drag and drop, and collapse heading contents
- Browse notes in the sidebar with the keyboard
- Search note names, heading names, and note contents, including unsaved edits
- Keep multiple notes open in tabs, with an indicator for unsaved changes
- View word count (excluding Markdown syntax) and character count
- Adjust the notes font size in Settings and zoom with the View commands
- Choose a custom notes folder in Settings
- Export and import heading organization, including heading order and note
  assignments; note files themselves are not included

### App settings

- Choose light or dark appearance
- Set the notes font size
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
| Toggle checklist item in Notes | `⌘↩` |
| Open selected note for typing (sidebar) | `↩` |
| Move selected note to Trash (sidebar) | `⌫` |

Zoom shortcuts use the keys that produce `+` and `-` on the active keyboard
layout.

## Requirements and building

- macOS 26.6 or newer (the version declared by the app)
- Xcode and a macOS development environment to build from source

This repository currently does not include an Xcode project or workspace, or a
Swift package manifest. A fresh clone therefore does not yet include the
project configuration needed to build the app directly.
