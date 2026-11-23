# Workflow and step contract history

Generated from [`registry.json`](registry.json) by `scripts/workflow-registry.py history --write`,
which the release's prepare step runs; never edit this page by hand. Every version of every
built-in workflow and every revision of every step contract is listed, newest first. A
version marked *shipped unused* was published as data before any released plugin could run it.

## Contents

- [alpha (`alpha`)](#alpha-alpha): version 3
- [beta (`beta`)](#beta-beta): version 1
- [Step contracts](#step-contracts): 3 contracts
  - [Unreleased](#unreleased)
  - [1.2.0, 2026-02-01](#120-2026-02-01)
  - [1.1.0, 2026-01-09](#110-2026-01-09)
  - [1.0.0, 2026-01-02](#100-2026-01-02)

## alpha (`alpha`)

Current version **3**, minimum plugin version **unreleased**, 4 row(s) recorded.

| Version | Plugin release | Date | Steps changed | Note |
| --- | --- | --- | --- | --- |
| 3 | unreleased | - | added `five` | (no note yet) |
| 2 | 1.2.0 | 2026-02-01 | added `four`, `three`; removed `two`; contract changed: `one` (first@1 → first@2) | A step \| with a pipe in its note. |
| 1 | 1.1.0 | 2026-01-09 | none | Content changed without a version bump. |
| 1 | 1.0.0 | 2026-01-02 | first version: 2 steps | The first version, written down before anything ran it. *Shipped unused: no released plugin could run it.* |

## beta (`beta`)

Current version **1**, minimum plugin version **1.2.0**, 1 row(s) recorded.

| Version | Plugin release | Date | Steps changed | Note |
| --- | --- | --- | --- | --- |
| 1 | 1.2.0 | 2026-02-01 | first version: 1 step | A second workflow. |

## Step contracts

Each contract is `name@major`. A major version only grows by additions; a *revision* is a
later published content of the same major, and a *slip* is one that changed more than that
without a new major.

### Unreleased

| Contract | Note |
| --- | --- |
| `fifth@1` | (no note yet) |

### 1.2.0, 2026-02-01

| Contract | Note |
| --- | --- |
| `first@2` | A new major: the answer changed. |

### 1.1.0, 2026-01-09

| Contract | Note |
| --- | --- |
| `first@1` (revision) | Additive revision: adds `extra`. |
| `second@1` (slip) | Content changed without a version bump: `item` changed. |

### 1.0.0, 2026-01-02

| Contract | Note |
| --- | --- |
| `first@1` | Do the first thing (first published). |
| `second@1` | Do the second thing. |
