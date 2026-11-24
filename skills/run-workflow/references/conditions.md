---
load: contract
---
# Conditions — when a step runs only if something is true

A step whose `when` has the mode `condition` runs only when its condition holds; otherwise it is
recorded skipped, with the verdict `SKIPPED: <condition> was false`, and the run moves on. The
runner decides it from the run's own record and from facts you pass it; it never evaluates the text
as code, and it touches no git and no network to decide it. Only a step that is not required may be
conditional (`start` refuses the rest), and a condition never removes a proof requirement.

## The grammar

One predicate, optionally after one `!` (NOT). No `and`, `or`, parentheses or free text: two tests
are two steps. At most 200 characters. `${CLAUDE_PLUGIN_ROOT}/schemas/when-condition-fixtures.json`
lists the strings accepted and refused; the tracker reads the same file.

| Condition | True when | Decided from |
|---|---|---|
| `review-path:fast` or `review-path:pull-request` | the earlier review took that path (`fast` is the fast local review) | the run itself |
| `item-tag:<name>` | the item carries the tag (case ignored); the name is the rest of the text, colons included, 1 to 100 characters | `itemTags` |
| `item-work-type:<name>` | the item is of that type (case ignored) | `workType` |
| `touches:<glob>` | at least one changed path matches the glob | `changedPaths` |
| `has-repository` | the run's checkout has a repository the tracker can name (the runner's own `repository`) | the run itself |
| `step-verdict:<step id>:<WORD>` | that earlier step's verdict is that word | the run itself |

A `touches` glob is anchored at both ends and matched by the plugin's one branch matcher: `**`
crosses directories and needs at least one character, `*` is one path segment, everything else is
literal. So `events` alone matches only a path called `events`, and `**/events/**` matches
`backend/src/events/x.ts`. A glob holds no white space, no date token such as `<YY-MM-DD>` and no
trailing `[-n]`, and is at most 150 characters. A `step-verdict` must name an earlier step and a
word its contract gives (`start` refuses it otherwise).

## need-facts

When the run reaches a conditional step whose fact it does not have, it answers
`{"action": "need-facts", "needs": [...]}` and records nothing. Collect exactly the facts named, then
call `next` with `{"facts": {...}}`; `start`, `done` and `resume` accept `facts` too. Facts count for
that one call only, so pass them again when asked again.

- `changedPaths`: the paths the work changes, from the diff against the working base
  (`git diff --name-only origin/<workingBase>...HEAD`), repository-relative, as a list.
- `itemTags`: the item's tag names, from the tracker's item, as a list.
- `workType`: the item's work type name, from the tracker's item.

**A fact you cannot know is passed as `null`, never guessed**: outside a repository there are no
changed paths, and a run with no item has no tags or type. The step then **runs**, and its evidence
starts `condition could not be decided: <fact> unknown`. Undecided always means the step runs, never
that it is skipped, with or without `!`.

## Examples

- `item-tag:needs-compliance` on a compliance check: the check runs only on items tagged for it.
- `!touches:**/*.md` on a spelling check: skipped when no Markdown file changed.
- `step-verdict:plan-qa:PASS` on an end-to-end check: it runs only after the QA plan step passed.

## Cited by

- `skills/run-workflow/SKILL.md` — the loop, step 3 ("Read … in full when an answer is
  `need-facts`").
- `skills/run-workflow/references/workflow-runner.md` — the actions ("Read … in full before acting
  on one").
- `skills/run-workflow/references/workflow-contracts.md` — `bad-condition` (the grammar).
