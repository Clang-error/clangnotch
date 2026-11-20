#!/bin/bash
# Mechanical checks for mistakes that kept coming back. Each message says what to write instead.
#   tools/check.sh           lines added in the staged diff (the pre-commit hook runs this)
#   tools/check.sh --all     the whole tree
# Errors stop the commit; warnings only print.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)"

# file:line:text for every line to look at: the whole tree with --all, else the lines the
# staged diff adds. The pattern is matched against the text alone.
if [ "${1:-}" = "--all" ]; then
    candidates() { grep -rn '' $1 2>/dev/null; }
else
    candidates() {
        git diff --cached -U0 --diff-filter=AM -- $1 | awk '
            /^\+\+\+ b\// { file = substr($0, 7); next }
            /^@@/ { split($3, a, ","); line = substr(a[1], 2) + 0; next }
            /^\+/ { print file ":" line ":" substr($0, 2); line++; next }
            /^ / { line++ }'
    }
fi
lines() {
    candidates "$1" | RE="$2" awk 'BEGIN { re = ENVIRON["RE"] }
        { i = index($0, ":"); rest = substr($0, i + 1); j = index(rest, ":")
          if (substr(rest, j + 1) ~ re) print }'
}

errors=0
report() {  # level, message, hits
    [ -z "$3" ] && return
    echo "$1: $2"
    echo "$3" | sed 's/^/    /' | cut -c1-200
    [ "$1" = "error" ] && errors=$((errors + 1))
}

# Settings window text: menu paths take "->" and lists take commas (not ›, → or ·).
report error 'Settings text: write menu paths with "->" and lists with commas, not ›, → or ·. The notch screens are the exception.' \
    "$(lines "ClangNotch/Views/Settings" 'L\("[^"]*(›|→|·)')"

# No explaining sentences in the notch or the menu bar popover (2026-11-20): an empty state
# shows nothing or hides its part, it never says what will appear there; the user reviews every
# line and won't read prose. The settings window (its own review) is left out.
report error \
    'Notch text: no guide sentences ("~하면 여기에 표시됩니다"). Hide the empty part or leave it blank; keep labels to a few words.' \
    "$(lines "$(ls -d ClangNotch/Views/*/ | grep -v '/Settings/$' | tr '\n' ' ')" 'L\("[^"]*(니다|세요|어요|해요)\.?"')"

# The user speaks of sessions, not turns (2026-11-19): 턴 is Claude Code's word. Code may say "turn".
report error 'App text: write 세션 ("세션이 작업을 끝내면", "끝낸 세션"), not 턴.' \
    "$(lines "ClangNotch" 'L\("[^"]*턴' | grep -v '패턴')"

# What comes down from the notch is a 드롭다운 in the settings text; 방울 is a code name.
report error 'Settings text: call it a 드롭다운 (복사 드롭다운), not 방울.' \
    "$(lines "ClangNotch/Views/Settings" 'L\("[^"]*방울')"

# Other sessions run test copies of the app; killing by name takes those down too.
report error 'Scripts: kill the one instance by its pid (pgrep -f "^/Applications/ClangNotch.app/..."), never pkill or killall.' \
    "$(lines "tools" '(^|[;&|])[[:space:]]*(pkill|killall)([[:space:]]|$)')"

# Under pipefail, grep -q quits at the first match and the command feeding it dies of SIGPIPE
# (141): the pipe fails although the text was there (release.sh's helper check, 2026-11-18).
report error 'Scripts: "| grep -q" fails under pipefail when the writer is still writing (SIGPIPE). Read the output into a variable and test it, or use grep without -q.' \
    "$(lines "tools" '\|[[:space:]]*grep[[:space:]]+(-[a-zA-Z]*q|--quiet)' | grep -v -e '^[^:]*:[0-9]*:[[:space:]]*#' -e '^tools/check.sh:')"

# An active tap (.defaultTap) that macOS switched off must not come straight back: when
# Accessibility was taken away, a tap that keeps coming back freezes every key and click on the
# Mac until the app quits (2026-11-19). EventTapRecovery.tapWasDisabled turns it on again only
# while Accessibility allows it. Checked over the whole tree, by file.
report error 'Event taps: an active tap handles .tapDisabledByTimeout / .tapDisabledByUserInput with EventTapRecovery.tapWasDisabled(tap), not CGEvent.tapEnable(…, enable: true): re-enabled without Accessibility it freezes the keyboard and mouse.' \
    "$(grep -rl --include='*.swift' 'tapDisabledByTimeout' ClangNotch | xargs grep -l '\.defaultTap' 2>/dev/null | xargs grep -L 'EventTapRecovery.tapWasDisabled' 2>/dev/null)"

report warning 'repeatForever: fine for a fixed view; on a view whose SF Symbol name changes it redraws at display rate for good (the 30% CPU usage-card bug). Keep the symbol name fixed.' \
    "$(lines "ClangNotch" '\.repeatForever\(')"

report warning 'notchVM.fold(): a dropdown that ends goes through restorePeek() or foldPeek(), which hand the notch to the next notice; a bare fold left notices that never came down (tests/NotchDropdownModelChecks.swift).' \
    "$(lines "ClangNotch/Views" 'notchVM\.fold\(\)')"

# A line marked allow-print is one that must print: debugLog itself, or a script embedded in a string.
report warning 'print(: app logging goes through debugLog() so release builds stay quiet. A print that must stay (debugLog itself, a script in a string) gets an allow-print comment on its line.' \
    "$(lines "ClangNotch" '^[[:space:]]*print\(' | grep -v 'allow-print')"

exit $((errors > 0))
