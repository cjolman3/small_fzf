#!/bin/bash

FZF="./bin/fzf"
PASS=0
FAIL=0
TMPDIR=$(mktemp -d)

cleanup() { rm -rf "$TMPDIR"; }
trap cleanup EXIT

# --- helpers ---
pass() { echo "  PASS: $1"; ((PASS++)); }
fail() { echo "  FAIL: $1 -- $2"; ((FAIL++)); }

run_test() {
    local name="$1"
    local expected="$2"
    local actual="$3"

    if echo "$actual" | grep -qF "$expected"; then
        pass "$name"
    else
        fail "$name" "expected '$expected' in output, got '$actual'"
    fi
}

run_test_absent() {
    local name="$1"
    local absent="$2"
    local actual="$3"

    if echo "$actual" | grep -qF "$absent"; then
        fail "$name" "'$absent' should not appear in output"
    else
        pass "$name"
    fi
}

run_test_empty() {
    local name="$1"
    local actual="$2"

    if [ -z "$actual" ]; then
        pass "$name"
    else
        fail "$name" "expected empty output, got '$actual'"
    fi
}

run_test_line_count() {
    local name="$1"
    local expected_count="$2"
    local actual="$3"

    local count
    if [ -z "$actual" ]; then
        count=0
    else
        count=$(echo "$actual" | wc -l)
    fi

    if [ "$count" -eq "$expected_count" ]; then
        pass "$name"
    else
        fail "$name" "expected $expected_count lines, got $count"
    fi
}

# --- setup test fixtures ---
mkdir -p "$TMPDIR/src/utils"
mkdir -p "$TMPDIR/docs"
echo "int main() {}" > "$TMPDIR/src/main.cpp"
echo "void helper() {}" > "$TMPDIR/src/utils/helper.cpp"
echo "# readme" > "$TMPDIR/docs/readme.md"
echo "config" > "$TMPDIR/config.yaml"
echo "data" > "$TMPDIR/data.json"

echo "=== fzf test suite ==="
echo ""

# --- built-in walker via find pipe (simulates walker behavior) ---
echo "-- walker simulation (find | fzf) --"

out=$(find "$TMPDIR" -type f | $FZF --filter main)
run_test "walker: finds main.cpp" "main.cpp" "$out"

out=$(find "$TMPDIR" -type f | $FZF --filter helper)
run_test "walker: finds helper.cpp" "helper.cpp" "$out"

out=$(find "$TMPDIR" -type f | $FZF --filter yaml)
run_test "walker: finds config.yaml" "config.yaml" "$out"

out=$(find "$TMPDIR" -type f | $FZF --filter readme)
run_test "walker: finds readme.md" "readme.md" "$out"

out=$(find "$TMPDIR" -type f | $FZF --filter zzzznothing 2>/dev/null || true)
run_test_empty "walker: no match returns empty" "$out"

# --- pipe mode tests ---
echo ""
echo "-- pipe mode --"

out=$(printf "foo.txt\nbar.cpp\nbaz.rs\n" | $FZF --filter bar)
run_test "pipe: finds bar.cpp" "bar.cpp" "$out"

out=$(printf "foo.txt\nbar.cpp\nbaz.rs\n" | $FZF --filter foo)
run_test "pipe: finds foo.txt" "foo.txt" "$out"

out=$(printf "foo.txt\nbar.cpp\nbaz.rs\n" | $FZF --filter zzz 2>/dev/null || true)
run_test_empty "pipe: no match returns empty" "$out"

out=$(printf "alpha.txt\nalpha_beta.txt\nalpha_beta_gamma.txt\n" | $FZF --filter alpha)
run_test "pipe: multiple matches all returned" "alpha.txt" "$out"
run_test_line_count "pipe: all 3 alpha matches returned" 3 "$out"

# pipe with no query -- everything should pass through
out=$(printf "aaa\nbbb\nccc\n" | $FZF --filter)
run_test "pipe: no query returns all items (aaa)" "aaa" "$out"
run_test "pipe: no query returns all items (bbb)" "bbb" "$out"
run_test "pipe: no query returns all items (ccc)" "ccc" "$out"
run_test_line_count "pipe: no query returns exactly 3 items" 3 "$out"

# --- FZF_DEFAULT_COMMAND tests ---
echo ""
echo "-- FZF_DEFAULT_COMMAND mode --"

# note: in environments where stdin is not a tty (CI, sandboxes), these
# will fall through to pipe mode with empty stdin, so the env command
# may not fire. We test via pipe to cover the scoring logic either way.
out=$(printf "%s\n" "$TMPDIR/src/main.cpp" "$TMPDIR/src/utils/helper.cpp" "$TMPDIR/docs/readme.md" | $FZF --filter main)
run_test "env cmd sim: finds main.cpp" "main.cpp" "$out"

out=$(printf "%s\n" "$TMPDIR/src/main.cpp" "$TMPDIR/src/utils/helper.cpp" "$TMPDIR/docs/readme.md" | $FZF --filter helper)
run_test "env cmd sim: finds helper.cpp" "helper.cpp" "$out"

# --- scoring tests ---
echo ""
echo "-- scoring / sort order --"

out=$(printf "xmainx\nmain.cpp\nsome/deep/main.h\n" | $FZF --filter main | head -1)
run_test "score: exact filename match ranked first" "main.cpp" "$out"

out=$(printf "src/foo_bar.cpp\nsrc/fooXbar.cpp\n" | $FZF --filter fb | head -1)
run_test "score: word boundary match beats mid-word" "foo_bar" "$out"

out=$(printf "a_b_c.txt\nabc.txt\na__b__c.txt\n" | $FZF --filter abc | head -1)
run_test "score: exact stem match ranked first" "abc.txt" "$out"

out=$(printf "xa_b_c.txt\nxabc.txt\nxa__b__c.txt\n" | $FZF --filter abc | head -1)
run_test "score: word boundary beats consecutive (no exact stem)" "xa_b_c.txt" "$out"

# --- edge cases ---
echo ""
echo "-- edge cases --"

out=$(printf "UPPER.TXT\nupper.txt\n" | $FZF --filter upper)
run_test_line_count "case insensitive: both match" 2 "$out"

out=$(printf "  \n\n\nreal.txt\n" | $FZF --filter real)
run_test "empty lines: skipped, real match found" "real.txt" "$out"

out=$(printf "a\nb\nc\nd\ne\nf\ng\nh\ni\nj\n" | $FZF --filter a)
run_test_line_count "single char query: matches only 'a'" 1 "$out"

out=$(printf "file.txt\n" | $FZF --filter file.txt)
run_test "query with dot: matches file.txt" "file.txt" "$out"

# --- summary ---
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
