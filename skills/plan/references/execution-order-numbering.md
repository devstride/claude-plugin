# Execution-order numbering — CANONICAL CONVENTION

The single authoritative definition of the bracketed `[N]` execution-order prefix in leaf
titles. Every skill that stamps, splices, or reads these numbers applies THIS convention by
citation — none restates it.

## The convention

Every executable LEAF item (a leaf-role type resolved at planning time via
`get_work_type_hierarchy` — this org's Story or Defect; NOT the container levels above them,
e.g. this org's Capabilities/Epics, which `/devstride:build-item` never picks up) carries a bracketed
execution-order prefix at the VERY START of its title: `[N] <title>`. Whole integers
`[1] … [N]` mark the original planned sequence assigned at authoring (`plan` step 6.5);
dotted numbers (`[23.1]`, `[23.1.1]`) mark items later spliced in by `insert-*`. **These
numbers are STABLE IDENTIFIERS — once assigned, they are NEVER recomputed** (renumbering would
churn shipped items and break any reference to them). `rationalize-gantt` re-dates but must
never renumber — the numbers are independent of the synthetic dates it computes, so prefixes
and date-order disagreeing is expected (inserts intentionally sit out of integer order).

## Splice arithmetic — numbering an insert between live neighbours

A spliced item's prefix must sort **STRICTLY between `UPSTREAM`'s prefix and `NEXT`'s prefix**
(compare dot-segment by dot-segment, numerically — this is what "sorts strictly between"
means). Read the current prefixes off the neighbours' titles — do NOT recompute the whole plan,
and NEVER renumber the neighbours. Worked cases:

- between `[23]` and `[24]` → `[23.1]`; a further insert into the SAME slot → `[23.2]`, then
  `[23.3]` (each still sorts between its live neighbours).
- between `[23.1]` and `[24]` → `[23.2]`; between `[23.1]` and `[23.2]` → `[23.1.1]`.
- after the LAST item `[40]` with no `NEXT` → `[40.1]`.
- if `UPSTREAM` is undefined (spliced at the very front, before the old root `[1]`) → use
  `[0.1]`, `[0.2]`, … so it still sorts ahead of `[1]`.
- if the item must JUMP the queue ahead of the current `NEXT` (e.g. an urgent defect), it
  splices before whatever it precedes — number it to sort strictly between that item and ITS
  upstream, same rule; if it becomes the new front before `[1]`, use `[0.1]`, `[0.2]`, ….

A new leaf that lands at the END of the execution order (extend-path authoring) continues the
integer sequence instead of taking a dotted sub-number.

## Unnumbered plans

If the plan is UNNUMBERED (the neighbours have no bracketed prefixes — authored before
numbering existed), skip the prefix, and say so in the report: numbering hasn't been rolled out
on this plan; suggest a `/devstride:plan <root>` pass to number the whole tree in one pass if the user
wants it. Do not partially number a plan — never mix numbered and unnumbered items.

## Cited by

- `plan` SKILL.md step 6.5 (canonical owner — stamps the numbers at authoring) and IMPORTANT
- `insert-story` SKILL.md step 4.5
- `insert-defect` SKILL.md step 4.5
- `rationalize-gantt` SKILL.md ("Re-date ONLY — never renumber")
- `build-item` SKILL.md step 7 (close-out report)
