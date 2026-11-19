#!/bin/bash
# scripts/tests/merge-commands.sh — the git commands the merge and its stops spell out, run exactly
# as the references write them (read from the files, placeholders filled in) in throwaway
# repositories with a bare origin: the exact-landing test, the fast merge's guard and its undo
# after a refused push, the excluded-paths re-route's rebase and push, and the durable proof's
# carry command. Each case also shows the fault the old wording had. No network.
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


def command(path, starts):
    """The one backticked command in `path` that starts with `starts`, white space collapsed."""
    found = [span for span in re.findall(r"`([^`]+)`", flat(path)) if span.startswith(starts)]
    if len(found) != 1:
        raise SystemExit("FAIL %s holds %d commands starting %r" % (os.path.basename(path), len(found), starts))
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
# --- an unproven landing: did a later story commit land? every commit listed, then the direct test ----
WR = os.path.join(ROOT, "skills/run-workflow/references/workflow-runner.md")
GAINED = command(MP, "git log --no-merges --oneline <commit>..origin/<workingBase>")
STORY_LATER = command(MP, "git rev-list <commit>..origin/<branch>")
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
    """What the person sees: the subjects the base gained, and the story commits the direct test finds on it."""
    listed = [line.split(" ", 1)[1] for line in sh(repo, filled(GAINED, "main", story)).stdout.strip().split("\n") if line]
    found = [c for c in sh(repo, STORY_LATER.replace("<commit>", story).replace("<branch>", "feature")).stdout.split()
             if sh(repo, filled(ON_BASE, "main", story).replace("<that>", c), check_rc=False).returncode == 0]
    return listed, found
for shape, how in (("B", "a --no-ff merge at a later head"), ("C2", "a release fast-forward carrying a later head's merge"),
                   ("D", "a stacked branch"), ("E", "an octopus merge")):
    repo, story = later_shape(shape)
    listed, found = later_found(repo, story)
    check("%s: unproven, the base's commits list the later story commit, and the direct test finds it on the base" % how,
          landing(repo, story) == ("unproven", None) and LATER in listed and found == [git(repo, "rev-parse", "feature")], (listed, found))
    if shape == "B":
        old_listed = sh(repo, "git log --first-parent --oneline %s..origin/main" % story).stdout
        check("(the old --first-parent listing showed only the merge commit)", LATER not in old_listed, old_listed)
repo, story = later_shape("F2")
listed, found = later_found(repo, story)
check("only another author's work past C: listed without any story commit, and the direct test finds none, so done naming C is valid",
      landing(repo, story) == ("unproven", None) and listed == ["another author: their work"] and found == [], (listed, found))
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

# --- the fast merge: never on a base ahead of its remote; a refused push undoes exactly the merge
AHEAD = command(MP, "git rev-list --count origin/<workingBase>..<workingBase>").replace("<workingBase>", "main")
UNDO_CHECK = command(MP, "git rev-parse HEAD^1 HEAD^2")
check("the undo is spelled as the reset to the tip written down before the merge, never to the remote, and never through a shell variable",
      "git reset --hard <tip>" in flat(MP) and "git reset --hard origin/<workingBase>" not in flat(MP) and "$tip" not in flat(MP))
bare, repo, story = setup()
git(repo, "checkout", "-q", "main")
unrelated = commit(repo, "notes.txt", "mine, not pushed\n", "an unrelated local commit")
check("a local base ahead of its remote is caught before any merge (the count is not 0)", sh(repo, AHEAD).stdout.strip() == "1")
tip = git(repo, "rev-parse", "HEAD")
git(repo, "merge", "-q", "--no-ff", "-m", "merge: I123", story)
other_author(bare, "the remote moves, so the push is refused")
refused = sh(repo, "git push origin main", check_rc=False).returncode != 0
parents = sh(repo, UNDO_CHECK).stdout.split()  # each command its own shell call, as a step runs them
if parents == [tip, story]:
    git(repo, "reset", "-q", "--hard", tip)
check("a refused push is undone to the recorded tip: the merge is gone and the unrelated commit kept",
      refused and parents == [tip, story] and git(repo, "rev-parse", "HEAD") == unrelated, (refused, parents))
git(repo, "fetch", "-q", "origin")
check("(the old reset to the remote would have discarded it)",
      sh(repo, "git merge-base --is-ancestor %s origin/main" % unrelated, check_rc=False).returncode != 0)
bare, repo, story = setup()
git(repo, "checkout", "-q", "main")
check("a base level with its remote passes the guard", sh(repo, AHEAD).stdout.strip() == "0")

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
BI = os.path.join(ROOT, "skills/build-item/SKILL.md")
FETCH = command(BI, 'git fetch origin "+refs/heads/<branch>:refs/remotes/origin/<branch>"')
FROM_LOCAL = command(BI, "git checkout <branch>")
FROM_REMOTE = command(BI, "git checkout -b <branch> origin/<branch> && git config")
def fresh_clone(bare, single=True):
    clone = fresh("single" if single else "full")
    git(clone, "clone", "-q", *((["--single-branch", "--branch", "main"] if single else []) + [bare, "."]))
    return clone
def recover(clone, branch="feature"):
    """The recovery as build-item writes it: the tracking-ref fetch, then the checkout that fits."""
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
