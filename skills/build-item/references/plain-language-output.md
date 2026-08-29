# Human-facing output — simplest accurate words

Translate before display. Apply this to every user-facing question, update, handoff and final
answer, including prose returned by agents. Technical accuracy stays.

## Make the next decision easy

1. Lead with the outcome, decision or blocker. Include history only when it changes what happens
   next.
2. Use the fewest complete sentences that preserve meaning. Put one idea in each sentence. Use
   prose for one or two facts, bullets for three or more, and a table only for a real comparison.
3. Give any necessary internal step, setting, workflow, branch, status or unfamiliar acronym a
   short plain-English gloss. Keep exact commands, paths, setting keys and identifiers as evidence,
   not as the explanation.
4. Agent and tool output is evidence, not finished prose. State its conclusion and material proof
   in ordinary words. Omit orchestration, model names and reviewer chatter unless they changed
   coverage, confidence, cost or the next action.
5. Never hide risk, blast radius, uncertainty, blockers, waivers, disagreement, degraded review,
   exact targets or who acts next. Distinguish **passed**, **failed**, **not run** and **not
   configured**.

## Ask useful questions

Ask only for a decision the loop cannot safely make. Start with the decision and why it matters.
Ask sequentially when one answer changes the next. Otherwise number at most three related
decisions; each bullet states one decision and its consequence. Offer only real choices; recommend
one when the evidence supports it. For destructive, billable,
production-facing or externally visible action, state the blast radius before asking. Never imply
consent. Say what “no” or waiting does.

## End each unit with a human recap

Do not repeat the engineering report. Put its short translation first; supporting evidence may
follow. Omit empty optional lines, but always name no continuous integration (CI), skipped review,
a waiver or a required check that did not run.

**After building one item**

```text
Built
- <one to three user or system outcomes, one sentence each>
Checked
- <tests and review in plain words; name anything not run>
Next
- <merge destination, blocker or exact next action>
```

**After opening or reviewing a pull request**

Lead with `READY`, `HELD`, `BLOCKED` or `MERGED`, its link and the practical reason. Then state the
change, review result, validation state, remaining risk and one next action. A held draft says that
cloud tests have not run; a repo with no CI says **not configured**, never “green.”

**After a pull-request merge or release**

```text
Merged / Released
- <every included item and its human-visible or system effect, one sentence each>
Delivery
- <where it landed, whether it is live, and what deploy the merge triggers>
Remaining
- <none, or the exact risk, waiver or owner action>
```

Before a production merge, present the same facts and ask one explicit yes/no question. State what
“yes” deploys and what “no” leaves safely held.

**For doctor**

Each finding starts `Found: <plain problem>`. Add `Why it matters:` and `Fix:` when applicable;
put an exact command or edit after the explanation. After an attempted repair say `Changed:` and
`Result:`. Close with the readiness state, blockers, warnings, repairs still available and one next
action. Personal-setting deletion keeps its own consent question.

## Tone guardrails

Plain does not mean childish, vague or euphemistic. Prefer “convert the pull request to draft so
cloud tests stay stopped” over “park it.” Do not manufacture options or compress several risks
into one dense sentence. The goal is minimum reading for maximum correct understanding.

## Cited by

- `skills/branch-feature/SKILL.md`
- `skills/branch-hotfix/SKILL.md`
- `skills/build-item/SKILL.md`
- `skills/ci-audit/SKILL.md`
- `skills/comprehend-plan/SKILL.md`
- `skills/create-defect/SKILL.md`
- `skills/create-story/SKILL.md`
- `skills/doctor/SKILL.md`
- `skills/insert-defect/SKILL.md`
- `skills/insert-story/SKILL.md`
- `skills/plan/SKILL.md`
- `skills/pr/SKILL.md`
- `skills/push/SKILL.md`
- `skills/rationalize-gantt/SKILL.md`
- `skills/rebalance/SKILL.md`
- `skills/release/SKILL.md`
- `skills/review/SKILL.md`
- `skills/setup/SKILL.md`
- `skills/ultracode-build/SKILL.md`
- `skills/update/SKILL.md`
