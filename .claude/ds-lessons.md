# Lessons — distilled review findings

<!-- Written ONLY by devstride:review at settle time. Read-only everywhere else.
     Format + curation rules: the devstride:review skill's references/lessons-format.md -->

Next-ID: 6

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

## L-002 · Tests share state with detached processes from other cases

class: general · recurrences: 2 · first-seen: 2026-11-09 · last-seen: 2026-11-09
sources: review settle (unwritable-directory tests; keepers left beating into a shared log)

- **Pattern:** a test case moves, deletes, chmods or replaces a directory or file (`mv x x.away`,
  `rm` then restore) that keepers, watchers or other detached processes started by earlier cases
  still read or recreate; or a case ends with such a process still running that writes to a log
  or file later cases count.
- **Why:** each case passes alone and the swap window is milliseconds, so it only fails
  intermittently, often in a later case, and reads as a flaky test.
- **Avoid:** give the case its own isolated copy (its own cache or `XDG_*` root, its own repo)
  instead of altering shared state; stop every process a case started before the case ends; and
  count only the case's own entries in anything shared.

## L-003 · Test fake accepts what the real service refuses

class: general · recurrences: 1 · first-seen: 2026-11-09 · last-seen: 2026-11-09
sources: review settle (a record field sent as a remote claim payload under a reserved key)

- **Pattern:** a client starts sending a new field (or a whole local record) to a remote API,
  and the only test is a repository fake (`scripts/tests/fixtures/**/fake-*.py`) that stores any
  shape it is given.
- **Why:** the fake is more permissive than the server's request schema, so every case passes
  while every real call is refused; nothing goes red until production.
- **Avoid:** read the real server's request schema for each field the client now sends; make the
  fake refuse what the server refuses, and prove the old code fails against it.

## L-004 · Timer-driven background job with no in-flight guard

class: general · recurrences: 1 · first-seen: 2026-11-09 · last-seen: 2026-11-09
sources: review settle (status-line name refresh re-spawned on every stale redraw)

- **Pattern:** a redraw or tick spawns a detached refresh when a cache is older than N seconds
  (`touch cache; (refresh &)`), with no lock or live-pid check, around a command that can run
  longer than N or hang.
- **Why:** each run passes alone; a slow or hung command adds one more process every N seconds,
  and concurrent writers share one temp file.
- **Avoid:** hold one lock per key recording the refresher's pid; skip while it lives, take over
  only a dead one; write through `mktemp`; prove it with a hanging-command case that kills what it starts.

## L-005 · Grep consistency check passes on the wrong text or on nothing

class: repeat · recurrences: 1 · first-seen: 2026-11-09 · last-seen: 2026-11-09
sources: review settle (shipped-default test: shape-target rows and the no-override guard)

- **Pattern:** a `scripts/tests/*.sh` check extracts a section with `awk` and greps it for words:
  the words also occur in nearby prose, not only in the rows it claims to guard; a negative check
  (`if grep …; then bad; else ok`) runs on an extraction that can be empty; or a denylist names
  only one vocabulary for the thing it forbids.
- **Why:** each passes on today's tree, and deleting the guarded rows, renaming the heading or
  using the other name still leaves it green, so nothing ever fails.
- **Avoid:** match the structure itself (an anchored table row with its cells); fail when an
  extraction is empty; check the real vocabulary source (registry keys, the knob table); and prove
  each check with a mutation that must turn it red.
