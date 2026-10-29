<p align="center">
  <img src="icon.png" width="128" alt="ClangNotch icon">
</p>

<h1 align="center">ClangNotch</h1>

<p align="center">
  English · <a href="README.ko.md">한국어</a>
</p>

<p align="center">
  Watch Claude Code and Codex work, right in your Mac's notch.
</p>

<p align="center">
  <img src="assets/demo-both.gif" width="100%" alt="Claude Code and Codex working together: answering a question from the notch, then done">
</p>

<p align="center">
  <img src="assets/demo-claude.gif" width="49%" alt="Claude Code working → question → done">
  <img src="assets/demo-codex.gif" width="49%" alt="Codex working → question → done">
</p>

---

ClangNotch sits in the notch and shows what your coding agents are doing: which tool is running, whether a reply has finished, and whether one is waiting on you. It reads the session files Claude Code and Codex already write, so there's nothing to set up.


## Install

Download `ClangNotch.dmg` from [Releases](../../releases) and drag it into your Applications folder.

The app isn't notarized, so macOS blocks it the first time. Open **System Settings → Privacy & Security** and click **Open Anyway**.

Requires macOS 14.2 or later. On a Mac without a notch, it appears in the same shape at the top of the screen.

## Features

**Agents**

- Live status for Claude Code (CLI, desktop app, VS Code) and Codex (CLI, desktop app), read from `~/.claude/projects` and `~/.codex/sessions`
- The closed notch shows the tool that's running, then Done with a checkmark when a turn ends
- Answer permission requests and `AskUserQuestion` questions from the notch
- Sessions grouped by folder. Click one to see each step and the file changes
- 5-hour and weekly usage for Claude and Codex
- Claude Code sessions running on an SSH server (over a reverse tunnel)
- Codex on an SSH server isn't supported yet

**Tools**

Each one is a tab in the open notch, and each can be turned off in Settings.

<p align="center">
  <img src="assets/demo-tools.gif" width="80%" alt="Clipboard, per-app volume, batteries, speed test, Sidecar and display arrangement tabs">
</p>

- Clipboard history (text only, kept in memory)
- Per-app volume
- iPad Sidecar controls
- Quick access to multi-display arrangement
- Battery for your Mac, Bluetooth devices, iPhone and iPad
- Speed test and network info
- Keyboard lock

The volume and brightness keys show ClangNotch's own slider instead of the system one.

The app's interface is in Korean by default. Switch it to English in **Settings → General → Display language**.

## Permissions

| Permission | Used for |
|---|---|
| Accessibility | Volume and brightness keys, keyboard lock, moving the system overlay |
| Notifications | Low battery alerts |
| Location | Reading the Wi-Fi name (macOS won't share it without location access) |
| Audio capture | Per-app volume |

Approving from the notch adds hooks to `~/.claude/settings.json` and `~/.codex/hooks.json`, and backs up the original files first. Codex only runs a new hook after you trust it once in `/hooks`.

iPhone and iPad battery needs [libimobiledevice](https://libimobiledevice.org). The install button in the Battery tab runs `brew install libimobiledevice` in Terminal.

## Build

```bash
git clone https://github.com/Clang-error/clangnotch.git
cd clangnotch
xcodebuild -project ClangNotch.xcodeproj -scheme ClangNotch -configuration Release build
```

Before building, set the project's Signing team to your own.

## License

[MIT](LICENSE)
