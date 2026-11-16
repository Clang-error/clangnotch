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

# What comes down from the notch is a 드롭다운 in the settings text; 방울 is a code name.
report error 'Settings text: call it a 드롭다운 (복사 드롭다운), not 방울.' \
    "$(lines "ClangNotch/Views/Settings" 'L\("[^"]*방울')"

# Other sessions run test copies of the app; killing by name takes those down too.
report error 'Scripts: kill the one instance by its pid (pgrep -f "^/Applications/ClangNotch.app/..."), never pkill or killall.' \
    "$(lines "tools" '(^|[;&|])[[:space:]]*(pkill|killall)([[:space:]]|$)')"

report warning 'repeatForever: fine for a fixed view; on a view whose SF Symbol name changes it redraws at display rate for good (the 30% CPU usage-card bug). Keep the symbol name fixed.' \
    "$(lines "ClangNotch" '\.repeatForever\(')"

report warning 'print(: app logging goes through debugLog() so release builds stay quiet (a print inside an embedded script string is fine).' \
    "$(lines "ClangNotch" '^[[:space:]]*print\(')"

exit $((errors > 0))
