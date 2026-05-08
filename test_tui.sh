#!/bin/bash
# TUI tests using expect. Requires: expect
# These test the interactive terminal UI behavior.
# For non-interactive tests that work without expect, use test.sh

FZF="./bin/fzf"
PASS=0
FAIL=0

pass() { echo "  PASS: $1"; ((PASS++)); }
fail() { echo "  FAIL: $1 -- $2"; ((FAIL++)); }

echo "=== fzf TUI test suite (expect) ==="
echo ""

# --- arrow key navigation ---
echo "-- arrow key navigation --"

out=$(expect -c '
    set timeout 3
    spawn bash -c {printf "alpha.txt\nbeta.cpp\ngamma.rs\n" | '"$FZF"' test}
    expect "3 matches"
    send "\r"
    expect eof
' 2>/dev/null)

if echo "$out" | grep -qF "alpha.txt"; then
    pass "enter selects first item"
else
    fail "enter selects first item" "got: $(echo "$out" | tail -1)"
fi

out=$(expect -c '
    set timeout 3
    spawn bash -c {printf "alpha.txt\nbeta.cpp\ngamma.rs\n" | '"$FZF"' test}
    expect "3 matches"
    send "\033\[B"
    sleep 0.1
    send "\r"
    expect eof
' 2>/dev/null)

if echo "$out" | grep -qF "beta.cpp"; then
    pass "down arrow selects second item"
else
    fail "down arrow selects second item" "got: $(echo "$out" | tail -1)"
fi

out=$(expect -c '
    set timeout 3
    spawn bash -c {printf "alpha.txt\nbeta.cpp\ngamma.rs\n" | '"$FZF"' test}
    expect "3 matches"
    send "\033\[B"
    sleep 0.1
    send "\033\[B"
    sleep 0.1
    send "\033\[A"
    sleep 0.1
    send "\r"
    expect eof
' 2>/dev/null)

if echo "$out" | grep -qF "beta.cpp"; then
    pass "up arrow goes back up"
else
    fail "up arrow goes back up" "got: $(echo "$out" | tail -1)"
fi

# --- Ctrl-n / Ctrl-p navigation ---
echo ""
echo "-- Ctrl-n / Ctrl-p navigation --"

out=$(expect -c '
    set timeout 3
    spawn bash -c {printf "alpha.txt\nbeta.cpp\ngamma.rs\n" | '"$FZF"' test}
    expect "3 matches"
    send "\016"
    sleep 0.1
    send "\r"
    expect eof
' 2>/dev/null)

if echo "$out" | grep -qF "beta.cpp"; then
    pass "Ctrl-n moves down"
else
    fail "Ctrl-n moves down" "got: $(echo "$out" | tail -1)"
fi

out=$(expect -c '
    set timeout 3
    spawn bash -c {printf "alpha.txt\nbeta.cpp\ngamma.rs\n" | '"$FZF"' test}
    expect "3 matches"
    send "\016"
    sleep 0.1
    send "\016"
    sleep 0.1
    send "\020"
    sleep 0.1
    send "\r"
    expect eof
' 2>/dev/null)

if echo "$out" | grep -qF "beta.cpp"; then
    pass "Ctrl-p moves up"
else
    fail "Ctrl-p moves up" "got: $(echo "$out" | tail -1)"
fi

# --- Ctrl-j / Ctrl-k navigation ---
echo ""
echo "-- Ctrl-j / Ctrl-k navigation --"

out=$(expect -c '
    set timeout 3
    spawn bash -c {printf "alpha.txt\nbeta.cpp\ngamma.rs\n" | '"$FZF"' test}
    expect "3 matches"
    send "\012"
    sleep 0.1
    send "\r"
    expect eof
' 2>/dev/null)

if echo "$out" | grep -qF "beta.cpp"; then
    pass "Ctrl-j moves down"
else
    fail "Ctrl-j moves down" "got: $(echo "$out" | tail -1)"
fi

out=$(expect -c '
    set timeout 3
    spawn bash -c {printf "alpha.txt\nbeta.cpp\ngamma.rs\n" | '"$FZF"' test}
    expect "3 matches"
    send "\012"
    sleep 0.1
    send "\012"
    sleep 0.1
    send "\013"
    sleep 0.1
    send "\r"
    expect eof
' 2>/dev/null)

if echo "$out" | grep -qF "beta.cpp"; then
    pass "Ctrl-k moves up"
else
    fail "Ctrl-k moves up" "got: $(echo "$out" | tail -1)"
fi

# --- boundary behavior ---
echo ""
echo "-- boundary behavior --"

out=$(expect -c '
    set timeout 3
    spawn bash -c {printf "alpha.txt\nbeta.cpp\ngamma.rs\n" | '"$FZF"' test}
    expect "3 matches"
    send "\033\[A"
    sleep 0.1
    send "\033\[A"
    sleep 0.1
    send "\r"
    expect eof
' 2>/dev/null)

if echo "$out" | grep -qF "alpha.txt"; then
    pass "up at top stays at first item"
else
    fail "up at top stays at first item" "got: $(echo "$out" | tail -1)"
fi

out=$(expect -c '
    set timeout 3
    spawn bash -c {printf "alpha.txt\nbeta.cpp\ngamma.rs\n" | '"$FZF"' test}
    expect "3 matches"
    send "\033\[B"
    sleep 0.1
    send "\033\[B"
    sleep 0.1
    send "\033\[B"
    sleep 0.1
    send "\033\[B"
    sleep 0.1
    send "\r"
    expect eof
' 2>/dev/null)

if echo "$out" | grep -qF "gamma.rs"; then
    pass "down at bottom stays at last item"
else
    fail "down at bottom stays at last item" "got: $(echo "$out" | tail -1)"
fi

# --- quit behavior ---
echo ""
echo "-- quit behavior --"

stdout_file=$(mktemp)
expect -c '
    set timeout 3
    log_user 0
    spawn bash -c {printf "alpha.txt\nbeta.cpp\n" | '"$FZF"' a > '"$stdout_file"'}
    expect "2 matches"
    send "\003"
    expect eof
' 2>/dev/null
out=$(cat "$stdout_file")
rm -f "$stdout_file"

if [ -z "$out" ]; then
    pass "Ctrl-c quits without printing selection"
else
    fail "Ctrl-c quits without printing selection" "got: $out"
fi

stdout_file=$(mktemp)
expect -c '
    set timeout 3
    log_user 0
    spawn bash -c {printf "alpha.txt\nbeta.cpp\n" | '"$FZF"' a > '"$stdout_file"'}
    expect "2 matches"
    send "\033"
    expect eof
' 2>/dev/null
out=$(cat "$stdout_file")
rm -f "$stdout_file"

if [ -z "$out" ]; then
    pass "Esc quits without printing selection"
else
    fail "Esc quits without printing selection" "got: $out"
fi

# --- display ---
echo ""
echo "-- display --"

out=$(expect -c '
    set timeout 3
    log_user 1
    spawn bash -c {printf "aa\nab\nac\nad\nae\n" | '"$FZF"' a}
    expect "5 matches"
    send "\003"
    expect eof
' 2>/dev/null)

if echo "$out" | grep -qF "5 matches"; then
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

# --- summary ---
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
