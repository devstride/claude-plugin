# Mandatory review lenses — a repository forces a finder on its own risk surface

The adversarial fan-out ships five generic lenses and forces exactly one of them, security, on
any diff touching the authentication boundary. Every repository has at least one more surface
where the same reasoning holds — transactions and durable events under a rolling deploy,
money-moving code, a permissions matrix — and the plugin cannot know which. `review.mandatoryLenses`
lets the repository name that surface and the question a finder must answer over it. This file
is the authority for the contract; the bodies that honour it cite it rather than restating it.

## Config key

```json
{
  "review": {
    "mandatoryLenses": [
      {
        "name": "concurrency-and-rolling-deploy",
        "paths": ["backend/src/**/*transaction*", "backend/src/**/events/**", "backend/migrations/**"],
        "question": "For every changed hunk: what ordering or isolation assumption does it make; what happens under READ COMMITTED; what happens while old and new revisions run side by side during a rolling deploy; which claim in the change summary cannot be proven from test or command output?"
      }
    ]
  }
}
```

| Field | Meaning |
|---|---|
| `name` | Kebab-case lens name. It labels the finder, its findings and the report line. |
| `paths` | Non-empty array of globs matched against repo-relative paths of the files in the diff under review. Globs are ANCHORED: a pattern is a path pattern, never a bare substring — `**/events/**` matches an `events` directory anywhere, `events` alone matches nothing. |
| `question` | What the finder must answer for every changed hunk in the matched files. It is the finder's base question, not a hint. |

Absent key or `[]`: no mandatory lens; nothing is reported. `setup` never writes entries — a
repository adds them by hand, because only the repository knows its own risk surface.

## What the skills do with a matched entry

1. **Match** — an entry matches when at least one hand-written file in the diff under review
   (generated files excluded, as always) matches one of its `paths`.
2. **One focused finder per matched entry**, carrying the entry's `name` as its lens and the
   entry's `question` as its base question, launched alongside the generic finders at the
   task-sized model/effort route. It sits on the same footing as the forced security lens: the
   breadth ceiling and the delivery profile clamp GENERIC finder breadth and never remove it.
3. **Findings are verified like any other** — REFUTED by default, CONFIRMED reproduces,
   PLAUSIBLE names the mechanism and path; the same fingerprint, grouping and `fixFloor` rules
   apply. A mandatory-lens finding is not automatically P1; severity comes from the verdict.
4. **The local review engine sees the question too.** When `review.localCommand` uses the
   `<context>` substitution, each matched entry's `question` travels in the distilled prompt as
   an additional hypothesis — never as a finding, and never as a substitute for the engine's own
   base question.
5. **Report** each matched entry as `mandatory lens <name>: ran (N findings)` in the risk-check
   report, the progress table and the hand-back. An entry that matched nothing is not mentioned:
   silence means "did not apply", which is a different fact from "ran and found nothing".
6. **A malformed entry is said once and ignored** — missing `name`, `paths` or `question`, a
   non-array `paths`, or a non-array key. The skill names the entry and continues with the
   rest; it never guesses a lens into existence.

## Where it runs

- `ultracode-build` phase 3 (the story risk check): a matched entry is an immediate-risk
  boundary of its own, so its focused verifier launches even for an otherwise routine diff.
- The merge-boundary adversarial review (`review-fanout.md`, run by `review`): a matched entry
  adds its finder to cycle 1 and to every later cycle whose effective scope still touches a
  matched file.

## Why a forced lens, and not a lesson or a bigger ceiling

A lesson is an advisory hypothesis handed to whichever finders happen to run; under a narrow
breadth ceiling the one correctness finder receives it as one line among many. A wider ceiling
adds generic finders, which is exactly the overlap the engineering-economy contract tells the
loop to avoid. What a repository needs is one finder that asks one specific question every time
the surface is touched, regardless of profile — the security lens already works that way, and the
failures this seam exists for look like it: a fix that was atomic in a test and not under READ
COMMITTED; a consumer that read a reshaped event while the old revision was still emitting it.
Both were found downstream, after the story's own review had passed at full breadth.

## Cited by

- `skills/ultracode-build/SKILL.md` — phase 3, immediate risk floor.
- `skills/ultracode-build/references/review-fanout.md` — task-sized breadth and the lens list.
- `skills/review/SKILL.md` — step 1, the Claude and local-engine launches.
- `skills/doctor/SKILL.md` — section 6, review roster.
- `skills/setup/references/config-defaults.md` — the key's default and worked example.
