# mygrep: minimal multicore fuzzy find + grep

A ~150-line standard C++17 tool that emulates the core of `fd | fzf` and
`ripgrep` with no external dependencies. Builds with only a C++ compiler
and pthreads.

## Build

```
g++ -O2 -std=c++17 -pthread mygrep.cpp -o mygrep
```

## Usage

```
mygrep --files <query> [path] # fd-mode: print matching file paths
mygrep <query> [path] # rg-mode: print matching lines in files whose paths fuzzy-match query
```

## Architecture

One producer walks the tree with
`std::filesystem::recursive_directory_iterator` and pushes paths onto a
bounded queue. N consumers (= `std::thread::hardware_concurrency()`) pop
paths, score them against the fuzzy query, and if the score clears the
threshold, either print the path (fd-mode) or scan the file's lines for the
pattern (rg-mode). A mutex around `std::cout` keeps output sane.

## Fuzzy scoring (fzf-lite)

Walk the query left-to-right through the candidate string. For each query
char, find the next case-insensitive match. Score = sum of per-match
bonuses:

- +16 if match follows `/`, `_`, `-`, `.`, or space (word boundary)
- +8 if match is uppercase following lowercase (camelCase)
- +4 if match is consecutive with the previous match
- -1 per skipped char (gap penalty)
- return -1 (reject) if any query char can't be matched in order

Not fzf-perfect but good enough you won't notice in daily use.

## Critical performance bits

1. **Single producer, many consumers.** The walk is I/O bound and doesn't
parallelize well on most filesystems anyway; parallelism pays off on the
scoring/grepping side.
2. **Bounded queue** (1024 entries) with `std::condition_variable` —
prevents the walker from running away with memory on huge trees.
3. **Binary skip**: read file, if first 8KB contains a NUL byte, skip.
Cheap and catches ~all binaries.
4. **Skip directory list** covers the 90% case: `.git`, `node_modules`,
`target`, `build`, `.venv`, `__pycache__`, `.cache`, `dist`, `.idea`,
`.vscode`. Extend as needed.
5. **No regex**, just case-insensitive substring search for content.
`std::regex` is standard but slow — live without it.

## What was deliberately cut

- No `mmap` — `std::ifstream` keeps it pure standard C++. Roughly 2-3x
slower on content search than mmap but still fast. If you want to add it
later, it's one `#include <sys/mman.h>` and three calls on POSIX.
- No full `.gitignore` parsing — just the skip-list above. Full gitignore
semantics are a rabbit hole.
- No colored output, no `--type` filters, no context lines (`-A/-B`), no
`--hidden`.
- No regex engine. Substring only.

## Extension points

If you want to grow this, in order of bang-for-buck:

1. **mmap for content search** — biggest single speedup for rg-mode.
2. **Root `.gitignore` parsing** — a simple glob matcher over literal and
`*` patterns covers most real-world `.gitignore` files.
3. **Score threshold + top-N** — right now any non-negative score prints;
add `--min-score` or keep a top-heap for best matches only.
4. **Regex** — wrap `std::regex` behind a `-E` flag. Know that it's slow.
5. **Hidden files flag** — currently descends into them; add
`--hidden`/`--no-hidden`.

## Why this stays small

The whole thing is: bounded queue (25 lines), scorer (30 lines), worker
loop (35 lines), main/walker (40 lines), plus helpers. Every feature beyond
this doubles the surface area. Start here, add only what you actually miss
after a week of use.
