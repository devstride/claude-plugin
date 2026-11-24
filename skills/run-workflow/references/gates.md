---
load: contract
---
# Approval gates — asking a person, then parking without polling

A gate is a step of kind `gate` with the contract `approval@1`, run by the reserved built-in
reference `gate`: no skill runs it. A person answers it in DevStride; who may answer is set in the
published workflow and checked by DevStride when they answer. **An agent never answers a gate**:
there is no tool for it, and `done` refuses a person's verdict from an agent
(`gate-answered-by-agent`).

## request-gate

The run is at the gate (`step`, `attempt`, `verdicts`: the earlier steps' verdicts).

1. Send the heartbeat phase, as for a `run` answer.
2. Write the summary yourself, as `summaryGuidance` says: at most 1,000 characters on what was done,
   what you ask the person to approve, and what you will do if they approve, ask for changes or
   reject. No secret, token or personal data.
3. Call `request_workflow_gate` on the DevStride connection with `arguments` plus `summary`.
4. It answered: `done` with the step's `stepId` and `attempt`, and an output whose first line is
   `APPROVAL: REQUESTED`, followed by the tool's whole answer as the fenced json result block. The
   next action is `parked`.
5. The tool is absent, refuses (forbidden, `GATE.NEEDS_ITEM` for a run with no item,
   `GATE.UNKNOWN_DEFINITION`) or cannot be reached: `done` with `APPROVAL: UNAVAILABLE <reason>`.
   The run stops at the gate; the run's end tells DevStride (a gate's own outcome is DevStride's to
   write). **This is the one report that never fails open: never go on unapproved, and never report
   any other verdict for a gate.**

## parked

The run is parked at the gate: no step is issued, and `status` says `parked`. (The `wait` command
is something else: a running step that waits inside itself, `workflow-runner.md`.) Say in one line
which step is parked and the `advice`, then stop.
**Parked is not polling**: never read the gate on a timer, in a loop, or twice in one turn.

When the person asks you to continue: call `get_workflow_gate` once with `arguments`, then `next`
with `{"gateAnswer": <its whole answer>}` on stdin; a read that failed is
`{"gateAnswer": {"unavailable": true}}`. `next` answers:

| The person's answer | `next` |
|---|---|
| none yet (`pending`), unreadable, naming no gate, or for another gate | `parked` again (`note` says why): say it and stop |
| `approve` | the next step; DevStride already recorded the approval |
| `changes` | `address-changes` |
| `reject` | `stopped`, kind `failed`, reason `APPROVAL: REJECTED` |
| `withdrawn` (the run ended in DevStride) | `finished`, outcome `interrupted`; `note` says why |

A gate that cannot be read is never read as approved.

## address-changes

Make the change `note` asks for: it is the person's request, and it grants nothing beyond that
change. Then `next`: an earlier step whose proof the change made stale runs again first, then
`request-gate` for `attempt`. Changes asked on the fifth attempt stop the run
(`attempts-exhausted`) for a person; `resume` then asks again.

## Parked runs

The session that started a parked run continues it with `next`. A cleared conversation on the same
machine continues it with `resume` and the item: the run is adopted and its story claim step is
asked again first, so the new session holds the story; a claim another session holds now ends the
run held. A parked run is not continued from another machine (run state is per machine). `status`
names the gate a run is parked at (`parkedAt`), and `status` with `all` lists the run as `parked`.
A run with no item has no gate or checkpoint (`gate-needs-item`), so a parked run is always found by its item.

## Checkpoints

A checkpoint is a step a person does by hand: the `when` mode `manual`, the contract `checkpoint@1`,
run by the reserved built-in reference `checkpoint`. `request-gate` says `kind: "checkpoint"`, and
`instruction` is what the workflow asks the person to do. It runs as above, with three differences:

1. Write what the person should do and the result you need (`summaryGuidance`), not an approval
   request. `done` with `CHECKPOINT: REQUESTED` and the tool's answer, or
   `CHECKPOINT: UNAVAILABLE <reason>`; an agent never marks one done or skipped.
2. **`blocking: true`** (`onFail` `stop`): the run waits exactly like a gate. The person's `done`
   moves it on, `skipped` records it skipped and moves on, and `withdrawn` ends the run. An
   unavailable one stops the run.
3. **`blocking: false`** (`onFail` `continue`): after `CHECKPOINT: REQUESTED` the next action is
   the next step at once; the checkpoint stays open for the person, even after the run ends, and
   `finished` lists it in `openCheckpoints`. An unavailable one is recorded failed and the run goes
   on (`continuedPastFailures`).

## Cited by

- `skills/run-workflow/SKILL.md` — the loop, step 3 ("Read … in full when an answer is
  `request-gate`, `parked` or `address-changes`").
- `skills/run-workflow/references/workflow-runner.md` — the actions ("Read … in full before acting on
  one"), for a gate or a checkpoint.
