---
load: contract
---
# A cloud reviewer requested once, at the final head

**Goal:** a per-use cloud reviewer reviews a pull request once, on the head that is about to
release CI, instead of after every fix round — and once more only when one of its own findings
changed the code.

`review.automatedReviewers[].requestPolicy` is `"every-round"` or `"final-head"`. Absent, or any
other value → `"every-round"`: requested when the pull request opens and re-requested on every
follow-up, exactly as before. `baseBranches` still decides whether an entry is in scope at all;
this key decides only WHEN an in-scope entry is asked.

## The procedure for a `"final-head"` entry

1. **Never at pull-request open, never in a follow-up cycle.** `pr` skips it at open; `review`
   step 1 and every step 5 follow-up skip it. The local engines run every round as usual. The
   roster announcement says so plainly: "<name>: requested once at the final head".
2. **Request it at step 7's entry** — every other finding fixed, pushed, replied-to and resolved —
   after 7.1's refresh, so the head is final, and before 7.1b's hold or the flip. Request it per its
   `how`, prove a NEW `review_requested` event and apply the registration window exactly as step 1
   does, wait with step 2's script, then take its findings through steps 3–6.5 like any other. A
   draft does not block an explicit request.
3. **One more pass after a fix it caused.** A finding of its that leads to a fix commit: fix and
   push per step 5 (the local streams get their contextual follow-up), come back to step 7's entry,
   and request it ONCE more on the fixed head. Findings from that second pass are triaged and fixed
   by the floor as usual but earn no third request — except a verified P1 or serious P2, which keeps
   the no-cap safety rule: request again after that fix.
4. **At most once per head.** Record every request's head SHA in the ledger; never request it twice
   on the same head.
5. **Failure is ordinary degradation.** Unproven within `reviewerRegistrationWindowMinutes` →
   dropped; registered but silent → degraded at the poll bound; both reported. If it was the only
   cloud reviewer in scope and the local engine also failed, the Claude-only STOP applies.

## Why

On a busy repository a per-use reviewer re-requested after every fix round can cost more than CI,
and most of those rounds review code that is about to change again. Asking once at the head that
will actually be merged keeps its independent view where it counts; the one extra pass after a fix
it caused checks that the fix holds.

## Cited by

- `skills/review/SKILL.md` — the cloud roster bullet and step 7's entry.
