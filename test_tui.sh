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

# --- Test 1: select first item with Enter ---
echo "-- navigation and selection --"

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

# --- Test 2: press down then enter selects second item ---
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
    pass "down+enter selects second item"
else
    fail "down+enter selects second item" "got: $(echo "$out" | tail -1)"
fi

# --- Test 3: down down enter selects third item ---
out=$(expect -c '
    set timeout 3
    spawn bash -c {printf "alpha.txt\nbeta.cpp\ngamma.rs\n" | '"$FZF"' test}
    expect "3 matches"
    send "\033\[B"
    sleep 0.1
    send "\033\[B"
    sleep 0.1
    send "\r"
    expect eof
' 2>/dev/null)

if echo "$out" | grep -qF "gamma.rs"; then
    pass "down+down+enter selects third item"
else
    fail "down+down+enter selects third item" "got: $(echo "$out" | tail -1)"
fi

# --- Test 4: j key navigates down (vim binding) ---
out=$(expect -c '
    set timeout 3
    spawn bash -c {printf "alpha.txt\nbeta.cpp\ngamma.rs\n" | '"$FZF"' test}
    expect "3 matches"
    send "j"
    sleep 0.1
    send "\r"
    expect eof
' 2>/dev/null)

if echo "$out" | grep -qF "beta.cpp"; then
    pass "j key navigates down"
else
    fail "j key navigates down" "got: $(echo "$out" | tail -1)"
fi

# --- Test 5: k key navigates up (vim binding) ---
out=$(expect -c '
    set timeout 3
    spawn bash -c {printf "alpha.txt\nbeta.cpp\ngamma.rs\n" | '"$FZF"' test}
    expect "3 matches"
    send "j"
    sleep 0.1
    send "j"
    sleep 0.1
    send "k"
    sleep 0.1
    send "\r"
    expect eof
' 2>/dev/null)

if echo "$out" | grep -qF "beta.cpp"; then
    pass "k key navigates up"
else
    fail "k key navigates up" "got: $(echo "$out" | tail -1)"
fi

# --- Test 6: up arrow at top stays at top ---
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

# --- Test 7: down at bottom stays at bottom ---
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

# --- Test 8: q quits without output ---
echo ""
echo "-- quit behavior --"

# capture only stdout (fd 1) from the spawned fzf, not expect's own output
stdout_file=$(mktemp)
expect -c '
    set timeout 3
    log_user 0
    spawn bash -c {printf "alpha.txt\nbeta.cpp\n" | '"$FZF"' a > '"$stdout_file"'}
    expect "2 matches"
    send "q"
    expect eof
' 2>/dev/null
out=$(cat "$stdout_file")
rm -f "$stdout_file"

if [ -z "$out" ]; then
    pass "q quits without printing selection"
else
    fail "q quits without printing selection" "got: $out"
fi

# --- Test 9: TUI shows match count ---
echo ""
echo "-- display --"

out=$(expect -c '
    set timeout 3
    log_user 1
    spawn bash -c {printf "aa\nab\nac\nad\nae\n" | '"$FZF"' a}
    expect "5 matches"
    send "q"
    expect eof
' 2>/dev/null)

if echo "$out" | grep -qF "5 matches"; then
    pass "footer shows correct match count"
else
    fail "footer shows correct match count" "got: $out"
fi

# --- Test 10: TUI shows the query in header ---
out=$(expect -c '
    set timeout 3
    log_user 1
    spawn bash -c {printf "alpha.txt\nbeta.cpp\n" | '"$FZF"' myquery}
    expect "fzf > myquery"
    send "q"
    expect eof
' 2>/dev/null)

if echo "$out" | grep -qF "myquery"; then
    pass "header shows query string"
else
    fail "header shows query string" "got: $out"
fi

# --- Test 11: selected item has > marker ---
out=$(expect -c '
    set timeout 3
    log_user 1
    spawn bash -c {printf "alpha.txt\nbeta.cpp\n" | '"$FZF"' a}
    expect "> "
    send "q"
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
