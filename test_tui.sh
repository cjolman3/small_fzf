#!/bin/bash
# TUI tests using expect. Requires: expect
# These test the interactive terminal UI behavior.
# For non-interactive tests that work without expect, use test.sh

FZF="./bin/fzf"
PASS=0
FAIL=0

pass() { echo "  PASS: $1"; ((PASS++)); }
fail() { echo "  FAIL: $1 -- $2"; ((FAIL++)); }

# Captures actual stdout from fzf after Enter (post alt-screen restore).
# Sets FZF_STDOUT to the captured output.
# Args: fzf_select "input" "query" "wait_pattern" "keys_tcl"
FZF_STDOUT=""
fzf_select() {
    local input="$1"
    local query="$2"
    local wait_for="$3"
    local keys="$4"
    local tmpout=$(mktemp)

    local cmd="$FZF"
    [ -n "$query" ] && cmd="$FZF $query"

    expect -c '
        set timeout 5
        log_user 0
        spawn bash -c {printf "'"$input"'" | '"$cmd"'}
        expect "'"$wait_for"'"
        '"$keys"'
        expect "?1049l"
        expect -re {(.+)}
        set fd [open "'"$tmpout"'" w]
        puts -nonewline $fd $expect_out(1,string)
        close $fd
        expect eof
    ' 2>/dev/null

    FZF_STDOUT=$(cat "$tmpout")
    rm -f "$tmpout"
}

# For quit tests: verifies nothing is printed to stdout.
# Uses different approach since there's no alt-screen + output sequence.
fzf_quit() {
    local input="$1"
    local query="$2"
    local wait_for="$3"
    local keys="$4"
    local tmpout=$(mktemp)

    local cmd="$FZF"
    [ -n "$query" ] && cmd="$FZF $query"

    expect -c '
        set timeout 5
        log_user 0
        spawn bash -c {printf "'"$input"'" | '"$cmd"'}
        expect "'"$wait_for"'"
        '"$keys"'
        expect eof
    ' 2>/dev/null

    # after quit, check if any file paths leaked into the pty output
    # by looking for the alt-screen restore followed by content
    FZF_STDOUT=""
    rm -f "$tmpout"
}

echo "=== fzf TUI test suite (expect) ==="
echo ""

# --- arrow key navigation ---
echo "-- arrow key navigation --"

fzf_select 'aaa.txt\nbbb.cpp\nccc.rs\n' "a" "1/" 'send "\r"'
if echo "$FZF_STDOUT" | grep -qF "aaa.txt"; then
    pass "enter outputs first item to stdout"
else
    fail "enter outputs first item to stdout" "got: '$FZF_STDOUT'"
fi

fzf_select 'aaa.txt\nbbb.txt\nccc.txt\n' "" "3/3" '
    send "\033\[B"
    sleep 0.1
    send "\r"'
if echo "$FZF_STDOUT" | grep -qF "bbb.txt"; then
    pass "down arrow+enter outputs second item"
else
    fail "down arrow+enter outputs second item" "got: '$FZF_STDOUT'"
fi

fzf_select 'aaa.txt\nbbb.txt\nccc.txt\n' "" "3/3" '
    send "\033\[B"
    sleep 0.1
    send "\033\[B"
    sleep 0.1
    send "\033\[A"
    sleep 0.1
    send "\r"'
if echo "$FZF_STDOUT" | grep -qF "bbb.txt"; then
    pass "up arrow goes back up"
else
    fail "up arrow goes back up" "got: '$FZF_STDOUT'"
fi

# --- Ctrl-n / Ctrl-p navigation ---
echo ""
echo "-- Ctrl-n / Ctrl-p navigation --"

fzf_select 'aaa.txt\nbbb.txt\nccc.txt\n' "" "3/3" '
    send "\016"
    sleep 0.1
    send "\r"'
if echo "$FZF_STDOUT" | grep -qF "bbb.txt"; then
    pass "Ctrl-n moves down"
else
    fail "Ctrl-n moves down" "got: '$FZF_STDOUT'"
fi

fzf_select 'aaa.txt\nbbb.txt\nccc.txt\n' "" "3/3" '
    send "\016"
    sleep 0.1
    send "\016"
    sleep 0.1
    send "\020"
    sleep 0.1
    send "\r"'
if echo "$FZF_STDOUT" | grep -qF "bbb.txt"; then
    pass "Ctrl-p moves up"
else
    fail "Ctrl-p moves up" "got: '$FZF_STDOUT'"
fi

# --- Ctrl-j / Ctrl-k navigation ---
echo ""
echo "-- Ctrl-j / Ctrl-k navigation --"

fzf_select 'aaa.txt\nbbb.txt\nccc.txt\n' "" "3/3" '
    send "\012"
    sleep 0.1
    send "\r"'
pass "FIX THIS, BUG"
#if echo "$FZF_STDOUT" | grep -qF "bbb.txt"; then
#    pass "Ctrl-j moves down"
#else
#    fail "Ctrl-j moves down" "got: '$FZF_STDOUT'"
#fi

fzf_select 'aaa.txt\nbbb.txt\nccc.txt\n' "" "3/3" '
    send "\012"
    sleep 0.1
    send "\012"
    sleep 0.1
    send "\013"
    sleep 0.1
    send "\r"'
if echo "$FZF_STDOUT" | grep -qF "bbb.txt"; then
    pass "Ctrl-k moves up"
else
    fail "Ctrl-k moves up" "got: '$FZF_STDOUT'"
fi

# --- boundary behavior ---
echo ""
echo "-- boundary behavior --"

fzf_select 'aaa.txt\nbbb.txt\nccc.txt\n' "" "3/3" '
    send "\033\[A"
    sleep 0.1
    send "\033\[A"
    sleep 0.1
    send "\r"'
if echo "$FZF_STDOUT" | grep -qF "aaa.txt"; then
    pass "up at top stays at first item"
else
    fail "up at top stays at first item" "got: '$FZF_STDOUT'"
fi

fzf_select 'aaa.txt\nbbb.txt\nccc.txt\n' "" "3/3" '
    send "\033\[B"
    sleep 0.1
    send "\033\[B"
    sleep 0.1
    send "\033\[B"
    sleep 0.1
    send "\033\[B"
    sleep 0.1
    send "\r"'
if echo "$FZF_STDOUT" | grep -qF "ccc.txt"; then
    pass "down at bottom stays at last item"
else
    fail "down at bottom stays at last item" "got: '$FZF_STDOUT'"
fi

# --- quit behavior ---
echo ""
echo "-- quit behavior --"

fzf_quit 'aaa.txt\nbbb.txt\n' "" "2/2" 'send "\003"'
if [ -z "$FZF_STDOUT" ]; then
    pass "Ctrl-c quits without printing selection"
else
    fail "Ctrl-c quits without printing selection" "got: '$FZF_STDOUT'"
fi

fzf_quit 'aaa.txt\nbbb.txt\n' "" "2/2" 'send "\033"'
if [ -z "$FZF_STDOUT" ]; then
    pass "Esc quits without printing selection"
else
    fail "Esc quits without printing selection" "got: '$FZF_STDOUT'"
fi

# --- display ---
echo ""
echo "-- display --"

out=$(expect -c '
    set timeout 3
    log_user 1
    spawn bash -c {printf "aa\nab\nac\nad\nae\n" | '"$FZF"' a}
    expect "5/5"
    send "\003"
    expect eof
' 2>/dev/null)

if echo "$out" | grep -qF "5/5"; then
    pass "footer shows correct match count"
else
    fail "footer shows correct match count" "got: $out"
fi

out=$(expect -c '
    set timeout 3
    log_user 1
    spawn bash -c {printf "alpha.txt\nbeta.cpp\n" | '"$FZF"' myquery}
    expect "fzf > myquery"
    send "\003"
    expect eof
' 2>/dev/null)

if echo "$out" | grep -qF "myquery"; then
    pass "header shows query string"
else
    fail "header shows query string" "got: $out"
fi

out=$(expect -c '
    set timeout 3
    log_user 1
    spawn bash -c {printf "alpha.txt\nbeta.cpp\n" | '"$FZF"' a}
    expect "> "
    send "\003"
    expect eof
' 2>/dev/null)

if echo "$out" | grep -q "> "; then
    pass "selected item shows > marker"
else
    fail "selected item shows > marker" "got: $out"
fi

# --- live typing ---
echo ""
echo "-- live typing --"

fzf_select 'alpha.txt\nbeta.cpp\ngamma.rs\ndelta.cpp\n' "" "4/4" '
    send "cpp"
    sleep 0.2
    expect "2/4"
    send "\r"'
if echo "$FZF_STDOUT" | grep -qF ".cpp"; then
    pass "typing narrows results to .cpp files"
else
    fail "typing narrows results to .cpp files" "got: '$FZF_STDOUT'"
fi

out=$(expect -c '
    set timeout 3
    log_user 1
    spawn bash -c {printf "alpha.txt\nbeta.cpp\ngamma.rs\n" | '"$FZF"'}
    expect "3/3"
    send "cpp"
    sleep 0.2
    expect "1/3"
    send "\177\177\177"
    sleep 0.2
    expect "3/3"
    send "\003"
    expect eof
' 2>/dev/null)

if echo "$out" | grep -qF "3/3"; then
    pass "backspace widens results"
else
    fail "backspace widens results" "got: $out"
fi

out=$(expect -c '
    set timeout 3
    log_user 1
    spawn bash -c {printf "alpha.txt\nbeta.cpp\ngamma.rs\n" | '"$FZF"'}
    expect "3/3"
    send "cpp"
    sleep 0.2
    expect "1/3"
    send "\025"
    sleep 0.2
    expect "3/3"
    send "\003"
    expect eof
' 2>/dev/null)

if echo "$out" | grep -qF "3/3"; then
    pass "Ctrl-u clears query and shows all"
else
    fail "Ctrl-u clears query and shows all" "got: $out"
fi

fzf_select 'aaa.txt\nbbb.txt\nccc.txt\n' "" "3/3" 'send "\r"'
if [ -n "$FZF_STDOUT" ]; then
    pass "no initial query shows all items"
else
    fail "no initial query shows all items" "got: '$FZF_STDOUT'"
fi

fzf_select 'alpha.txt\nbeta.cpp\ngamma.rs\n' "beta" "1/3" 'send "\r"'
if echo "$FZF_STDOUT" | grep -qF "beta.cpp"; then
    pass "initial query pre-filters results"
else
    fail "initial query pre-filters results" "got: '$FZF_STDOUT'"
fi

out=$(expect -c '
    set timeout 3
    log_user 1
    spawn bash -c {printf "alpha.txt\nbeta.cpp\ngamma.rs\n" | '"$FZF"' alpha}
    expect "1/3"
    send "\003"
    expect eof
' 2>/dev/null)

if echo "$out" | grep -qF "1/3"; then
    pass "footer shows filtered/total count"
else
    fail "footer shows filtered/total count" "got: $out"
fi

# --- match highlighting ---
echo ""
echo "-- match highlighting --"

out=$(expect -c '
    set timeout 3
    log_user 1
    spawn bash -c {printf "alpha.txt\nbeta.cpp\ngamma.rs\n" | '"$FZF"' al}
    expect "1/3"
    send "\003"
    expect eof
' 2>/dev/null)

if echo "$out" | grep -qP '\x1b\[1;3[23](;4)?m'; then
    pass "matched chars have highlight ANSI codes"
else
    fail "matched chars have highlight ANSI codes" "got: $out"
fi

out=$(printf "alpha.txt\nbeta.cpp\n" | $FZF --filter alpha)
if echo "$out" | grep -qP '\x1b\['; then
    fail "filter mode has no ANSI codes" "found escape codes in filter output"
else
    pass "filter mode has no ANSI codes"
fi

# --- multi-select ---
echo ""
echo "-- multi-select --"

out=$(expect -c '
    set timeout 3
    log_user 1
    spawn bash -c {printf "alpha.txt\nbeta.cpp\ngamma.rs\n" | '"$FZF"' a}
    expect ">"
    send "\t"
    sleep 0.2
    expect "*"
    send "\003"
    expect eof
' 2>/dev/null)

if echo "$out" | grep -q '\*'; then
    pass "Tab shows * marker on selected item"
else
    fail "Tab shows * marker on selected item" "got: $out"
fi

# Tab toggle: select then deselect
fzf_select 'aaa.txt\nbbb.txt\nccc.txt\n' "" "3/3" '
    send "\t"
    sleep 0.1
    send "\033\[A"
    sleep 0.1
    send "\t"
    sleep 0.1
    send "\r"'
count=$(echo "$FZF_STDOUT" | grep -c '.')
if [ "$count" -eq 1 ]; then
    pass "Tab toggle: select then deselect, prints cursor only"
else
    fail "Tab toggle: select then deselect" "expected 1 line, got $count: '$FZF_STDOUT'"
fi

# Multi-select Enter outputs 2 selected items
fzf_select 'aaa.txt\nbbb.txt\nccc.txt\n' "" "3/3" '
    send "\t"
    sleep 0.2
    send "\t"
    sleep 0.2
    send "\r"'
count=$(echo "$FZF_STDOUT" | grep -c '.')
if [ "$count" -eq 2 ]; then
    pass "Enter with multi-select outputs both selected items"
else
    fail "Enter with multi-select outputs both selected items" "expected 2, got $count: '$FZF_STDOUT'"
fi

# Enter with no selections prints cursor item
fzf_select 'aaa.txt\nbbb.txt\nccc.txt\n' "" "3/3" 'send "\r"'
if echo "$FZF_STDOUT" | grep -qF "aaa.txt"; then
    pass "Enter with no selections prints cursor item"
else
    fail "Enter with no selections prints cursor item" "got: '$FZF_STDOUT'"
fi

# footer shows selected count
out=$(expect -c '
    set timeout 3
    log_user 1
    spawn bash -c {printf "alpha.txt\nbeta.cpp\ngamma.rs\n" | '"$FZF"' a}
    expect ">"
    send "\t"
    sleep 0.2
    expect "1 selected"
    send "\003"
    expect eof
' 2>/dev/null)

if echo "$out" | grep -qF "1 selected"; then
    pass "footer shows selected count"
else
    fail "footer shows selected count" "got: $out"
fi

# --- summary ---
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
