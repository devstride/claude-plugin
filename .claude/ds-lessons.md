# Lessons — distilled review findings

<!-- Written ONLY by devstride:review at settle time. Read-only everywhere else.
     Format + curation rules: the devstride:review skill's references/lessons-format.md -->

Next-ID: 3

## L-001 · Free-text git subjects classified by loose words

class: repeat · recurrences: 1 · first-seen: 2026-11-09 · last-seen: 2026-11-09
sources: review settle (honest-estimates, six cycles)

- **Pattern:** a script decides how to treat a commit (absorb, delivery, sync) from a
  hand-written or git-generated subject with word or regex tests (`\bword`, `.* into .*`,
  "mentions X anywhere"), and accepts on the first positive match.
- **Why:** subjects carry branch names, slugs and side clauses; each tightening leaves another
  bypass (a word inside `absorb-retries`, a later `into`, git's own `Merge commit '<sha>' into
  <branch>`), and nothing goes red.
- **Avoid:** check the strongest negative evidence first (a subject naming the destination you
  must never accept), then accept only fixed prescribed forms plus structural checks; give every
  alternative a fixture and a mutation that fails it.

## L-002 · Tests swap shared state that detached processes still use

class: general · recurrences: 1 · first-seen: 2026-11-09 · last-seen: 2026-11-09
sources: review settle (unwritable-directory tests, two cycles)

- **Pattern:** a test case moves, deletes, chmods or replaces a directory or file (`mv x x.away`,
  `rm` then restore) that keepers, watchers or other detached processes started by earlier cases
  still read or recreate.
- **Why:** each case passes alone and the swap window is milliseconds, so it only fails
  intermittently, often in a later case, and reads as a flaky test.
- **Avoid:** give the case its own isolated copy (its own cache or `XDG_*` root, its own repo)
  instead of altering shared state, and assert nothing was written beside the placeholder.
