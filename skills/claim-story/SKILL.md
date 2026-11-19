---
name: claim-story
description: "Claim one story for this agent so no other builds it; report who holds it."
---

**Human output.** Read `${CLAUDE_PLUGIN_ROOT}/skills/build-item/references/plain-language-output.md` once per top-level run; composed skills reuse it. Apply it to every message.

Read `${CLAUDE_PLUGIN_ROOT}/skills/release/references/step-skills.md` first: the rule every step skill follows.

Arguments: $ARGUMENTS — one JSON object, the `claim@1` payload
(`${CLAUDE_PLUGIN_ROOT}/schemas/step-contracts.json`): `item` (the story's number) and `mode`
(`select` for a story the loop chose, `named` for one a person named, `resume` for the handoff's
resumed story). **Read `${CLAUDE_PLUGIN_ROOT}/skills/build-item/references/story-claims.md` in full
before the first call**: the claim, the record, the modes and what degrades.

## Verdict

`CLAIM: WON | RENEWED | TOOK OVER | HELD <holder> | NOT CONFIGURED | DEGRADED [<reason>]`

## Steps

1. No `claims` block in `.claude/ds-config.json` → `NOT CONFIGURED`: no claim, no heartbeat, no
   message.
2. **Claim it** before the item moves to In Progress, kind `story`, key the item number: the holder
   from `${CLAUDE_PLUGIN_ROOT}/skills/release/scripts/clearance-github.sh identity`, the record from
   `${CLAUDE_PLUGIN_ROOT}/skills/build-item/scripts/claim_record.py`, one claim through the
   configured provider, exactly as the reference's "The claim" and "The record" spell.
3. Pipe the answer to `python3 ${CLAUDE_PLUGIN_ROOT}/skills/build-item/scripts/story-claim.py
   decide` with the request the reference spells (`mode` as passed) and follow its `action`:
   `proceed` → `WON`, or `RENEWED` when its message says renewed; `takeover` → claim again with its
   `takeoverDigest`, decide again, then `TOOK OVER`; `reclaim` → claim again plainly and decide
   again; `skip` or `stop` → `HELD` with the holder's machine and session and since when, as its
   message names them (an answer it could not read: that message); `degrade` → `DEGRADED` with its
   reason. Say its `message`; times are local, with the zone's abbreviation.
4. The holder token is never printed, logged or put in a comment; only its digest is ever shown.

`HELD` only reports. It ends the run, and what follows is the loop's: a selected story gives way to
the next candidate, while a story the person named or the handoff resumed stops the run, naming the holder. This step never takes over a live claim by itself.

## Result

After the verdict and its evidence, one fenced `json` block: `state` (`won`, `renewed`,
`took-over`, `held`, `not-configured` or `degraded`), and for a held claim `heldBy` (machine and
session, never the holder) and `since`.

**Step rules.** This step only; verdict first; safe to re-run (a claim already yours renews); config
wins; it never starts a subagent and never decides what runs next.
