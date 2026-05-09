# cppfzf: minimal multicore fuzzy finder with TUI

A single-file C++17 fuzzy file finder with an interactive terminal UI.
No external dependencies -- builds with only a C++ compiler and pthreads.
Uses ANSI escape codes for the TUI, no ncurses required.

## Build

```
g++ -O2 -std=c++17 -pthread fzf.cpp -o fzf
```

Or with separate compile and link:

```
g++ -O2 -std=c++17 -pthread -c fzf.cpp -o obj/fzf.o
g++ -O2 -std=c++17 -pthread obj/fzf.o -o bin/fzf
```

## Usage

```
fzf [query] [path]                              # built-in directory walker
find . -type f -name "*.cpp" | fzf [query]      # piped input
FZF_DEFAULT_COMMAND="find . -type f" fzf [query] # env var
```

The query argument is optional -- if omitted, all items are shown and you
can type to filter interactively.

### Input modes (in priority order)

1. **Piped stdin** -- if stdin is a pipe, fzf reads one path per line from
   it. Keyboard input for the TUI is rerouted to `/dev/tty` so the two
   streams don't conflict.
2. **`FZF_DEFAULT_COMMAND`** -- if the env var is set and stdin is a
   terminal, fzf runs the command via `popen()` and reads its output.
3. **Built-in walker** -- falls back to
   `std::filesystem::recursive_directory_iterator` starting at `[path]`
   (default `.`).

### TUI controls

| Key              | Action                          |
|------------------|---------------------------------|
| Type any char    | Append to query, re-filter      |
| Backspace        | Delete last char, re-filter     |
| Ctrl-u           | Clear query                     |
| Ctrl-n / Ctrl-j / Down | Move selection down        |
| Ctrl-p / Ctrl-k / Up   | Move selection up          |
| Tab              | Toggle multi-select on item     |
| Enter            | Print selected path(s) and exit |
| Ctrl-c / Esc     | Quit without printing           |

### Live typing

The query is editable in the TUI header. Typing narrows the results in
real-time. The footer shows `filtered/total` count (e.g., `12/350`).

### Match highlighting

Matched characters in each result are highlighted -- bold green for
normal items, bold yellow with underline for the cursor item.

### Multi-select

Press Tab to toggle selection on the current item (marked with `*`).
Tab also advances the cursor down. On Enter:

- If any items are Tab-selected, all of them are printed (one per line).
- If none are selected, only the cursor item is printed.

This composes with other tools:

```
vim $(fzf)
```

### Filter mode

`--filter` skips the TUI and prints sorted results to stdout. Useful for
scripts, testing, and non-interactive environments:

```
fzf --filter query
find . -type f | fzf --filter query
```

## Testing

```
./test_all.sh         # runs all test suites
./test.sh             # non-interactive tests (no dependencies)
./test_tui.sh         # TUI tests (requires expect)
```

## Architecture

```
main thread (producer)          N worker threads (consumers)
        |                               |
  walk tree / read stdin          pop path from queue
        |                         collect into PathList
  push paths onto BQueue                |
        |                               |
        +--- q.close() -----------------+
        |
  filter_paths(query, all_paths)  <- called on each keystroke
        |
   run_tui() displays filtered results
```

- **BQueue** -- bounded concurrent queue (capacity 1024) with
  `std::condition_variable`. Prevents the producer from running away
  with memory on huge trees.
- **PathList** -- thread-safe vector that workers push paths into.
  After all workers join, the full list is available for filtering.
- **filter_paths** -- scores and sorts all paths against the current
  query. Called on every keystroke in TUI mode, or once in filter mode.
- **TUI** -- enters the alternate screen buffer, draws with ANSI escape
  codes, reads keys from `tty_fd` (either stdin or `/dev/tty`).
  Selection goes to stdout; all drawing goes to stderr.

## Fuzzy scoring

Walk the query left-to-right through the candidate string. For each
query char, find the next case-insensitive match. Scoring:

- **+16** match at start of string or after `/`, `_`, `-`, `.`, space
- **+8** camelCase boundary (uppercase after lowercase)
- **+4** consecutive match (immediately follows previous match)
- **-1** per skipped character (gap penalty)
- **NO_MATCH** if any query char can't be matched in order

Filenames are scored first; if no match, the full path is tried.

## Skip list

These directories are skipped during the built-in walk:
`.git`, `node_modules`, `target`, `build`, `.venv`, `__pycache__`,
`.cache`, `dist`, `.idea`, `.vscode`.

Not used when input comes from a pipe or `FZF_DEFAULT_COMMAND` -- the
external command controls what paths are fed in.
