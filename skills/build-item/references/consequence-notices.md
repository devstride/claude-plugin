---
load: contract
---
# Consequence notices — tell the item's author what a change could do to others

**A notice, never a gate.** Nothing here stops, delays or re-opens a build, review, merge or
release, and a notice is never a review finding. It tells the person who asked for the work, in
plain words and with evidence, when the change could cost money, cut someone off or break a caller,
so they hear it from the loop rather than from a customer or an invoice.

## The categories

| Id | Title | Counts when the change… |
|---|---|---|
| `billable-infrastructure` | Adds billable infrastructure | adds a cloud resource, managed service or paid plan, or more of one charged by size, count or use (a larger instance, more replicas, longer retention, a new paid API) |
| `removed-caller-surface` | Removes something callers still use | deletes or stops serving an endpoint, route, webhook, event, tool, command, export or documented URL that callers outside this change may still use |
| `access-removed` | Removes someone's access | narrows a permission, role, policy, sharing rule, allow list, token scope or membership so a person, team, customer or service loses access they had |
| `interface-break` | Could break a published interface | changes the shape, meaning, validation, authentication, limits, errors or timing of an API, webhook, tool, command or documented URL so existing callers may stop working correctly |

A removal is `removed-caller-surface`; a change that keeps the thing but alters it is
`interface-break`. The repository adds its own with `consequenceNotices.categories`
(`{id, title, means}`); `consequenceNotices.enabled: false` turns the whole check off.

**Not a finding:** tests and fixtures; a "might" with no line that does it; for the two caller
categories, code with no caller outside this repository and this change, or a replacement that
keeps the old surface working (a redirect, an alias, a compatible default). An access loss counts
whoever loses it, a teammate included. When it is unclear whether outside callers exist, a documented, versioned or registered
surface (an OpenAPI path, a published tool or command, a URL in user docs) counts as published.

## When — once per item, on the final reviewed diff

After the review settles, just before the merge command, on the head that merges, whatever the
profile: `build-item` 5a after any refresh and its re-run gate, right before the `--no-ff` merge;
5b right before the `MERGE` line, on the head it passes (the final reviewed head, or 5b's
tree-identical rebase of it); step 8 for the release unit itself, right before its merge, on its
release pull request's final reviewed head (`epic-release-steps.md`). A story held by a release
hold runs it when it merges. Fetch first; the base is the SHA of `origin/<working base>` (step 8:
of `origin/<the routing.py release-target branch>`) recorded now, never a local branch that may be
stale, and the diff is `git diff --unified=0 -M <base>...<head>`.

## How

1. **Judge the diff** against the categories in force (the table plus the repository's). Each
   finding is `{category, file, lines, side, sentence}`: the changed file; the changed lines
   (`"40"`, `"40-52"` or `"40-42, 50"`, every one of them changed); `side` `new` for added or
   changed lines and `old` for removed ones (old-file numbers); and ONE plain sentence on who or what
   is affected and how ("Any integration that downloads exports will get a 404"). A renamed file
   (its old path), a binary file, a mode change or an empty file added or deleted is cited with no
   `lines`. No finding → an
   empty list. Step 8's unit check leaves out only a consequence a carried leaf's standing notice
   already states (the same effect of the same code), never another in the same file.
2. **The people.** The author is the item's creator: `get_item(view: 'full')`'s `authorUsername`,
   with `resolve_user` for the name. Each `consequenceNotices.notify` entry is resolved the same
   way. One that does not resolve is left out and named in the recap.
3. **Earlier notices.** `list_comments` on the item, oldest first, every page.
4. **Run the helper**:
   `python3 ${CLAUDE_PLUGIN_ROOT}/skills/build-item/scripts/consequence-notices.py check` with
   `{"item", "head", "base", "findings", "author": {"username", "name"}, "notify": [...],
   "earlier": [<the list_comments rows>]}` on stdin, in the checkout. It checks every finding's
   evidence against the diff, renders the comment and answers `{post, notices, comment, recap,
   reason}`. Exit 2 naming a finding → the evidence is wrong: cite the lines the diff changed and
   run it again; never drop a real finding to get past it. Any other non-zero exit (the
   configuration, git) → no notice: the recap says "consequence check could not run: <reason>",
   and `/devstride:doctor` names the fix.
5. **Post** when `post` is true: `add_comment` on the item with `comment` as `{html}` exactly,
   internal (the default visibility). A mention the server rejects → post once more without it and
   name who was not told. `post` false → nothing to post; its `reason` says why (no finding, the
   same notice already there, or turned off).
6. **The run's recap** (step 7) carries each `recap` line, or "Consequence notices: none".

The helper matches only the notice shape it renders, for that item, so a reply never counts as one.
The same notice (the same findings, in any order) is not posted twice; one whose facts changed is
posted again and the newest stands; an earlier notice the final diff no longer supports gets a
short "none" withdrawal.

## Release recaps repeat them

`release` (step 4's recap before the yes) and the epic release (with step 8's unit check, before
its merge) gather every notice the release carries, ONCE, before the merge: for each item it
carries (the items the release-holds check reads, and each release unit's leaves via
`get_item_hierarchy`), `list_comments` oldest first, every page, then `consequence-notices.py
collect` with `{"items": [{"number", "comments": [<rows>...]}]}`.

**Reconcile before repeating.** A later story or the release's own fixes can undo or change what an
item's notice says. Record the release's diff before the merge: `<base>` the SHA of
`origin/<release.productionBranch>` for `release` (of `origin/<the routing.py release-target
branch>` for an epic), `<head>` the release's final reviewed head. `collect` returns each notice's
`findings` as data. A finding **still holds** when the release diff still makes the same change to
that file, on the same side, with the same effect; line numbers that merely shifted are no change.
Every finding holds → repeat it as is. One no longer holds, or its effect changed → run `check` for
that item on the release diff (`base`, `head`) with How steps 2–3's author, `notify` and the item's
comments as `earlier`, and the findings as they now hold, lines re-cited from that diff (none → its
withdrawal); post, and collect again. In step 8 the order is: gather, the unit's own check (which
needs the leaves' standing notices), then reconcile.

Each `recap` line goes under **Consequence notices**; none → "Consequence notices: none".
**Record them before the merge**: one comment on the release pull request (`gh pr comment`),
headed `Consequence notices` with the recorded base and head SHAs, then the lines (or "none"), and
ending `<!-- devstride:consequence-notices -->`. The recaps after the merge (release step 6, the
epic `Merged / Released` recap) and a session recovering an already-merged release read the newest
such comment written by the account the session runs as (`gh api user`), and repeat it, marked
"recorded at an older head <sha>" when its head is not the one that merged; they never gather or reconcile again, because after the merge the
target holds the release and the diff is empty. No such comment → "consequence notices: not
recorded before the merge". They inform the owner's yes and never condition it, standing yes included. Turned off,
`collect` repeats nothing.

## Cited by

- `skills/build-item/SKILL.md` — step 5, before the merge.
- `skills/build-item/references/epic-release-steps.md` — the release unit's own check and recap.
- `skills/release/SKILL.md` — steps 4 and 6's recaps.
- `skills/doctor/SKILL.md` — §4, the `consequenceNotices` block.
