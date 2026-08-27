# GitHub review-API reference — exact queries, and the traps behind each rule

Read this when executing a step that touches the GitHub review APIs. `SKILL.md`
carries the RULES; this file carries the queries and the evidence for why each rule
exists. Every trap below was measured on a real PR, and every one of them fails
SILENTLY — the wrong call returns a plausible empty result rather than an error.

## Requesting the Copilot review

REST `/pulls/{pr}/requested_reviewers` rejects a bot with `Reviews may only be
requested from collaborators`. Bots go through GraphQL, using the `graphqlBotId`
from `review.automatedReviewers`:

```
gh api graphql -f query='mutation($prId:ID!,$botId:ID!){
  requestReviews(input:{pullRequestId:$prId, botIds:[$botId], union:true}){
    pullRequest{ number } } }' \
  -f prId="$(gh pr view <pr> --json id --jq .id)" -f botId="<graphqlBotId>"
```

**Use the CONFIGURED id — never discover one from `suggestedActors`.** That query
with `capabilities:[CAN_BE_ASSIGNED]` lists ASSIGNEES and returns only
`copilot-swe-agent` (`BOT_kgDOC9w8XQ`) — the Copilot CODING agent, a different bot
from the reviewer (`copilot-pull-request-reviewer`, `BOT_kgDOCnlnWA`). Requesting
the coding agent is silently accepted and creates no review request.

**The mutation reports success even when it creates nothing** — observed live
registering on two PRs and silently no-opping on the next two across four
attempts. The only proof is a NEW `review_requested` timeline event. Count before
and after and require an increase; a bare all-history count is already non-zero on
any PR that was ever reviewed, so a silently no-op'd re-request would read as
registered and you would wait on a reviewer nobody asked:

**`--paginate` with `--jq` evaluates the filter ONCE PER PAGE**, so the naive form yields one
count per page (`0 1 0 0 0 1 0`), not a total — and the numeric comparison then breaks on any
multi-page timeline. Note `--slurp` is NOT accepted together with `--jq`; slurp the pages and
pipe to a standalone `jq`:

**Count PER REVIEWER, not in aggregate.** Now that the skills iterate every configured reviewer,
an aggregate count is wrong: one request landing while another silently no-ops still increments
the total, so the failed entry would be marked REGISTERED. Filter on
`requested_reviewer.node_id` against that entry's own `graphqlBotId` — the timeline event exposes
it (verified: `node_id` = `BOT_kgDOCnlnWA`, login `Copilot`).

```
# $1 = the graphqlBotId of the reviewer entry being requested
count_requests() {
  gh api "repos/{owner}/{repo}/issues/{pr}/timeline" --paginate --slurp \
    | jq --arg bot "$1" '[.[][]|select(.event=="review_requested"
                                       and .requested_reviewer.node_id==$bot)]|length'
}
before=$(count_requests "$BOT_ID")
# ... run the mutation for THAT entry ...
after=$(count_requests "$BOT_ID")
# that entry registered only if: after > before   (repeat per configured reviewer)
```

(Verified against a real PR with `per_page=1`: the `--jq` form printed seven per-page counts, the
slurped form printed the correct total.)

Do NOT use `reviewRequests` for this — it is empty both while a request is queued
AND after the review posts, so it distinguishes nothing. If no event appears, retry;
if it still will not register, ask the user to press **Re-request review** in the UI,
which works. That figure is the SEED observation only — the wait itself uses the per-reviewer
table it learns on each machine (`reviewer-latency.md`). Matching a review to its reviewer:
verified live, REST review objects carry `user.node_id` equal to the bot's GraphQL id
(`BOT_kgDOCnlnWA` on the review object and on the timeline's `requested_reviewer` alike), so
that is the match key; the `/reviews` login is a fallback only. Measured latency once registered is ~3 minutes (measured twice on one
live PR: 17:22:55Z → 17:25:31Z, and 18:29:22Z → 18:32:17Z) — "nothing yet" long
past that points at registration, not slowness.

This matters because the opposite assumption once produced a confident and false
"Copilot is broken" diagnosis with a billing-overage theory, then a second wrong
conclusion that its latency was ~13 minutes — derived by pairing a review with a
request that had never registered. Measure from the timeline event, never the call.

## Collecting the findings

### The login trap

The SAME Copilot reviewer reports THREE different logins depending on which API you
ask (measured on a live PR):

| surface | login reported |
| --- | --- |
| REST `/pulls/{pr}/reviews` | `copilot-pull-request-reviewer[bot]` |
| REST `/pulls/{pr}/comments` | **`Copilot`** |
| GraphQL `reviewThreads → comments → author.login` | `copilot-pull-request-reviewer` |
| REST `/issues/{pr}/timeline` → `requested_reviewer.login` | **`Copilot`** (use `.node_id` instead — it equals the configured `graphqlBotId`) |

So the `bot` field in config is correct for REQUESTING and for `/reviews`, and wrong
for `/comments`. A filter built from it returns zero rows there, indistinguishable
from "the reviewer left no inline comments". `test("copilot")` does not save you
either — `Copilot` is capital-C and jq's `test` is case-sensitive; use
`test("copilot"; "i")` if you must match a login at all.

On a live PR a re-review's single inline comment — a genuine blind spot in a
security regression guard — was collected with a `[bot]`-suffixed filter, reported
as "no inline comments", and surfaced only later from the unresolved-thread count.

**Scope by `pull_request_review_id`**, which is the same integer on every surface.

### Scoping to the current cycle

Each endpoint returns the PR's whole history, so after a re-review you would
re-triage findings already fixed on an earlier push. Select the target review(s)
first and keep their ids (worked example from a live PR: Copilot reviews at 17:25:31Z
and 18:32:17Z, the first fully addressed before the second arrived).

```
# 0. the review(s) in scope, and their ids
gh api repos/{owner}/{repo}/pulls/{pr}/reviews --paginate \
  --jq '[.[]|{id,at:.submitted_at,author:.user.login,body}]'

# 1. inline comments for a selected review id — select on the id, NOT user.login
gh api repos/{owner}/{repo}/pulls/{pr}/comments --paginate \
  --jq '.[]|select(.pull_request_review_id == <id>)
            |{id,review:.pull_request_review_id,path,line,user:.user.login,body}'
```

Print `user.login` rather than filtering on it — useful to read, actively harmful as
a predicate.

On a re-review, "has the reviewer posted?" must mean THIS cycle. The earlier
submission is already in `reviews`, so a naive predicate settles instantly and you
triage the stale review while the new one is still in flight — merging with nothing
having looked at the current diff. Capture a high-water mark first (largest existing
review `id`, or the request timestamp / last fix-push time) and require strictly
newer:

```
gh api repos/{owner}/{repo}/pulls/{pr}/reviews --paginate --slurp \
  | jq --argjson prev "$PREV_REVIEW_ID" '[.[][]|select(.id > $prev)]|length'
```

(Slurped for the same reason as the timeline count above — `--paginate` with `--jq` runs the
filter once per page, so on a multi-page PR the bare form yields newline-separated per-page counts
and the numeric predicate silently misbehaves.)

Use that same id as the floor when selecting inline comments.

### The review BODY — the half that is easy to miss

The body has no thread and never appears in a `reviewThreads` query. Copilot puts
findings it is less sure about in a collapsed
`<details><summary>Comments suppressed due to low confidence (N)</summary>` block
inside it, complete with file and line. Treat them exactly like inline findings —
"low confidence" is the reviewer hedging, not a triage decision you may inherit.

On one live PR a suppressed comment correctly identified a real race
(`writeFileSync(..., {flag:'wx'})` publishing an empty file before its contents); it
was never read because collection was thread-only, and the defect shipped to develop
and needed a follow-up PR. On another, a suppressed comment correctly identified that
the three-engine review contract was not implemented on every code path.

A review can carry findings with ZERO inline comments, so an inline count of 0 never
means "no findings".

## Resolving threads

Inline comments live in *review threads*, and the REST comment id is NOT the thread
id. List threads (the inner `databaseId` equals the REST comment id, which is how you
correlate a thread to the finding you addressed):

**PAGINATE this too.** Capped at the first 100 threads, a current thread on page two cannot be
mapped to its GraphQL node id and therefore cannot be resolved — and the paginated zero-check in
the next section will detect the leftover without being able to supply the missing id.

```
gh api graphql --paginate -f query='
  query($owner:String!,$repo:String!,$pr:Int!,$endCursor:String){
    repository(owner:$owner,name:$repo){
      pullRequest(number:$pr){
        reviewThreads(first:100, after:$endCursor){
          nodes{ id isResolved comments(first:1){ nodes{ databaseId author{login} path } } }
          pageInfo{ hasNextPage endCursor }
        } } } }' -F owner=<owner> -F repo=<repo> -F pr=<pr>
```

Then resolve each thread you addressed:

```
gh api graphql -f query='
  mutation($threadId:ID!){
    resolveReviewThread(input:{threadId:$threadId}){ thread{ isResolved } }
  }' -F threadId=<thread node id>
```

**Check the mutation's own response**: it returns `thread { isResolved }` — assert `true` per
thread rather than firing the batch and assuming. Resolution state lives ONLY in this GraphQL
`isResolved` flag; two UI states are easily mistaken for it and are NOT it:

- **"Outdated"** — set automatically when a rebase/force-push moves the lines a thread anchored
  to. It looks handled in the UI but the thread is still unresolved until this mutation runs.
- **A posted reply** — replying (the REST `/replies` call) does not resolve; a thread with a
  perfect fix-reply still shows as an open review comment until explicitly resolved here.

## Verifying zero unresolved — PAGINATE

`reviewThreads(first:100)` silently truncates, so on a long-lived PR the unresolved
thread sits on page two and an unpaginated query reports a reassuring zero while a
finding is still open:

```
gh api graphql --paginate -f query='query($o:String!,$r:String!,$p:Int!,$endCursor:String){
  repository(owner:$o,name:$r){ pullRequest(number:$p){
    reviewThreads(first:100, after:$endCursor){
      nodes{ isResolved }
      pageInfo{ hasNextPage endCursor }
    } } } }' \
  -F o=<owner> -F r=<repo> -F p=<pr> \
  --jq '[.data.repository.pullRequest.reviewThreads.nodes[]|select(.isResolved==false)]|length'
```

(`--paginate` drives `$endCursor` itself; sum the per-page counts.) A non-zero result
means collection MISSED a finding — it is the only cheap check that catches that.

Copilot may also leave an overview/summary as an *issue* comment (not a review
thread) which cannot be resolved; a reply there, or nothing, is fine.

## The mergeability stall — why close+reopen is not enough

`pull_request` workflow runs are built on `refs/pull/<n>/merge`, the merge ref GitHub computes
when it evaluates mergeability. When that computation stalls — `gh api repos/{owner}/{repo}/pulls/<n>
--jq '[.mergeable_state,.merge_commit_sha]'` reads `unknown` and `null` for minutes — there is no
merge ref to build, so GitHub creates **no workflow runs at all** for the event: not even skipped
ones. A board with no runs reads exactly like "the flip triggered nothing" (step 7.3's known
race), which is why the two are easy to confuse; the difference is the `mergeable_state` read.

Observed twice on one day, on two repositories at once, which is what shows the stall is
repo-wide for EXISTING heads rather than a property of one pull request: close+reopen did not
clear it, re-setting the base (`gh pr edit --base`) did not clear it, and a control pull request
opened in the same window stalled the same way. What cleared it, both times, was a NEW HEAD — an
empty commit pushed to the branch. The merge ref was built and runs started within seconds.
Hence step 7.3's order: close+reopen first (it is the cheap fix for the flip race and costs
nothing), then one empty commit when `mergeable_state` is still `unknown` ~60 s later, then
stop — a second empty commit has never been needed, and looping on one would only stack no-op
commits on the branch.

**Why 7.3(b) has three preconditions rather than one command.** `git commit --allow-empty` does
NOT force an empty tree — it commits whatever is in the index, and an empty *diff* is only the
result when nothing is staged. A session that had staged an unrelated edit would therefore push
real content under the "does not change the patch, so no re-review" rule: substantive code
settled as a no-op. Hence a clean index BEFORE, and a tree comparison against the parent AFTER —
the check that actually proves what the rule assumes. And the commit must land on the PR's own
head: `review` runs standalone against any PR number, and `release` operates on two named
branches, so in neither case is local `HEAD` necessarily that PR's head — an unqualified push
would leave the stalled PR untouched while advancing some other branch.

Two consequences step 7.3 states as rules: the empty commit does not change the patch, so the
"CHANGED the patch" re-review rule does not fire; and on a protected release head it is a
fast-forward push, which the protected-head rule permits (it forbids rewriting), at the cost of
a no-op commit that production inherits at promotion — the tree-identical skip still fires
there, because the tree is unchanged.
