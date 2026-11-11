---
load: contract
---
# Needs you — one list of the questions only the owner can answer

**Goal:** a run nobody is watching must not sit idle on a decision that is the owner's. It writes
the question down once, with a recommended answer, where the owner sees every such question
together, and goes on to other work. The list is nothing new: tracker items carrying ONE tag
(`needsYou.label`), seen through one saved view (`needsYou.view`, only ever quoted to people).

## When it applies

All three, else behave exactly as before (stop and ask in the conversation):

1. **`needsYou.label` is set.** Absent → the feature is OFF: no search, no comment, no tag, no
   message.
2. **The skill would stop and ask at a genuine owner fork**: a decision that is the user's, an
   ambiguous, risky or unverifiable finding, a destructive or outward-facing action that needs a
   yes. Nothing else is ever queued: not a progress note, not a finding the skill can settle.
3. **Nobody is answering**: the run is driven by another skill, started from a loop or a schedule,
   or otherwise unattended. An attended, interactive run asks in the conversation as it always has.

**A hard stop stays a hard stop.** Where another rule forbids the action without its own yes (the
production merge, anything a rule blocks "whatever the approval"), the question is queued so it
shows on the list and the action STILL WAITS under that rule: a thread answer never stands in for
the yes that rule requires.

## Queue it — exactly once per question

On the item the question is about: the story, else its epic, else `needsYou.fallbackItem` (a
release, a machine problem). No such item → fail open (below).

1. **Not twice.** `list_comments` on the item (every page). An open question (below) asking the
   same thing → queue nothing; name it in the report.
2. **One comment**, `add_comment` in the `{ html }` form, in this order:
   - the plan owner, @-mentioned so they are notified: the plan root's assignee, else the item's
     (`resolve_user`; `<user-mention-popup data-mention="" class="mention" data-id="<username>"
     data-label="<name>">@<name></user-mention-popup>`). Nobody to mention → fail open;
   - the question, bold, one line, in plain words;
   - `Recommended: <answer> — <one-line why>`;
   - the options, two to four, one line each with its consequence;
   - what is waiting on it, and what the agent is doing meanwhile;
   - `Reply in this thread with the option, or your own words.`;
   - the marker, alone, as the LAST paragraph: `Needs you: open`.
3. **The tag.** Resolve `needsYou.label` to its id first (`resolve_label`: a tag written by name
   can silently match nothing), add it to the item keeping the item's other tags, then read the
   item back and confirm the tag is there.
4. **One line in the run's report**: what was queued, on which item, and `needsYou.view` when set.

## Keep working — never wait on it

- **Never wait on a queued question, never poll it, never notify again.**
- The item is skipped exactly as a gated item is (`build-item` step 0's GATING CHECK: flag, next
  candidate), and stays skipped while its question is open. For that item it is a STOP in every
  respect but one: the run goes on instead of ending. Work already done stays committed and pushed
  on the item's branch, named in the comment.
- A skill another skill invoked (`ultracode-build`, `review`) queues, stops at the fork and
  returns it to its caller as queued; it never goes past the fork.
- Nothing else to do → end cleanly, naming every question queued.

## Pick answers up — once, at the start of a top-level run

`build-item` step 0 and `release` step 0, before selection, when `needsYou.label` is set. Bounded:
ONE `search_items` on the tag, then only those items' comments.

For each comment whose last paragraph is `Needs you: open`, read its thread (`list_comments`). It
is **open** until a reply in it ends `Needs you: answered`.

- **Answered** = a reply by the person the comment mentions that does not carry a marker. **Only
  the owner's own words count**: never an agent's reply, never anyone else's, never an answer
  relayed in a conversation or by another session. Agents may share a person's tracker account, so
  an agent writes in such a thread ONLY the closing reply below, and never types an answer there.
  Then:
  1. act on it as an in-the-moment owner decision **for that question only** (the item is
     selectable again; a hard stop keeps its own rule);
  2. `reply_to_comment`, once: one line saying what was done, then the marker alone as the last
     paragraph: `Needs you: answered`. Edit nothing the owner wrote;
  3. remove the tag and read the item back to confirm, unless another question on it is open.
- **Not answered** → leave it exactly as it is. No reminder, no second mention.
- An answer that does not settle the question → one reply asking the narrower question, the thread
  stays open.

## It fails open

The tracker unreachable, the tag missing, nobody to mention, a write refused, a read-back that
does not show the tag → say so ONCE in the report and fall back to stopping and asking, as before.
**Never lose the question:** a question that could not be queued is asked in the conversation.

## What this does not change

A settled epic release pull request still merges on its own once its full review settles
(`epicIntegrationBranches.autoRelease`); the standing yes still decides a release's merge; every
hard floor (required checks, review, the production merge's own yes) is untouched.

## Doctor

Read-only; `doctor` writes nothing here. `needsYou.label` absent → "Needs-you list: off". Set →
report the label and `needsYou.view` (or "no view set"), then `resolve_label`: no such tag → WARN,
"the tracker has no tag named <label>, so nothing can be queued". Fix: create the tag, or correct
`needsYou.label`. `needsYou.fallbackItem` set and `get_item` cannot find it → WARN.

## Cited by

- `build-item` SKILL.md step 0 (pick-up; the gating check and every unattended pause)
- `ultracode-build` SKILL.md contract (the stop-and-ask floor)
- `review` SKILL.md step 4 (the ambiguous / risky / unverifiable bucket, driven)
- `release` SKILL.md step 0 (pick-up; the unattended stop at step 4) and
  `release/references/auto-start.md` "Unattended stop"
- `doctor` SKILL.md §4 (the settings report)
