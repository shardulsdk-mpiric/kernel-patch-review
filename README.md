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

**Prerequisites:** `git`, `python3`, Claude Code. `b4` additionally if you want
to review a patch by message-id or lore URL (`pip install b4`); `curl` if you
want the ground-truth corpus.

### 1. Get Sashiko's prompt bundle on disk

The skill reads Sashiko's prompts rather than duplicating them, so they have to
exist somewhere. Either is fine:

**If you already run Sashiko locally**, `sashiko init` has already put the
bundle under `~/.local/share/sashiko/prompts/<hash>/kernel/`, and `config.sh`
finds it automatically (newest first). Nothing to do.

**Otherwise, clone the repo and point at the prompts** -- no install step, the
files just need to be readable:

```sh
git clone https://github.com/sashiko-dev/sashiko.git
echo "SASHIKO_PROMPTS=$PWD/sashiko/third_party/prompts/kernel" >> config.local.sh
```

(Sashiko also ships `third_party/prompts/kernel/scripts/claude-setup.sh`, which
installs *its own* `kernel` skill and `/kreview`-style commands. That is
complementary to this skill and entirely optional -- this one does not need it.)

### 2. Install this skill

```sh
git clone <this repo> kernel-patch-review
ln -s "$PWD/kernel-patch-review/skill" ~/.claude/skills/kernel-patch-review
```

That is the whole install. `config.sh` discovers the rest: your kernel tree
from the working directory, and the prompt bundle from its install location.

### 3. Check it resolved everything

```sh
cd /path/to/your/linux/tree
kernel-patch-review/skill/scripts/setup-review-target.sh HEAD
```

It prints `TREE=`, `RANGE=` and `VERIFIED=`. If something is missing it aborts
naming the variable to set -- put it in `config.local.sh` beside `config.sh`,
or export it. Nothing else needs configuring.

### 4. Review a patch

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

The resolver takes whatever you have:

```sh
skill/scripts/setup-review-target.sh HEAD                   # or a sha, or a range
skill/scripts/setup-review-target.sh <message-id>           # fetched with b4
skill/scripts/setup-review-target.sh https://lore.../<id>/  # a lore URL
skill/scripts/setup-review-target.sh --file series.mbox     # a saved mbox
skill/scripts/setup-review-target.sh --patchset 12427       # a sashiko.dev id
```

**Review only what it printed a `RANGE` for.** One subject in the MPTCP corpus
is committed eight times across a month; choosing "the commit with that
subject" once produced a review of code the author never posted. `VERIFIED=`
tells you how much is confirmed: `yes` means blob hashes match a published
review, `content-only` means the series applied cleanly but nothing independent
confirms the bytes, `no` means it is your working tree as it stands.

## Scoring against published Sashiko reviews

Sashiko's hosted reviews are **not** on lore -- they live only in the web app.
Fetch them from its public API to use as ground truth:

```sh
corpus/fetch-sashiko-hosted.sh        # MPTCP list; ~316 patchsets, ~13 MB
```

Then `SKILL.md` section 7 scores a review against the published one, and
`evidence/severity-calibration.py` reproduces the severity tables.

## Layout

```
config.sh              every site path; override by env or config.local.sh
skill/                 what Claude Code loads (symlink this into ~/.claude/skills)
  SKILL.md               the procedure
  references/            lenses, verification discipline
  scripts/               setup-review-target.sh -- resolves what to review
corpus/                fetch-sashiko-hosted.sh -- pulls the ground-truth corpus
evidence/              the measurements behind the rules
harness/               optional: runs the real Sashiko binary for comparison,
                       schedules runs, logs and recovers findings
```

Only `skill/` is needed to use this. `harness/` is for comparing against
Sashiko itself and needs `SASHIKO_SRC` pointing at a full checkout.

## Evidence and honest limits

`evidence/` holds what was actually measured, and it is not a success story:

- Scored against published Sashiko reviews, this trailed them -- 4 of 6
  findings from a fresh context, 1 of 7 from inside a long working session.
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

Apache License 2.0 -- see [LICENSE](LICENSE). Chosen to match Sashiko, so work
here can flow upstream into it.

Sashiko and its prompt bundle are separate projects, used here under their own
licenses; this repository redistributes neither.
