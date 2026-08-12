# kernel-patch-review

A Claude Code skill that reviews Linux kernel patches, plus the harness and the
measurements it rests on. Built for MPTCP; the method is subsystem-agnostic.

The skill exists to answer one question: can a fresh Claude Code session, given
an explicit procedure, match the hosted Sashiko reviewer that comments on
patches sent to the mailing list -- so problems are found before the list sees
them.

## Layout

```
config.sh              every site path; override by env or config.local.sh
skill/                 what Claude Code loads
  SKILL.md               the procedure
  references/            lenses, verification discipline
  scripts/               setup-review-target.sh -- resolves what to review
harness/               tree preparation, findings recovery, logging proxy
evidence/              the measurements behind the rules
```

## Install

The skill is one symlink away from working in every session:

```sh
ln -s "$PWD/skill" ~/.claude/skills/kernel-patch-review
```

Then set your paths in `config.local.sh` (untracked) or export them.

## Use

```sh
skill/scripts/setup-review-target.sh HEAD
skill/scripts/setup-review-target.sh <message-id>          # fetched with b4
skill/scripts/setup-review-target.sh https://lore.../<id>/
skill/scripts/setup-review-target.sh --patchset 12427      # hosted corpus id
```

It prints `TREE=`, `RANGE=` and `VERIFIED=`. **Nothing should be reviewed that
this script did not print a RANGE for** -- one subject in the MPTCP corpus is
committed eight times across a month, and picking "the commit with that
subject" once produced a review of code the author never posted.

## The one rule that matters most

`SKILL.md` defers to Sashiko's own prompt corpus (`$SASHIKO_PROMPTS`) wherever
the two overlap. Four separate rules were written into this skill that the
corpus already stated, and in three cases the corpus version was better. The
measured failures were never missing guidance -- they were guidance not
applied. Grep the corpus before adding a rule here.
