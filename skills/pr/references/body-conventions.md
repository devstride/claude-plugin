# PR body conventions — the history behind three rules

Same-call reviewer request: it is what makes the cloud review overlap the local engines rather
than follow them — the single biggest wall-clock saving in the loop.

First-section title: deliberately not an "explain-like-I'm-five" abbreviation — the GitHub
webhook's item-number matcher historically had no left word boundary, so a heading token
embedding a short item number auto-linked every PR to an unrelated low-numbered item. Fixed
now, but the safe title costs nothing.

Loop marker: the draft-convention workflow from the CI cost patterns exempts pull requests
carrying it, since `gh` opens them as the operator and `github.actor` cannot tell the loop from
a person.

## Cited by

- `skills/pr/SKILL.md` step 1's body-format paragraph.
