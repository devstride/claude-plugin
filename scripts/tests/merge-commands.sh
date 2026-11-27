#!/bin/bash
# scripts/tests/merge-commands.sh — the git commands the merge and its stops spell out, run exactly
# as the references write them (read from the files, placeholders filled in) in throwaway
# repositories with a bare origin: the exact-landing test, the fast merge from a detached HEAD at
# the recorded base commit beside a worktree holding the base (and a peer worktree landing in
# between) and its return to the story branch after a refused push, the sync, story branch and its
# first push, its re-run check on origin (full and single-branch clones, a remote branch deleted and
# pruned, only archive/<branch> on origin) and new epic branch commands beside that worktree, the excluded-paths
# re-route's rebase and push, and the durable proof's carry command. Each case also shows the fault the old wording had. No network.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FAIL=0; ok() { echo "  ok   $1"; }; bad() { echo "  FAIL $1"; FAIL=1; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
export PYTHONDONTWRITEBYTECODE=1
unset GIT_DIR GIT_WORK_TREE

cat > "$WORK/cases.py" <<'PY'
import os, re, subprocess, sys

ROOT, WORK = sys.argv[1], sys.argv[2]
MP = os.path.join(ROOT, "skills/merge-story/references/merge-paths.md")
RS = os.path.join(ROOT, "skills/build-item/references/run-stops.md")
made = [0]
ENV = dict(os.environ, GIT_AUTHOR_NAME="Test", GIT_AUTHOR_EMAIL="test@example.com", GIT_COMMITTER_NAME="Test",
           GIT_COMMITTER_EMAIL="test@example.com", GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM="1")


def check(label, good, detail=""):
    print(("ok   " if good else "FAIL ") + label + ("" if good else " -> %s" % (detail,)))


def flat(path):
    return re.sub(r"\s+", " ", open(path, encoding="utf-8").read().replace("**", ""))


def command(path, starts, after=None):
    """The one backticked command in `path` that starts with `starts`, white space collapsed;
    with `after`, read from that text on (a file whose earlier code fences leave an odd count)."""
    return spelled(flat(path), starts, after, os.path.basename(path))


def spelled(text, starts, after=None, name="the text"):
    """`command` over text already read and flattened, so a case can run an in-memory edit of it."""
    if after is not None:
        text = text[text.index(after) + len(after):] if after in text else ""
    found = [span for span in re.findall(r"`([^`]+)`", text) if span.startswith(starts)]
    if len(found) != 1:
        raise SystemExit("FAIL %s holds %d commands starting %r" % (name, len(found), starts))
    return found[0]


def fresh(name):
    made[0] += 1
    path = os.path.join(WORK, "%s-%d" % (name, made[0]))
    os.makedirs(path)
    return path


def sh(repo, script, check_rc=True):
    done = subprocess.run(["bash", "-c", script], cwd=repo, capture_output=True, text=True, env=ENV)
    if check_rc and done.returncode != 0:
        raise RuntimeError("%s: %s" % (script, done.stderr))
    return done


def git(repo, *args):
    return sh(repo, " ".join("'%s'" % a for a in ("git",) + args)).stdout.strip()


def commit(repo, name, text, message):
    with open(os.path.join(repo, name), "w") as out:
        out.write(text)
    git(repo, "add", "-A")
    git(repo, "commit", "-q", "-m", message)
    return git(repo, "rev-parse", "HEAD")


def setup():
    """A bare origin with main; a clone holding a pushed story branch `feature` off main."""
    bare = fresh("origin")
    git(bare, "init", "-q", "--bare", "-b", "main")
    repo = fresh("repo")
    git(repo, "init", "-q", "-b", "main")
    commit(repo, "readme.txt", "one\n", "first")
    git(repo, "remote", "add", "origin", bare)
    git(repo, "push", "-q", "-u", "origin", "main")
    git(repo, "checkout", "-q", "-b", "feature")
    story = commit(repo, "export.txt", "export\n", "add the export")
    git(repo, "push", "-q", "-u", "origin", "feature")
    return bare, repo, story


def fresh_clone(bare, single=True):
    clone = fresh("single" if single else "full")
    git(clone, "clone", "-q", *((["--single-branch", "--branch", "main"] if single else []) + [bare, "."]))
    return clone


def other_author(bare, message):
    other = fresh("other")
    git(other, "clone", "-q", bare, ".")
    git(other, "checkout", "-q", "main")
    commit(other, "upstream-%d.txt" % made[0], "theirs\n", message)
    git(other, "push", "-q", "origin", "main")


# --- Already landed: three answers, exactly `commit`, landed but unproven, or nothing ----------
MERGED = command(MP, "git rev-list --first-parent --parents origin/<workingBase>")
TIP = command(MP, "git rev-parse origin/<workingBase>")
CARRIED = command(MP, "git merge-base --is-ancestor <commit> origin/<workingBase>")
OLD = "git rev-list --parents origin/%s | awk -v c=%s '$3 == c { print $1; exit }'"  # the round before: any merge, anywhere
def filled(text, base, commit_id):
    return text.replace("<workingBase>", base).replace("<commit>", commit_id)
def landing(repo, commit_id, base="main"):
    """The landing test as the reference spells it, in its order: (exact, what), (unproven, None) or (nothing, None)."""
    git(repo, "fetch", "-q", "origin")
    merge = sh(repo, filled(MERGED, base, commit_id)).stdout.strip()
    if merge:
        return "exact", merge
    if sh(repo, filled(TIP, base, commit_id)).stdout.strip() == commit_id:
        return "exact", commit_id
    if sh(repo, filled(CARRIED, base, commit_id), check_rc=False).returncode == 0:
        return "unproven", None
    return "nothing", None
def old(repo, commit_id, base="main"):
    return sh(repo, OLD % (base, commit_id)).stdout.strip()

bare, repo, story = setup()
git(repo, "checkout", "-q", "main")
git(repo, "merge", "-q", "--no-ff", "-m", "merge: I123", story)
merge = git(repo, "rev-parse", "HEAD")
git(repo, "push", "-q", "origin", "main")
check("the landing test names the two-parent merge of exactly the story commit on the base's own line", landing(repo, story) == ("exact", merge), landing(repo, story))
bare, repo, story = setup()
git(repo, "checkout", "-q", "main"); git(repo, "merge", "-q", "--ff-only", story); git(repo, "push", "-q", "origin", "main")
check("... and the story commit itself when it is the base's tip", landing(repo, story) == ("exact", story), landing(repo, story))
bare, repo, story = setup()
past = commit(repo, "export.txt", "export\nunchecked change\n", "an unchecked commit on top of the checked one")
git(repo, "checkout", "-q", "main"); git(repo, "merge", "-q", "--ff-only", past); git(repo, "push", "-q", "origin", "main")
check("a base fast-forwarded past the checked commit is landed but unproven, for a person", landing(repo, story) == ("unproven", None), landing(repo, story))
# --- an unproven landing: everything the base gained listed, and the story branch hint ------------
WR = os.path.join(ROOT, "skills/run-workflow/references/workflow-runner.md")
GAINED = command(MP, "git log --oneline <commit>..origin/<workingBase>")
STORY_LATER = command(MP, "git rev-list <commit>..<story-ref>")
ON_BASE = command(MP, "git merge-base --is-ancestor <that> origin/<workingBase>")
check("(run-stops.md and workflow-runner.md spell the same commands)",
      all("`%s`" % c in flat(RS) and "`%s`" % c in flat(WR) for c in (GAINED, STORY_LATER, ON_BASE)))
LATER = "the later story commit"
def later_shape(shape):
    """The checked commit C landed with D, a later commit of the story branch, or (F2) without it."""
    bare, repo, story = setup()
    commit(repo, "export.txt", "export\nunchecked change\n", LATER); git(repo, "push", "-q", "origin", "feature")
    git(repo, "checkout", "-q", "main")
    if shape == "B":  # the loop's own --no-ff merge, at a later head
        git(repo, "merge", "-q", "--no-ff", "-m", "merge: the story", "feature")
    elif shape == "C2":  # a release fast-forward carrying a merge of the later head
        git(repo, "checkout", "-q", "-b", "develop"); git(repo, "merge", "-q", "--no-ff", "-m", "merge into develop", "feature")
        git(repo, "checkout", "-q", "main"); git(repo, "merge", "-q", "--ff-only", "develop")
    elif shape == "D":  # stacked: the story merged into another branch, which lands
        git(repo, "checkout", "-q", "-b", "stack"); git(repo, "merge", "-q", "--no-ff", "-m", "take the story", "feature")
        commit(repo, "stack.txt", "stack\n", "stack work")
        git(repo, "checkout", "-q", "main"); git(repo, "merge", "-q", "--no-ff", "-m", "merge the stack", "stack")
    elif shape == "E":  # an octopus
        git(repo, "checkout", "-q", "-b", "other"); commit(repo, "other.txt", "other\n", "other work")
        git(repo, "checkout", "-q", "main"); git(repo, "merge", "-q", "--no-ff", "-m", "octopus", "feature", "other")
    else:  # F2: C landed, then only another author's merged work
        git(repo, "merge", "-q", "--ff-only", story)
        git(repo, "checkout", "-q", "-b", "theirs"); commit(repo, "theirs.txt", "theirs\n", "another author: their work")
        git(repo, "checkout", "-q", "main"); git(repo, "merge", "-q", "--no-ff", "-m", "merge their work", "theirs")
    git(repo, "push", "-q", "origin", "main")
    return repo, story
def later_found(repo, story):
    """What the person sees: the subjects the base gained, and the commits the hint finds on it."""
    listed = [line.split(" ", 1)[1] for line in sh(repo, filled(GAINED, "main", story)).stdout.strip().split("\n") if line]
    found = [c for c in sh(repo, STORY_LATER.replace("<commit>", story).replace("<story-ref>", "origin/feature")).stdout.split()
             if sh(repo, filled(ON_BASE, "main", story).replace("<that>", c), check_rc=False).returncode == 0]
    return listed, found
for shape, how in (("B", "a --no-ff merge at a later head"), ("C2", "a release fast-forward carrying a later head's merge"),
                   ("D", "a stacked branch"), ("E", "an octopus merge")):
    repo, story = later_shape(shape)
    listed, found = later_found(repo, story)
    check("%s: unproven, the listing shows the later story commit, and the hint finds it on the base" % how,
          landing(repo, story) == ("unproven", None) and LATER in listed and found == [git(repo, "rev-parse", "feature")], (listed, found))
    if shape == "B":
        old_listed = sh(repo, "git log --first-parent --oneline %s..origin/main" % story).stdout
        check("(the old --first-parent listing showed only the merge commit)", LATER not in old_listed, old_listed)
repo, story = later_shape("F2")
listed, found = later_found(repo, story)
check("only another author's work past C: listed (their merge too) without any story commit, and the hint finds none, so done naming C is valid",
      landing(repo, story) == ("unproven", None) and listed == ["merge their work", "another author: their work"] and found == [], (listed, found))
# (1) the base merged into the story with changes of its own, then fast-forwarded onto the base, story refs deleted
bare, repo, story = setup()
other_author(bare, "upstream U")
git(repo, "fetch", "-q", "origin")
git(repo, "merge", "-q", "--no-commit", "--no-ff", "origin/main")
with open(os.path.join(repo, "export.txt"), "a") as out:
    out.write("a change made while resolving the merge\n")
git(repo, "add", "-A"); git(repo, "commit", "-q", "-m", "merge the base into the story")
git(repo, "push", "-q", "origin", "feature:main")
git(repo, "push", "-q", "origin", "--delete", "feature"); git(repo, "checkout", "-q", "main"); git(repo, "branch", "-q", "-D", "feature")
listed = [line.split(" ", 1)[1] for line in sh(repo, filled(GAINED, "main", story)).stdout.strip().split("\n") if line]
check("a merge made on the story branch and fast-forwarded onto the base: unproven, and the listing shows that merge for the person to account for",
      landing(repo, story) == ("unproven", None) and "merge the base into the story" in listed and "upstream U" in listed, listed)
check("(the --no-merges listing hid it, showing only the upstream commit)",
      sh(repo, "git log --no-merges --format=%%s %s..origin/main" % story).stdout.split("\n")[:1] == ["upstream U"])
# (2) the story rebased onto upstream U as C', while a release merge R(C, U) lands the original C
bare, repo, story = setup()
other_author(bare, "upstream U")
git(repo, "fetch", "-q", "origin")
upstream = git(repo, "rev-parse", "origin/main")
git(repo, "checkout", "-q", "-b", "release", story); git(repo, "merge", "-q", "--no-ff", "-m", "release merge", upstream)
git(repo, "checkout", "-q", "main"); git(repo, "merge", "-q", "--ff-only", "release"); git(repo, "push", "-q", "origin", "main")
git(repo, "checkout", "-q", "feature"); git(repo, "rebase", "-q", upstream); git(repo, "push", "-q", "-f", "origin", "feature")
listed, found = later_found(repo, story)
check("a rebased story beside a release landing the original C: the listing shows only the release merge and the upstream commit",
      landing(repo, story) == ("unproven", None) and listed == ["release merge", "upstream U"], listed)
check("... and the hint's one hit is U, an upstream commit the rebased branch merely contains: one to look at, not story work",
      found == [upstream] and git(repo, "log", "-1", "--format=%s", upstream) == "upstream U"
      and "an upstream commit the story branch merely contains (through a rebase or a base merge) is not story work" in flat(RS), found)
bare, repo, story = setup()
later = commit(repo, "export.txt", "export\nunchecked change\n", "a later commit inside the merge step")
git(repo, "checkout", "-q", "main"); git(repo, "merge", "-q", "--no-ff", "-m", "merge: I123", later); git(repo, "push", "-q", "origin", "main")
check("a later commit that landed carrying the story commit is landed but unproven", landing(repo, story) == ("unproven", None), landing(repo, story))
bare, repo, story = setup()
git(repo, "checkout", "-q", "main"); git(repo, "merge", "-q", "--ff-only", story)
commit(repo, "notes.txt", "someone else's\n", "work landed on top"); git(repo, "push", "-q", "origin", "main")
check("the checked commit fast-forwarded and then built on is landed but unproven", landing(repo, story) == ("unproven", None), landing(repo, story))
bare, repo, story = setup()
check("a story commit that never landed is nothing landed", landing(repo, story) == ("nothing", None), landing(repo, story))
# a stacked branch: the story merged into another branch, which then gains an unchecked commit and lands
bare, repo, story = setup()
git(repo, "checkout", "-q", "-b", "stack", "main")
git(repo, "merge", "-q", "--no-ff", "-m", "take the story into the stack", story)
carried = git(repo, "rev-parse", "HEAD")
commit(repo, "stack.txt", "unchecked\n", "an unchecked commit on the stack")
git(repo, "checkout", "-q", "main"); git(repo, "merge", "-q", "--no-ff", "-m", "merge the stack", "stack"); git(repo, "push", "-q", "origin", "main")
check("a story merged into another branch that gained unchecked work and then landed is unproven, for a person",
      landing(repo, story) == ("unproven", None), landing(repo, story))
check("(the any-history test named that other branch's merge as the story's exact landing)", old(repo, story) == carried, old(repo, story))
# an octopus merge carrying the story onto the base
bare, repo, story = setup()
git(repo, "checkout", "-q", "-b", "other", "main"); commit(repo, "other.txt", "other\n", "another branch")
git(repo, "checkout", "-q", "main"); git(repo, "merge", "-q", "--no-ff", "-m", "octopus", story, "other")
octopus = git(repo, "rev-parse", "HEAD"); git(repo, "push", "-q", "origin", "main")
check("an octopus merge carrying the story is unproven, for a person", landing(repo, story) == ("unproven", None), landing(repo, story))
check("(the any-history test took it as exact)", old(repo, story) == octopus, old(repo, story))
# a release fast-forwards the train to develop: the story's merge is now off the train's first-parent line
bare, repo, story = setup()
git(repo, "checkout", "-q", "-b", "train", "main"); git(repo, "push", "-q", "-u", "origin", "train")
git(repo, "merge", "-q", "--no-ff", "-m", "merge: I123 into train", story)
merge = git(repo, "rev-parse", "HEAD"); git(repo, "push", "-q", "origin", "train")
check("(before the release, the train's own merge is the exact landing)", landing(repo, story, "train") == ("exact", merge), landing(repo, story, "train"))
git(repo, "checkout", "-q", "main"); commit(repo, "develop.txt", "other develop work\n", "other develop work")
git(repo, "merge", "-q", "--no-ff", "-m", "Merge the release train", "train"); git(repo, "push", "-q", "origin", "main")
git(repo, "checkout", "-q", "train"); git(repo, "merge", "-q", "--ff-only", "main"); git(repo, "push", "-q", "origin", "train")
check("after a release fast-forwards the train, the landing is unproven: a person confirms, since topology cannot tell it from unchecked work",
      landing(repo, story, "train") == ("unproven", None), landing(repo, story, "train"))
check("the unproven answer says exactly that, and never that the code went unchecked",
      "landed, but this check cannot prove how" in flat(MP) and "landed, but this check cannot prove how" in flat(RS)
      and "never checked or reviewed" not in flat(RS) and "carrying <commit>" not in flat(MP))

# --- the fast merge: on a detached HEAD at the recorded base commit, never on a branch another worktree holds
RECORD = command(MP, "git rev-parse --verify origin/<workingBase>").replace("<workingBase>", "main")
PROVE = command(MP, "git merge-base --is-ancestor <tip> <commit>")
DETACH = command(MP, "git checkout --detach <tip>")
PUSH = command(MP, "git push origin HEAD:refs/heads/<workingBase>").replace("<workingBase>", "main")
BACK = command(MP, "git checkout <branch>", "A refused push →").replace("<branch>", "feature")
check("the fast merge never checks out, pulls or resets the base branch, never detaches at the shared ref, and never keeps the tip in a shell variable",
      "git checkout <workingBase>" not in flat(MP) and "git pull" not in flat(MP) and "git reset --hard" not in flat(MP)
      and "$tip" not in flat(MP) and "git checkout --detach origin/" not in flat(MP))
def linked(repo):
    """A second checkout of the same repository holding main, as a pool of linked worktrees does."""
    path = os.path.join(fresh("linked"), "wt")
    git(repo, "worktree", "add", "-q", path, "main")
    return path
def base_moved(repo, story):
    """"Base moved" as merge-paths.md spells it: the fetch, the base recorded once as <tip>, the ancestry test."""
    git(repo, "fetch", "-q", "origin")
    tip = sh(repo, RECORD).stdout.strip()
    return tip, sh(repo, PROVE.replace("<tip>", tip).replace("<commit>", story), check_rc=False).returncode == 0
def detach(repo, tip, story):
    return sh(repo, DETACH.replace("<tip>", tip).replace("<commit>", story), check_rc=False).returncode == 0
bare, repo, story = setup()
holder = linked(repo)
check("(the old by-name checkout stops while another worktree holds the base)",
      sh(repo, "git checkout main && git pull --ff-only", check_rc=False).returncode != 0)
tip, proven = base_moved(repo, story)
proven = proven and detach(repo, tip, story)
git(repo, "merge", "-q", "--no-ff", "-m", "merge: I123", story)
merge = git(repo, "rev-parse", "HEAD")
pushed = sh(repo, PUSH, check_rc=False).returncode == 0
git(repo, "fetch", "-q", "origin")
check("with another worktree on the base, the fast merge lands from a detached HEAD: the base's new tip is the merge of the recorded tip and exactly the story commit",
      proven and pushed and git(repo, "rev-parse", "origin/main") == merge and git(repo, "rev-parse", "%s^1" % merge) == tip
      and git(repo, "rev-parse", "%s^2" % merge) == story and git(repo, "rev-parse", "--abbrev-ref", "HEAD") == "HEAD",
      (proven, pushed, merge))
check("... and the other worktree's checkout of the base is left alone", git(holder, "rev-parse", "HEAD") == tip)
bare, repo, story = setup()
linked(repo)
tip, proven = base_moved(repo, story)
detach(repo, tip, story)
git(repo, "merge", "-q", "--no-ff", "-m", "merge: I123", story)
other_author(bare, "the remote moves, so the push is refused")
refused = sh(repo, PUSH, check_rc=False).returncode != 0
sh(repo, BACK)  # each command its own shell call, as a step runs them
git(repo, "fetch", "-q", "origin")
check("a refused push goes back to the story branch: HEAD is the story commit, off the unpushed merge, nothing reset",
      refused and git(repo, "rev-parse", "--abbrev-ref", "HEAD") == "feature" and git(repo, "rev-parse", "HEAD") == story
      and git(repo, "rev-parse", "origin/feature") == story, refused)
check("... and the fetch shows the base moved past the recorded tip, so the merge answers REFRESHED",
      git(repo, "rev-parse", "origin/main") != tip)

# a peer worktree OF THE SAME REPOSITORY lands and fetches between "Base moved" and the merge: linked worktrees
# share refs/remotes, so its fetch moves origin/main under this checkout
def peer_between(use_ref):
    bare, repo, story = setup()
    peer = linked(repo)
    tip, proven = base_moved(repo, story)
    commit(peer, "peer.txt", "peer\n", "a peer story lands meanwhile")
    git(peer, "push", "-q", "origin", "main"); git(peer, "fetch", "-q", "origin")
    shared_moved = git(repo, "rev-parse", "origin/main") != tip
    if use_ref:  # the round-2 form: detach at the shared ref
        sh(repo, "git checkout --detach origin/main")
    else:
        proven = proven and detach(repo, tip, story)
    git(repo, "merge", "-q", "--no-ff", "-m", "merge: I123", story)
    pushed = sh(repo, PUSH, check_rc=False).returncode == 0
    if not pushed:
        sh(repo, BACK)
    git(repo, "fetch", "-q", "origin")
    return proven, shared_moved, pushed, git(repo, "rev-parse", "origin/main") != tip
proven, shared_moved, pushed, moved = peer_between(False)
check("a peer worktree landing and fetching after the ancestry check: the merge sits on the recorded tip, the push is refused and the fetch shows the base moved (REFRESHED), never a landing",
      proven and shared_moved and not pushed and moved, (proven, shared_moved, pushed, moved))
proven, shared_moved, pushed, moved = peer_between(True)
check("(detaching at origin/<workingBase>, which the peer's fetch had moved, merged onto its unchecked tip and the push landed)",
      proven and shared_moved and pushed, (proven, shared_moved, pushed))

# --- sync, a new story branch and a new epic branch, while another worktree holds the base ---------
SYNC = command(os.path.join(ROOT, "skills/sync-base/SKILL.md"), "git fetch origin && git checkout --detach").replace("<workingBase>", "main")
BF = os.path.join(ROOT, "skills/branch-feature/SKILL.md")
BF_TEXT = flat(BF)
UPSTREAM = "git config branch.<b>.remote; git config branch.<b>.merge"  # what the skill's upstream settings are
def upstream(repo, branch):
    return sh(repo, UPSTREAM.replace("<b>", branch), check_rc=False).stdout.split()
def cut_and_push(repo, text, branch, base):
    """The creation step as `text` spells it, each command its own call: the cut, then its first push.
    Gives the branch's upstream settings after the cut and after the push."""
    sh(repo, spelled(text, "git checkout --no-track -b <new-branch>").replace("<new-branch>", branch).replace("<working base>", base))
    after_cut = upstream(repo, branch)
    sh(repo, spelled(text, "git push", "## Steps").replace("<new-branch>", branch))
    return after_cut, upstream(repo, branch)
def own_upstream(cut, pushed, branch):
    return cut == [] and pushed == ["origin", "refs/heads/%s" % branch]
EPIC = command(os.path.join(ROOT, "skills/build-item/references/parallel-building.md"), "git fetch origin && git push origin origin/<from>")
bare, repo, story = setup()
linked(repo)
other_author(bare, "the base moves on")
sh(repo, SYNC)
check("the sync returns the checkout to the base detached at its fresh remote tip, beside a worktree holding it",
      git(repo, "rev-parse", "--abbrev-ref", "HEAD") == "HEAD" and git(repo, "rev-parse", "HEAD") == git(repo, "rev-parse", "origin/main"))
sh(repo, EPIC.replace("<from>", "main").replace("<epic branch>", "jane/26-11-26/epic-42-export"))
git(repo, "fetch", "-q", "origin")
check("a new epic branch is created on the remote from the base without being checked out here",
      git(repo, "rev-parse", "origin/jane/26-11-26/epic-42-export") == git(repo, "rev-parse", "origin/main")
      and git(repo, "rev-parse", "--abbrev-ref", "HEAD") == "HEAD"
      and sh(repo, "git rev-parse --verify --quiet refs/heads/jane/26-11-26/epic-42-export", check_rc=False).returncode != 0)
cut, pushed = cut_and_push(repo, BF_TEXT, "jane/26-11-26/I43-next", "jane/26-11-26/epic-42-export")
check("the next story branch is cut from the remote epic branch, never from a local checkout of it, and tracks nothing after the cut (never the shared base)",
      git(repo, "rev-parse", "--abbrev-ref", "HEAD") == "jane/26-11-26/I43-next"
      and git(repo, "rev-parse", "HEAD") == git(repo, "rev-parse", "origin/jane/26-11-26/epic-42-export") and cut == [], cut)
check("... and the creation step's own push publishes it with its own upstream: origin, refs/heads/<the new branch>",
      own_upstream(cut, pushed, "jane/26-11-26/I43-next")
      and git(bare, "rev-parse", "jane/26-11-26/I43-next") == git(repo, "rev-parse", "HEAD"), pushed)
bare, repo, story = setup()
no_u = BF_TEXT.replace("`git push -u origin <new-branch>`", "`git push origin <new-branch>`")
cut, pushed = cut_and_push(repo, no_u, "jane/26-11-26/I44-new", "main")
check("(mutation: without -u in the creation push, the new branch has no upstream of its own, and that check fails)",
      no_u != BF_TEXT and not own_upstream(cut, pushed, "jane/26-11-26/I44-new"), pushed)
git(repo, "checkout", "-q", "--detach", "origin/main")
sh(repo, "git checkout -q -b tracked origin/main")
check("(the old cut made the shared base the story branch's upstream)", upstream(repo, "tracked") == ["origin", "refs/heads/main"])
# the re-run: origin asked for exactly the branch, every time, then the pull; in a full clone and in one tracking only the base
RERUN = spelled(BF_TEXT, "if git ls-remote")
def rerun(clone, branch, text=RERUN):
    """The re-run's one command as spelled (or an in-memory edit of it), then its pull:
    True when it succeeded, origin holds the branch at this commit, and the upstream settings name it."""
    ran = sh(clone, text.replace("<branch>", branch), check_rc=False).returncode == 0
    pulled = ran and sh(clone, "git pull -q --ff-only", check_rc=False).returncode == 0
    there = sh(clone, "git ls-remote origin refs/heads/%s" % branch, check_rc=False).stdout.split()[:1] == [git(clone, "rev-parse", branch)]
    return pulled and there and upstream(clone, branch) == ["origin", "refs/heads/%s" % branch]
check("the re-run asks origin for the exact ref, never a bare name", "ls-remote --exit-code origin refs/heads/<branch>" in RERUN, RERUN)
for single_branch in (False, True):
    kind = "a clone tracking only the base" if single_branch else "a full clone"
    bare, repo, story = setup()
    clone = fresh_clone(bare, single=single_branch)
    git(clone, "fetch", "-q", "origin", "+refs/heads/feature:refs/heads/feature")  # the story branch, here and on origin
    git(clone, "config", "branch.feature.remote", "origin"); git(clone, "config", "branch.feature.merge", "refs/heads/main")  # left tracking the base
    git(clone, "checkout", "-q", "feature")
    check("%s: a story branch left tracking the base and on origin gets its own upstream from the config sets" % kind,
          rerun(clone, "feature") and git(bare, "rev-parse", "feature") == story, upstream(clone, "feature"))
    git(clone, "checkout", "-q", "-b", "only-here")
    check("%s: a story branch only here is published by the push, which sets its upstream" % kind,
          rerun(clone, "only-here") and git(bare, "rev-parse", "only-here") == story, upstream(clone, "only-here"))
    if single_branch:
        check("(the old `git branch -u origin/<branch>` fails in a clone tracking only the base)",
              sh(clone, "git branch -u origin/feature feature", check_rc=False).returncode != 0)
def deleted_and_pruned():
    """The story branch's upstream settings name origin's copy, which was deleted and then pruned here."""
    bare, repo, story = setup()
    git(bare, "update-ref", "-d", "refs/heads/feature")
    git(repo, "fetch", "-q", "--prune", "origin")
    gone = sh(repo, "git rev-parse --verify --quiet refs/remotes/origin/feature", check_rc=False).returncode != 0
    return repo, gone and upstream(repo, "feature") == ["origin", "refs/heads/feature"]
repo, premise = deleted_and_pruned()
check("upstream settings still naming a remote branch that was deleted and pruned: the re-run pushes it back and the pull succeeds",
      premise and rerun(repo, "feature"), upstream(repo, "feature"))
repo, premise = deleted_and_pruned()
old_skip = 'git config branch.<branch>.merge | grep -qx refs/heads/<branch> || ' + RERUN  # the old order: settings first
check("(mutation: trusting matching settings skips the remote check, so the pull fails and that check fails)",
      premise and not rerun(repo, "feature", old_skip))
def only_archived():
    """A story branch only here, while origin holds archive/<the same name>."""
    bare, repo, story = setup()
    git(repo, "checkout", "-q", "-b", "jane/26-11-26/I45-later")
    git(repo, "push", "-q", "origin", "HEAD:refs/heads/archive/jane/26-11-26/I45-later")
    return bare, repo
bare, repo = only_archived()
check("only archive/<branch> on origin is treated as absent: the re-run pushes the branch itself and points its upstream there",
      rerun(repo, "jane/26-11-26/I45-later"), upstream(repo, "jane/26-11-26/I45-later"))
bare, repo = only_archived()
unanchored = RERUN.replace("--exit-code origin refs/heads/<branch>", "--exit-code --heads origin <branch>")
check("(mutation: the bare name matches archive/<branch>, so nothing is pushed and that check fails)",
      unanchored != RERUN and not rerun(repo, "jane/26-11-26/I45-later", unanchored))

# --- the excluded-paths re-route: one shell call, the named branch rebased, only its ref pushed ----
REROUTE = command(RS, "git fetch origin && pushed=$(git rev-parse --verify --quiet refs/remotes/origin/<branch>)")
FIRST = command(RS, "git rebase --onto origin/<baseBranch> origin/<train> <branch> && git push origin")
fill = lambda text: text.replace("<branch>", "feature").replace("<baseBranch>", "main").replace("<train>", "train")
def reroute_repo(push_feature=True):
    bare = fresh("origin")
    git(bare, "init", "-q", "--bare", "-b", "main")
    repo = fresh("repo")
    git(repo, "init", "-q", "-b", "main")
    commit(repo, "readme.txt", "one\n", "first")
    git(repo, "checkout", "-q", "-b", "train"); commit(repo, "train.txt", "train work\n", "on the train")
    git(repo, "checkout", "-q", "-b", "feature"); commit(repo, "migration.sql", "alter table\n", "the one-off")
    git(repo, "checkout", "-q", "-b", "other", "main"); commit(repo, "other.txt", "pushed\n", "another branch")
    git(repo, "remote", "add", "origin", bare)
    git(repo, "push", "-q", "origin", "main", "train", "other", *(["feature"] if push_feature else []))
    git(repo, "fetch", "-q", "origin")
    git(repo, "reset", "-q", "--hard", "main")  # `other` now differs from its pushed copy
    git(repo, "config", "push.default", "matching")
    git(repo, "checkout", "-q", "main")          # the story branch is not the one checked out
    return bare, repo
check("the re-route's lease is read and used inside the one command it is spelled in", "$pushed" in REROUTE and "--force-with-lease=refs/heads/<branch>:$pushed" in REROUTE)
bare, repo = reroute_repo()
other_before = git(repo, "rev-parse", "origin/other")
sh(repo, fill(REROUTE))
git(repo, "fetch", "-q", "origin")
check("the re-route, as one call, rebases the named story branch off the train, whatever is checked out",
      git(repo, "rev-parse", "origin/feature") == git(repo, "rev-parse", "feature")
      and sh(repo, "git merge-base --is-ancestor origin/train feature", check_rc=False).returncode != 0
      and git(repo, "rev-parse", "feature^") == git(repo, "rev-parse", "main"))
check("... and pushes only that ref, leaving another diverged branch alone under push.default=matching",
      git(repo, "rev-parse", "origin/other") == other_before)
bare, repo = reroute_repo()
git(repo, "checkout", "-q", "feature")
sh(repo, "git rebase -q --onto origin/main origin/train && git push -q --force-with-lease", check_rc=False)
git(repo, "fetch", "-q", "origin")
check("(the old bare push forced the other branch too)", git(repo, "rev-parse", "origin/other") != other_before)
bare, repo = reroute_repo()
lease = fill(REROUTE).replace("$pushed", "0" * 40).replace("pushed=$(", "true $(")
check("the push's lease names the one ref: a stale expected value is refused",
      sh(repo, lease, check_rc=False).returncode != 0)
bare, repo = reroute_repo(push_feature=False)
before = git(repo, "rev-parse", "feature")
done = sh(repo, fill(REROUTE), check_rc=False)
check("a branch never pushed stops the one call before the rebase, with nothing moved",
      done.returncode != 0 and git(repo, "rev-parse", "feature") == before)
check("(the old separate read printed the name itself as the lease value)",
      sh(repo, "git rev-parse origin/feature", check_rc=False).stdout.strip() == "origin/feature")
sh(repo, fill(FIRST))
git(repo, "fetch", "-q", "origin")
check("... and its own instruction, a plain first push, moves and publishes it",
      git(repo, "rev-parse", "origin/feature") == git(repo, "rev-parse", "feature") and git(repo, "rev-parse", "feature^") == git(repo, "rev-parse", "main")
      and git(repo, "rev-parse", "origin/other") != git(repo, "rev-parse", "other"))

# --- wrong-branch recovery: fetch into a tracking ref, then check the story branch out ----------
BI = os.path.join(ROOT, "skills/run-workflow/references/workflow-runner.md")  # build-item points here for it
AT = "send the same request again:"
FETCH = command(BI, 'git fetch origin "+refs/heads/<branch>:refs/remotes/origin/<branch>"', AT)
FROM_LOCAL = command(BI, "git checkout <branch>", AT)
FROM_REMOTE = command(BI, "git checkout -b <branch> origin/<branch> && git config", AT)
def recover(clone, branch="feature"):
    """The recovery as the runner's reference writes it for build-item: the tracking-ref fetch, then the checkout that fits."""
    sh(clone, FETCH.replace("<branch>", branch), check_rc=False)
    here = sh(clone, "git rev-parse --verify --quiet refs/heads/%s" % branch, check_rc=False).returncode == 0
    sh(clone, (FROM_LOCAL if here else FROM_REMOTE).replace("<branch>", branch))
def rules(clone):
    return sh(clone, "git config --get-all remote.origin.fetch", check_rc=False).stdout
bare, repo, story = setup()
single = fresh_clone(bare)
check("(a clone tracking only the base: the old plain fetch fills FETCH_HEAD and the checkout fails)",
      sh(single, "git fetch -q origin feature && git checkout -q feature", check_rc=False).returncode != 0)
for single_branch in (True, False):
    bare, repo, story = setup()
    clone = fresh_clone(bare, single=single_branch)
    kind = "a clone tracking only the base" if single_branch else "a full clone"
    side = fresh("worktree")
    git(clone, "worktree", "add", "-q", "-b", "side", side, "origin/main")  # a second worktree of the same repository
    before = rules(clone)
    recover(clone)
    check("%s: the recovery checks the story branch out at its pushed commit, its fetch rules unchanged" % kind,
          git(clone, "rev-parse", "--abbrev-ref", "HEAD") == "feature" and git(clone, "rev-parse", "HEAD") == story
          and rules(clone) == before, (rules(clone), before))
    commit(clone, "later.txt", "later\n", "a later commit on the recovered branch")
    check("... a later bare git push publishes it",
          sh(clone, "git push -q", check_rc=False).returncode == 0 and git(bare, "rev-parse", "feature") == git(clone, "rev-parse", "HEAD"))
    git(clone, "push", "-q", "origin", "--delete", "feature")  # the merge deletes the story branch
    other_author(bare, "the base moves on")
    git(clone, "checkout", "-q", "main")
    check("... and once the story branch is deleted, a plain fetch and a base pull still work, here and in another worktree",
          sh(clone, "git fetch -q origin", check_rc=False).returncode == 0 and sh(clone, "git pull -q --ff-only", check_rc=False).returncode == 0
          and sh(side, "git fetch -q origin", check_rc=False).returncode == 0 and sh(side, "git pull -q --ff-only", check_rc=False).returncode == 0)
bare, repo, story = setup()
broken = fresh_clone(bare)
sh(broken, "git remote set-branches --add origin feature && " + FETCH.replace("<branch>", "feature") + " && git checkout -q feature")
git(broken, "push", "-q", "origin", "--delete", "feature"); git(broken, "checkout", "-q", "main")
check("(the set-branches recipe left a fetch rule that fails every plain fetch once the branch is deleted)",
      sh(broken, "git fetch -q origin", check_rc=False).returncode != 0)
plain = fresh_clone(bare)
git(repo, "push", "-q", "origin", "feature")
sh(plain, FETCH.replace("<branch>", "feature") + " && git checkout -q -b feature origin/feature")
check("(a checkout without the upstream config, in a clone tracking only the base, leaves the bare push failing)",
      sh(plain, "git push -q", check_rc=False).returncode != 0)
local_only = fresh_clone(bare)
git(local_only, "checkout", "-q", "-b", "local-only"); git(local_only, "checkout", "-q", "main")
before = rules(local_only)
failed = sh(local_only, FETCH.replace("<branch>", "local-only"), check_rc=False).returncode != 0
recover(local_only, "local-only")
check("a branch that exists only here: its fetch fails, changing nothing, and the checkout still finds it",
      failed and rules(local_only) == before and git(local_only, "rev-parse", "--abbrev-ref", "HEAD") == "local-only")

# --- the durable proof's carry passes the bare branch the script requires ----------------------
CARRY = command(MP, "python3 ${CLAUDE_PLUGIN_ROOT}/skills/review/scripts/reviewed-status.py post <commit> --from")
bin_dir = fresh("bin")
with open(os.path.join(bin_dir, "gh"), "w") as fake:
    fake.write("#!/bin/sh\necho '{}'\n")
os.chmod(os.path.join(bin_dir, "gh"), 0o755)
sha = "a" * 40
def carry(text):
    text = (text.replace("${CLAUDE_PLUGIN_ROOT}", ROOT).replace("<commit>", sha).replace("<reviewProof.head>", sha)
            .replace("<n>", "7").replace("<workingBase>", "main").replace("<reviewProof.base>", "origin/main"))
    done = subprocess.run(["bash", "-c", text], cwd=repo, capture_output=True, text=True,
                          env=dict(ENV, PATH=bin_dir + os.pathsep + os.environ["PATH"], REVIEWED_STATUS_WAIT="0"))
    return done.stdout + done.stderr
said = carry(CARRY)
check("the carry command as written passes the script's base check (it gets as far as asking about the pull request)",
      "pass the bare branch name" not in said and "not an open pull request" in said, said)
said = carry(CARRY.replace("<workingBase>", "<reviewProof.base>"))
check("(the old --base <reviewProof.base> was refused by that check)", "pass the bare branch name" in said, said)
PY
OUT="$(python3 -B "$WORK/cases.py" "$ROOT" "$WORK" 2>&1)"; RC=$?
printf '%s\n' "$OUT" | sed 's/^/  /'
N="$(printf '%s\n' "$OUT" | grep -c '^ok')"
if [ $RC -ne 0 ] || printf '%s\n' "$OUT" | grep -q '^FAIL'; then bad "a case failed or the script did not finish (exit $RC)"
elif [ "$N" -lt 30 ]; then bad "only $N cases ran, expected at least 30"
fi
exit $FAIL
