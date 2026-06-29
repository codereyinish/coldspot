#!/bin/bash
# mac/lib/prompt.sh — interactive prompt helper for the ColdSpot installer.
#
# ask(): shows a default as grey "ghost" text you can accept with Enter or type
# over. Stray keys (Tab, arrows, other control chars) are ignored so the hint
# never vanishes; the ghost clears only when you type a real character, and
# comes back if you backspace to empty.
#
# It's hand-rolled with raw char-by-char reads instead of bash 4's `read -e -i`
# so it runs on macOS's stock bash 3.2 — no Homebrew bash dependency.

# Fallbacks so this is safe to source even if the caller didn't define colors.
: "${BLD:=}"; : "${DIM:=}"; : "${RST:=}"

# Usage: ask VAR "Question" "default"
ask() {
    local var=$1 question=$2 default=$3 input="" ch junk
    printf "\n  ${BLD}%s${RST}: " "$question"
    # Draw the grey ghost default (no-op if no default). MUST return 0 — under
    # the installer's `set -e`, a bare call returning non-zero would exit the
    # whole script.
    _draw_ghost() {
        [ -n "$default" ] || return 0
        printf '\033[s'; printf "${DIM}%s${RST}" "$default"; printf '\033[u'
        return 0
    }
    _draw_ghost
    while IFS= read -rsn1 ch; do
        case "$ch" in
            '')                                          # Enter → accept
                if [ -z "$input" ] && [ -n "$default" ]; then printf "\033[K%s" "$default"; fi
                break ;;
            $'\033') read -rsn2 -t 1 junk 2>/dev/null || true ;;  # ESC: swallow arrow seq, ignore
            $'\t')   : ;;                                # Tab: ignore (ghost stays)
            $'\177'|$'\b')                               # backspace
                if [ -n "$input" ]; then
                    input="${input%?}"; printf '\b \b'
                    if [ -z "$input" ]; then printf '\033[K'; _draw_ghost; fi   # empty → ghost back
                fi ;;
            [[:print:]])                                 # a real printable char
                if [ -z "$input" ]; then printf '\033[K'; fi   # first real char wipes the ghost
                input+="$ch"; printf '%s' "$ch" ;;
            *) : ;;                                       # any other control char: ignore
        esac
    done
    printf '\n'
    eval "$var=\"${input:-$default}\""
}

# True if $1 is a syntactically valid IPv4 address (e.g. 203.0.113.10).
valid_ipv4() {
    local ip=$1 a b c d e o
    case $ip in ''|*[!0-9.]*) return 1 ;; esac          # non-empty, only digits and dots
    IFS=. read -r a b c d e <<< "$ip"
    [ -n "$a" ] && [ -n "$b" ] && [ -n "$c" ] && [ -n "$d" ] && [ -z "$e" ] || return 1
    for o in "$a" "$b" "$c" "$d"; do (( 10#$o <= 255 )) || return 1; done
    return 0
}
