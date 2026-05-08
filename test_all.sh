#!/bin/bash
# Runs all test suites. TUI tests are skipped if expect is not installed.

DIR="$(cd "$(dirname "$0")" && pwd)"
EXIT=0

echo "==============================="
echo "  fzf full test suite"
echo "==============================="
echo ""

# --- non-interactive tests (always run) ---
echo ">>> Running test.sh (non-interactive) ..."
echo ""
if "$DIR/test.sh"; then
    echo ""
else
    EXIT=1
    echo ""
fi

# --- TUI tests (only if expect is available) ---
if command -v expect &>/dev/null; then
    echo ">>> Running test_tui.sh (expect TUI tests) ..."
    echo ""
    if "$DIR/test_tui.sh"; then
        echo ""
    else
        EXIT=1
        echo ""
    fi
else
    echo ">>> Skipping test_tui.sh (expect not installed)"
    echo ""
fi

echo "==============================="
if [ "$EXIT" -eq 0 ]; then
    echo "  ALL SUITES PASSED"
else
    echo "  SOME TESTS FAILED"
fi
echo "==============================="
exit $EXIT
