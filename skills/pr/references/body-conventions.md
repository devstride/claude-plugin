---
load: rationale
---
# PR body conventions — the history behind four rules

Same-call reviewer request: it is what makes the cloud review overlap the local engines rather
than follow them — the single biggest wall-clock saving in the loop.

First-section title: deliberately not an "explain-like-I'm-five" abbreviation — the GitHub
webhook's item-number matcher historically had no left word boundary, so a heading token
embedding a short item number auto-linked every PR to an unrelated low-numbered item. Fixed
now, but the safe title costs nothing.

Loop marker: the draft-convention workflow from the CI cost patterns exempts pull requests
carrying it, since `gh` opens them as the operator and `github.actor` cannot tell the loop from
a person.

Attribution precedence: `prBodyTemplate.noAiAttribution` is stated as outranking the harness
because in a field run the two genuinely disagreed — the session's own instructions told the
agent to append AI attribution and a session link to every PR body while the repository's
config forbade exactly that. With no stated precedence the agent had no way to settle it, and
the operator ended up adjudicating the same conflict once per session. The config is the
repository's published choice and travels with the repository; a harness instruction belongs to
one session, so the config wins — and the run says so once, because a body that silently lacks
the attribution the harness demanded otherwise looks like the rule was simply forgotten. Commit
trailers are a separate surface with their own rule in `push`, and are untouched by this one.

## Cited by

- `skills/pr/SKILL.md` step 1's body-format pointer ("before changing a section heading, the
  marker, the same-call rule, or the attribution precedence below"), covering the section
  headings, the loop marker, the same-call reviewer request and the attribution precedence
  sentence that follows it.
