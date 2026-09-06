# Measured: this skill vs Sashiko's own `/kreview`, on published ground truth

Run 2026-09-06. Every number here is reproducible from the corpus fetcher and
the trees named below.

## The question

Not "is this better than hosted Sashiko" -- that was measured before and this
skill trailed it. The question a developer actually faces is: **Sashiko already
ships a Claude Code skill and a `/kreview` command. Does this add anything over
what is already on offer?**

## Method

| | |
|---|---|
| frame | 48 eligible patchsets: >=1 hosted finding, a message-id, single-patch, an inline review, and a known baseline. Drawn from 316 fetched. **40 patchsets authored by this repo's author were excluded.** |
| sample | 12 drawn at `random.seed(20260906)` from the deterministically sorted frame, **before any review content was read**. First 8 primary, 4 reserve. |
| attrition | `54207` and `7897` failed tree prep (pre-image blob unrecoverable). Replaced by `34263`, `54849` -- the first two reserves **in sample order**, per a rule fixed before prep ran. |
| final set | `39660 38466 44292 16123 14783 45420 34263 54849` |
| verification | every tree: *pre-image and post-image blobs both match the hosted review*. 5 of 8 needed content-search because the recorded baseline was gone (mptcp export branches are rebased). |
| ground truth | 14 hosted findings, 1-3 per patch |
| arm A | this skill, one fresh subagent per patch, given only the resolved target |
| arm B | `/kreview`, reproduced: `kernel.md` and `kreview.md` rendered exactly as `claude-setup.sh` renders them, `REVIEW_DIR` substituted. Nothing installed. |
| scoring | blind. Arm labels stripped, X/Y shuffled per patch at `seed=77`, judged by an agent told nothing about either procedure. Mapping revealed only afterwards. |

## Result

| patch | GT | A matched | B matched | A extras | B extras |
|---|---:|---:|---:|---:|---:|
| 16123 | 1 | 1 | 1 | 0 | 1 |
| 14783 | 1 | 1 | 0 | 3 | 0 |
| 54849 | 1 | 1 | 0 | 6 | 4 |
| 39660 | 2 | 2 | 1 | 5 | 3 |
| 38466 | 2 | 2 | 1 | 10 | 3 |
| 44292 | 2 | 2 | 2 | 4 | 1 |
| 34263 | 2 | 2 | 1 | 5 | 2 |
| 45420 | 3 | 3 | 3 | 3 | 0 |
| **total** | **14** | **14** | **9** | **36** | **14** |

All 50 extras were judged plausible; **zero** unsupported, **zero** contradicted
by code, in either arm. Both arms flagged pre-existing defects correctly and
both disclosed their own unproven preconditions.

### Cost

| | tokens | wall | per GT finding |
|---|---:|---:|---:|
| A | 1,607,860 | 9,033s | 114,847 |
| B | 997,643 | 3,560s | 110,849 |

A costs 1.6x the tokens and 2.5x the wall clock. **Cost per finding recovered is
within 4% -- effectively identical.** This skill is not more efficient. It
recovers more because it does more work, at a near-constant price per finding.

## Where the difference came from

A's five unique recoveries trace to specific sections:

- `54849`, `38466` -- section 4b's sibling sweep found a second route into the
  same defect class after the primary finding was in hand.
- `14783` -- section 6b. The patch is correct, so every finding is pre-existing;
  B reported **no regressions found**. A's lead finding is confirmed by upstream
  `e00b63056fb4` ("mptcp: fastopen: only mark MPTFO subflows with SYN data",
  `Cc: stable`), whose pre-image blob is byte-identical to the reviewed commit's
  post-image. Treating "pre-existing" as a discount would have buried a real,
  stable-worthy bug.
- `39660`, `34263` -- invariant-driven scope (2b) reaching functions the diff
  never touches.

B's one unique recovery (`14783`'s `-skb->len` zero-extension) A also reported,
scored to B by the judge on the composite-finding split.

## What this measurement does NOT support

- **14 vs 9 on 14 items is not statistical separation.** It rests on five
  single-finding differences. Do not present it as significance.
- **"Extras" means "not in the ground truth", not "correct".** GT sets are 1-3
  findings and clearly not exhaustive. 36 extras is as consistent with broader
  real coverage as with over-reporting.
- **Neither arm had `semcode`**, which Sashiko's bundle assumes in 10+ files.
  Both numbers are a floor.
- Single-patch patches only; series behave differently. n=8.
- **The ground truth is fallible** -- see below.
- Nothing here measures which report a maintainer would rather receive. A's
  reports run 2-3x longer; on `38466` it filed 12 findings against B's 3.

## Two findings that survive regardless of the scoring

**1. The duplicate-subject hazard occurred live, in-sample.** In `bench_45420`
four commits share the subject "mptcp: pm: fix data race in add_addr timer
callback", spanning three weeks, resolving to **two different file contents**
(`4c039e7843d3` and `c71dcf887683`). Choosing a commit by subject is a coin flip
between two genuinely different revisions. This is what section 1's resolver
exists for, and neither `/kreview` nor the hosted pipeline addresses it -- both
are handed their target rather than choosing it.

**2. A filed a Critical false positive, and it is instructive.** On `44292` A
claimed the *setsockopt* path NULL-derefs on an `AF_INET` socket, asserting "no
NULL check anywhere". There is one: `ipv6_sockglue.c:553` guards
`sk_family != AF_INET6`, ahead of `case IPV6_TCLASS:` at line 708. B caught the
guard and correctly listed it as a false positive it had eliminated.

It scored as a *match* anyway, because the hosted ground truth makes the same
error. **So A's 14/14 contains one case of being rewarded for reproducing a
mistake.** Read it as 13 clean matches plus one shared false positive.

Two lessons, both self-inflicted:

- `44292` is the **only** patch where section 5's refutation pass did not run --
  the operator launched 8 reviews concurrently and exhausted the subagent
  budget. That agent wrote at the time: *"the two NULL-deref findings are the
  ones worth re-checking."* It predicted its own error. The one patch missing
  the refutation step is the one that produced a Critical false positive.
- The guard sits in a **caller** frame, and `pointer-guards.md:78` already says
  *"CRITICAL: You need to find the callers of these functions as well."* This is
  the fifth recorded instance of this repo's core failure mode: not missing
  guidance, but guidance not applied.

## Reproducing

```sh
corpus/fetch-sashiko-hosted.sh
harness/prepare-bench-tree.sh <patchset-id>        # verifies blobs, rejects mismatches
```
Then review each tree under both procedures and score blind. The sample is
recoverable exactly: sort the eligible frame, `random.seed(20260906)`,
`random.sample(frame, 12)`.
