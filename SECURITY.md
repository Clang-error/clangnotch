# Security

## Reporting a vulnerability

Report it privately through GitHub: open the [Security tab](https://github.com/Clang-error/clangnotch/security) and choose **Report a vulnerability**. Please don't open a public issue for it.

You will get a reply within two days.

It helps to include:

- the ClangNotch version (Settings -> About) and your macOS version
- the steps that lead to the problem
- what someone could do with it

## Supported versions

The latest release and the latest beta. A fix goes into the next release; older versions are not patched.

## What the app touches

For judging whether something is in scope:

- **Local receiver.** ClangNotch listens on `127.0.0.1:4318` for the hooks Claude Code and Codex post. It is bound to the loopback address only and refuses requests a browser page could make (any with an `Origin` header, or a `Host` other than `127.0.0.1` or `localhost`). Any program running as you can still post to it. The notch's approval dropdown spells out invisible characters, and for a command too long to show at once Allow stays off until it has been opened and scrolled to the end; a very long one can only be answered in the agent's own prompt. Settings -> Security can turn either lock off for someone who accepts the risk; both are on by default. File edits show their paths, not their contents.
- **Agent files.** It reads session files under `~/.claude` and `~/.codex`. Approving from the notch adds hooks to `~/.claude/settings.json` and `~/.codex/hooks.json`, backing up the originals first.
- **SSH hosts.** A password you choose to save is kept in the Keychain. The helper that hands it to `ssh` answers only an `ssh` that ClangNotch itself started.
- **Energy mode helper.** Off unless you install it from the Battery tab (click the Mac's row, then the install button) and allow it in System Settings -> General -> Login Items. It then runs as root to change the Mac's energy mode without a password. It takes only a mode number (automatic, low power or high power) and runs one fixed `pmset` command; it answers only ClangNotch signed by this developer, and a release build also refuses a copy a debugger can attach to. ClangNotch talks only to a helper with the same signature. Remove it from Settings -> Features or from Login Items.
- **Updates.** A new version is downloaded from this repository's releases over HTTPS and put in place when you click Restart to Update or, with "Install downloaded updates automatically" on (the default), by itself once your agents are idle and the notch is closed. Either way only if its bundle identifier, version, Developer ID signature and notarization check out.
- **Network.** GitHub for update checks. With their features on: Anthropic for Claude usage (with Claude Code's own sign-in), Cloudflare for the speed test, T world for the SKT shared data balance, and the SSH hosts you add. Clipboard history and key presses stay on this Mac.

---

## 한국어

취약점은 공개 이슈로 올리지 말고 GitHub의 비공개 제보로 알려 주세요. [Security 탭](https://github.com/Clang-error/clangnotch/security)에서 **Report a vulnerability**를 누르면 됩니다. 2일 안에 답합니다.

ClangNotch 버전(설정 -> 정보), macOS 버전, 재현 순서, 그 문제로 무엇을 할 수 있는지를 함께 적어 주시면 도움이 됩니다.

지원하는 버전은 최신 릴리스와 최신 베타입니다. 수정은 다음 릴리스에 들어가고, 예전 버전은 따로 고치지 않습니다.
