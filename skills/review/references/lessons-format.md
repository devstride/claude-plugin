# Lessons store — format and curation rules (CANONICAL)

The single authoritative statement of the per-repo lessons store's file format, size policy,
and curation bar. The store itself lives at the path named by the repo config key `lessonsDoc`
(inline fallback: `.claude/ds-lessons.md`). The WRITER (`review`, at settle time) and every
CONSUMER (`ultracode-build`'s build context and finder lenses; `review`'s dedup guard)
cite this file rather than restating it — one canonical definition, zero sync obligations.

## What the store is

Review findings that represent a **repeatable class** of mistake, distilled so the build engine
reads them BEFORE writing code and the review engines consult them WHILE triaging. It is curated
knowledge, not a findings log: small, high-signal, and bounded.

## File format

The lessons file opens with exactly this header shape:

```markdown
# Lessons — distilled review findings

<!-- Written ONLY by devstride:review at settle time. Read-only everywhere else.
     Format + curation rules: the devstride:review skill's references/lessons-format.md -->

Next-ID: 4
```

- **`Next-ID` is the ID authority.** It only ever increments. Eviction can remove the
  highest-numbered lesson, so "max existing ID + 1" would silently reuse an ID; the counter
  makes reuse impossible by construction. Evicted IDs are retired forever.
- The `Next-ID: 4` above is an ILLUSTRATIVE value (pairing with the sample `L-003` below) —
  **a freshly created file starts at `Next-ID: 1`**.
- **Concurrent-branch allocation**: two branches settling from the same base can mint the same
  `L-NNN`. The MERGE RESOLVER's rule is: keep BOTH lessons' content (never drop a lesson to
  resolve a conflict); the lesson from the branch merging IN keeps its content but is
  re-minted with a fresh ID from the post-merge `Next-ID` (set to max(both counters), then
  incremented per re-mint); if the two collided lessons match each other's Pattern, they are
  the SAME class — merge into one entry (earliest `first-seen`, latest `last-seen`, summed
  `recurrences`) under the lower ID and retire the higher.

Each lesson is one entry, **one lesson per finding CLASS — never per finding instance**:

```markdown
## L-003 · Unanchored match gates behavior

class: common · recurrences: 2 · first-seen: 2026-08-01 · last-seen: 2026-08-15
sources: review settle (optional one-liner)

- **Pattern:** a bare substring/regex test (`includes`, unanchored grep) decides a branch,
  matching far more than intended with no error.
- **Why:** the over-match is silent — extra or wrong work happens and nothing goes red, so it
  survives review unless a finder looks for it specifically.
- **Avoid:** anchor to the meaning (`^prefix/`, `\b` word boundaries, exact keys); prefer the
  field naming the specific event over a set that merely contains it.
```

- **Stable ID**: `L-` + zero-padded 3-digit number from `Next-ID`. Never reused, never
  renumbered. Recurrences UPDATE the existing entry (bump `recurrences`, refresh `last-seen`)
  rather than minting a duplicate.
- **Merge-vs-mint (the sameness test)**: a new finding is a RECURRENCE of an existing lesson
  when it exhibits the same mistake mechanism the lesson's **Pattern** bullet describes — the
  Pattern IS the equivalence test, which is why it must be written in code/diff terms a finder
  can match. Matches a Pattern → update that lesson; matches none → a candidate for minting
  (subject to the curation bar).
- **`class` is fixed at mint and never changes.** It records how the lesson qualified at the
  curation bar: `repeat` (the class had already been seen in a prior cycle when first minted),
  `general` (a repo-wide pattern applicable beyond the file it was found in), `common` (a
  well-known trap class — unanchored matches, swallowed `Result` errors, missing permission
  cases, absence-of-data-read-as-data, and kin). Later recurrences bump `recurrences` and
  `last-seen` only — a `common` lesson that recurs stays `common` (the sample below shows
  exactly this).
- **Exactly three bullets** — Pattern (what the mistake looks like in code/diff terms a finder
  can match), Why (why it happens or slips review), Avoid (the concrete actionable rule).
  Target ≤ ~120 words per lesson.

## Size cap and eviction

- **Hard cap: 40 lessons AND 16KB, whichever is hit first.** 16KB keeps the whole file loadable
  as build context without crowding out the story itself.
- **Eviction, enforced at every write**: when adding a qualifying lesson would exceed either
  cap, evict the lesson with the lowest `recurrences`, tie-broken by oldest `last-seen`, then
  by lowest `L-` number (a total order), and repeat until BOTH caps are satisfied. A lesson
  recorded as recurring (`recurrences` ≥ 2) is never evicted in favor of a first-occurrence
  lesson — **if the store is at capacity and every resident lesson is recurring, a
  first-occurrence candidate is DROPPED, not admitted** (the incoming lesson loses; record
  nothing). Growth is curated, never append-only.

### Measurement bias in `recurrences` — read the counter honestly

A resident lesson installs its own finder check downstream, so the class it describes is
actively hunted while classes NOT in the store get no dedicated check. `recurrences` therefore
measures *how often we found it while looking for it*, not the class's true frequency, and
incumbents accumulate faster than newcomers would. Two consequences, both deliberate but worth
naming:

- Eviction's recurrence-priority is biased toward classes we keep hitting **and** keep looking
  for. That is defensible — a check that keeps paying out has earned its slot — but it is not
  an objective frequency ranking, and it should never be presented as one.
- A rising count does NOT by itself prove a lesson's Avoid rule is failing to land; increased
  detection explains it equally well. Treat a climbing counter as a prompt to look, not a
  verdict.

A bump still requires a genuine new occurrence in the code under review — finding the mistake
again because you looked is a real recurrence, not an artifact. What is an artifact is
*comparing* those counts across lessons as if all classes were equally hunted.

## Curation bar

**What enters** — finding classes likely to recur: `repeat`, `general`, or `common` as defined
above, distilled from CONFIRMED/PLAUSIBLE findings at settle time.

**What NEVER enters**:

- One-off nitpicks and finding instances with no recurrence potential.
- Item-, PR-, or incident-specific facts (those belong in commit bodies or item comments).
- Style opinions.
- Anything already stated in the repo's `conventionsDoc` — **the writer checks conventionsDoc
  before minting a lesson**; a rule that belongs there is a human-owned doc change, never a
  lesson. The store must never shadow the conventions doc.

**When classification is uncertain, do not write.** The store's value is its signal density; a
borderline entry costs more than it saves.

## Ownership

1. **Single writer**: only `review` mutates the file, at settle time.
2. **Read-only everywhere else**: consumers load it as context; no other skill writes it.
3. **Absent or empty is a VALID state** for every reader and the writer — readers degrade to
   current behavior; the writer creates the file (with the header above) on the first
   qualifying lesson. No setup prerequisite, ever.
4. **Committed repo data** — not gitignored; the team and every agent session share one store.
   A repo that relocates `lessonsDoc` must verify the new path is not ignored
   (`git check-ignore <path>` exits 1), or lessons silently never enter a commit.
5. **Lessons are repo data, not plugin content**: the plugin ships this format doc and the
   mechanism, never anyone's accumulated lessons.


## Self-verification (why the unreviewed lesson write is a bounded exemption)

A lesson entry lands after the reviewers settle, and step 7 re-runs them only if a rebase
changes the patch — so nothing else looks at it. That is acceptable, not a hole in the
reviewed-diff contract, because the file is DATA, never executable; consumers treat lessons as
checks that EXTEND a finder's list and never narrow it; and every lesson-derived finding is
still independently verified downstream. A bad lesson costs signal quality, never a gate —
which is why the write's own rule is re-read-against-this-file plus a visible heading+class in
the report, not an engine round.

## Cited by

- `.claude/ds-config.json` `_lessonsDoc_readme` — the addressing key.
- `review/SKILL.md` — the writer (classification, merge-by-ID, cap enforcement) and the
  dedup guard.
- `ultracode-build/SKILL.md` — phase-1 build context and phase-3 finder checks.
