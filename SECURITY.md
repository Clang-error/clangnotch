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

- **Local receiver.** ClangNotch takes the hooks Claude Code and Codex post on a Unix socket in `~/Library/Application Support/ClangNotch`, a folder only your account can open (until 1.5.0 it was `127.0.0.1:4318`, which other accounts on the Mac could reach). Any program running as you can still post to it. The notch's approval dropdown spells out invisible characters. Allow stays off for a command with a sign of danger (running a downloaded script, `sudo`, touching SSH keys and the like, or too long to check), and for a command too long to show at once until it has been opened and scrolled to the end; a very long one can only be answered in the agent's own prompt. Settings -> Security can turn either lock off for someone who accepts the risk; both are on by default. File edits show their paths, not their contents.
- **Agent files.** It reads session files under `~/.claude` and `~/.codex`, the Claude app's session list, Codex's logs and the environment of the processes the sessions run in (to find their terminal tab). At launch, while an agent is turned on, it adds its hooks to `~/.claude/settings.json` (approvals, questions, notifications, and a copy of the status line's input) and `~/.codex/hooks.json` (approvals), backing up the originals first. Programs that aren't part of macOS (`codex`, `tmux`, a terminal's command line tool) run without ClangNotch's privacy permissions.
- **SSH hosts.** A password or key passphrase you choose to save is kept in the Keychain, together with the host keys it may be sent to. A host with a saved one is reached without reading `~/.ssh/config` (what the config says about it is passed along, and a host behind a proxy can't use a saved password), and the helper that hands the secret to `ssh` answers only an `ssh` that ClangNotch itself started that way, for ssh's own password or passphrase prompt. What a host sends back through its tunnel comes in apart from this Mac's own hooks and can only show that host's sessions and questions, never an approval.
- **Energy mode helper.** Off unless you install it from the Battery tab (click the Mac's row, then the install button) and allow it in System Settings -> General -> Login Items. It then runs as root to change the Mac's energy mode without a password. It takes only a mode number (automatic, low power or high power) and runs one fixed `pmset` command; it answers only ClangNotch signed by this developer, and a release build also refuses a copy a debugger can attach to. ClangNotch talks only to a helper with the same signature. Remove it from Settings -> Features or from Login Items.
- **Updates.** A new version is downloaded from this repository's releases over HTTPS and put in place when you click Restart to Update or, with "Install downloaded updates automatically" on (the default), by itself once your agents are idle and the notch is closed. Either way only if its bundle identifier, version, Developer ID signature and notarization check out.
- **Network.** GitHub for update checks and the What's New text. With their features on: Anthropic for Claude usage (with Claude Code's own sign-in, refreshing it when it has expired), OpenAI for Codex usage (through the `codex` command line tool, with its own sign-in), Cloudflare for the speed test, SK Telecom for the T world shared data balance (with the T ID you save), and the SSH hosts you add. Clipboard history and key presses stay on this Mac.

---

## 한국어

취약점은 공개 이슈로 올리지 말고 GitHub의 비공개 제보로 알려 주세요. [Security 탭](https://github.com/Clang-error/clangnotch/security)에서 **Report a vulnerability**를 누르면 됩니다. 2일 안에 답합니다.

ClangNotch 버전(설정 -> 정보), macOS 버전, 재현 순서, 그 문제로 무엇을 할 수 있는지를 함께 적어 주시면 도움이 됩니다.

지원하는 버전은 최신 릴리스와 최신 베타입니다. 수정은 다음 릴리스에 들어가고, 예전 버전은 따로 고치지 않습니다.
