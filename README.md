# fzf: minimal multicore fuzzy finder with TUI

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
fzf <query> [path]                          # built-in directory walker
find . -type f -name "*.cpp" | fzf query    # piped input
FZF_DEFAULT_COMMAND="find . -type f" fzf query  # env var
```

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
| Up / k           | Move selection up               |
| Down / j         | Move selection down             |
| Enter            | Print selected path and exit    |
| q / Esc          | Quit without printing           |

The selected path is printed to stdout, so it composes with other tools:

```
vim $(fzf query)
```

## Architecture

```
main thread (producer)          N worker threads (consumers)
        |                               |
  walk tree / read stdin          pop path from queue
        |                         score against query
  push paths onto BQueue          store in MatchResults
        |                               |
        +--- q.close() -----------------+
        |
   run_tui() reads sorted MatchResults
```

- **BQueue** -- bounded concurrent queue (capacity 1024) with
  `std::condition_variable`. Prevents the producer from running away
  with memory on huge trees.
- **MatchResults** -- thread-safe vector that workers insert into
  concurrently. After all workers join, `sorted()` returns a copy
  ordered by score descending.
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
- **-1 (reject)** if any query char can't be matched in order

Filenames are scored first; if no match, the full path is tried.

## Skip list

These directories are skipped during the built-in walk:
`.git`, `node_modules`, `target`, `build`, `.venv`, `__pycache__`,
`.cache`, `dist`, `.idea`, `.vscode`.

Not used when input comes from a pipe or `FZF_DEFAULT_COMMAND` -- the
external command controls what paths are fed in.
