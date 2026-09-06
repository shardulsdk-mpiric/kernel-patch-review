# kernel-patch-review

A [Claude Code](https://claude.com/claude-code) skill that reviews Linux kernel
patches using [Sashiko](https://github.com/sashiko-dev/sashiko)'s review
protocol, run inside your session instead of through Sashiko's staged pipeline.
Built and measured on MPTCP; the method is subsystem-agnostic.

It is a **companion to Sashiko, not a replacement.** It defers to Sashiko's
prompt bundle wherever the two overlap, and adds the things a local,
interactive run needs that a server-side pipeline does not:

- **knowing exactly which bytes you are reviewing** -- a resolver that turns
  "review my patch" into a verified commit range, because picking a commit by
  subject has silently reviewed code the author never posted
- **avoiding your own context** -- guidance to run the review in a fresh
  context, since reviewing a patch in the session where you wrote it measured
  worse than reviewing it cold
- **not paying the per-stage context re-send** -- Sashiko's pipeline starts
  each stage from an empty context; one patch measured 45m10s and roughly one
  full usage window on a fixed-quota subscription

Honest status: this has **not** been measured against Sashiko on equal footing,
and where it has been scored against published Sashiko reviews it has trailed
them. See [Evidence and honest limits](#evidence-and-honest-limits).

---

## Quick start

Everything below uses `$KPR` for wherever you cloned this, so the commands work
from any directory. Copy the whole block, adjusting the two paths on the first
two lines.

```sh
# --- 1. Get this repo -------------------------------------------------------
git clone https://github.com/shardulsdk-mpiric/kernel-patch-review.git ~/src/kernel-patch-review
KPR=~/src/kernel-patch-review

# --- 2. Get Sashiko's prompt bundle on disk ---------------------------------
# Skip this if you already run Sashiko locally: `sashiko init` has put the
# bundle under ~/.local/share/sashiko/prompts/<hash>/kernel/ and it is found
# automatically. Otherwise clone it and record where it is:
git clone https://github.com/sashiko-dev/sashiko.git ~/src/sashiko
echo "SASHIKO_PROMPTS=$HOME/src/sashiko/third_party/prompts/kernel" >> "$KPR/config.local.sh"

# --- 3. Install the skill ---------------------------------------------------
mkdir -p ~/.claude/skills
ln -s "$KPR/skill" ~/.claude/skills/kernel-patch-review

# --- 4. Check it, FROM YOUR KERNEL TREE -------------------------------------
cd /path/to/your/linux && "$KPR/skill/scripts/preflight.sh"
```

**Step 4 must run from inside your kernel tree.** `preflight.sh` discovers the
tree from your working directory, so running it from this repo will always
report `KERNEL_TREE unset` -- that is the check working, not a broken install.

`preflight.sh` is the one command to run whenever anything seems off. It
reports three tiers and exits non-zero if a REQUIRED item is missing:

| tier | meaning |
|---|---|
| **REQUIRED** | a review must not start without it -- git, a kernel tree, and the prompt bundle's `false-positive-guide.md`, `severity.md` and `subsystem/` |
| **RECOMMENDED** | a named step of the procedure is unavailable, e.g. guard reasoning without `pointer-guards.md`. The review runs and reports the gap. |
| **CONDITIONAL** | only matters for one use -- `b4` for message-id review, the corpus for scoring against published reviews |

Every problem it reports comes with the exact command that fixes it. The skill
runs this itself before every review and will **ask you** to arrange anything
REQUIRED rather than reviewing without it -- a review run without the prompt
bundle still produces a confident-looking report, and that is the failure mode
worth being loud about.

### Review a patch

In Claude Code, from inside your kernel tree:

```
/kernel-patch-review
```

or just ask in plain language -- the skill loads on requests like:

```
review this patch like Sashiko would
review HEAD before I send it to the list
review https://lore.kernel.org/mptcp/<message-id>/
```

The skill resolves the target, reads the prompt bundle, works through the
lenses, tries to refute its own findings, and reports with severity, location,
mechanism and consequence -- plus what it did not check.

---

## Reviewing something other than HEAD

The resolver takes whatever you have. Run it **from inside your kernel tree**,
using an absolute path to the script:

```sh
cd /path/to/your/linux
$KPR/skill/scripts/setup-review-target.sh HEAD                   # or a sha, or a range
$KPR/skill/scripts/setup-review-target.sh <message-id>           # fetched with b4
$KPR/skill/scripts/setup-review-target.sh https://lore.../<id>/  # a lore URL
$KPR/skill/scripts/setup-review-target.sh --file series.mbox     # a saved mbox
$KPR/skill/scripts/setup-review-target.sh --patchset 12427       # a sashiko.dev id
```

**Review only what it printed a `RANGE` for.** One subject in the MPTCP corpus
is committed eight times across a month, and in one sampled tree four commits
shared a subject across three weeks resolving to two different file contents;
choosing "the commit with that
subject" once produced a review of code the author never posted. `VERIFIED=`
tells you how much is confirmed: `yes` means blob hashes match a published
review, `content-only` means the series applied cleanly but nothing independent
confirms the bytes, `no` means it is your working tree as it stands.

Reviewing a message-id, a lore URL, an mbox or a `--patchset` needs somewhere
to apply the series, so those create a detached git worktree under
`$KERNEL_TREE/.claude/worktrees/`. Reviewing a sha or a range does not touch
your tree at all. Set `REVIEW_WORKROOT` if you would rather they went elsewhere.

## Scoring against published Sashiko reviews

Sashiko's hosted reviews are **not** on lore -- they live only in the web app.
Fetch them from its public API to use as ground truth:

```sh
$KPR/corpus/fetch-sashiko-hosted.sh        # the whole MPTCP list
```

The list grows as patches are posted, so the corpus size depends on when you
fetch; `--index-only` reports the current total without downloading reviews.

Then `SKILL.md` section 7 scores a review against the published one, and the
severity tables reproduce with:

```sh
cd "$KPR/evidence" && . ../config.sh && ./severity-calibration.py --per-patch
```

## Layout

```
config.sh              every site path; override by env or config.local.sh
skill/                 what Claude Code loads (symlink this into ~/.claude/skills)
  SKILL.md               the procedure
  references/            lenses, verification discipline
  scripts/               preflight.sh -- checks prerequisites
                         setup-review-target.sh -- resolves what to review
corpus/                fetch-sashiko-hosted.sh -- pulls the ground-truth corpus
evidence/              the measurements behind the rules
PRE-PUBLICATION-CHECKLIST.md   maintainer checklist for cutting a release;
                       not needed to use this
harness/               optional: runs the real Sashiko binary for comparison,
                       schedules runs, logs and recovers findings
```

Only `skill/` is needed to use this. `harness/` is for comparing against
Sashiko itself and needs `SASHIKO_SRC` pointing at a full checkout.

## Evidence and honest limits

`evidence/` holds what was actually measured, and it is not a success story:

These are **two different comparisons and they point different ways**; do not
read either as the headline.

- Against the **hosted** Sashiko reviewer, this trailed it -- 4 of 6 findings
  from a fresh context, 1 of 7 from inside a long working session. It has never
  been measured to beat hosted.
- Against **`/kreview`**, the command Sashiko's own prompt bundle ships, it
  recovered 14 of 14 published findings to `/kreview`'s 9 on 8 blind-scored
  patches -- while costing 1.6x the tokens and 2.5x the wall clock, and within
  4% on cost per finding recovered. See `evidence/comparison-vs-kreview.md`,
  including the Critical false positive this skill filed and `/kreview`
  correctly rejected.
- Across three patches the first Sashiko finding was found every time and the
  second missed every time, which is what section 4b exists to fix.
- Severity was undercalled by about one level against 951 hosted findings,
  which is what section 6b exists to fix.

Those measurements **predate** the rules written to address them, and the rules
have not been re-measured since. Treat the procedure as reasoned, not proven.

The cost argument is on firmer ground: the per-stage context re-send is
observable in Sashiko's own invocation (`claude --print
--no-session-persistence`), and the 45m10s / one-usage-window figures are
measured. That in-session is materially cheaper is an assumption -- the
in-session side has not been metered, and fanning out to subagents pays part of
the saving back.

## The one rule that matters most

`SKILL.md` defers to Sashiko's own prompt corpus (`$SASHIKO_PROMPTS`) wherever
the two overlap. Four separate rules were written into this skill that the
corpus already stated, and in three cases the corpus version was better. The
measured failures were never missing guidance -- they were guidance not
applied. Grep the corpus before adding a rule here.

## License

Copyright 2026 Shardul Bankar <shardul.b@mpiricsoftware.com>

Apache License 2.0 -- see [LICENSE](LICENSE). Chosen to match Sashiko, so work
here can flow upstream into it.

If you send a change here that you would also like to see upstream in Sashiko,
add a `Signed-off-by:` line (`git commit -s`): Sashiko's CI enforces DCO
sign-off on pull requests, and a commit without one cannot be carried across
without being rewritten.

Sashiko and its prompt bundle are separate projects, used here under their own
licenses; this repository redistributes neither.
