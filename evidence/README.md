# Evidence

Each rule in `SKILL.md` that is not obvious should be traceable to something
measured. This directory holds the measurements and the scripts that reproduce
them.

## tool-call-repetition.md and tool-call-repetition.py

Why a review agent reissues tool calls whose answers are already in its
context, measured across 25 recorded runs. The finding is that the result is
buried rather than missing, so a repeat restores recency rather than fetching
data, which is why answering with an error made the looping worse and
answering with the earlier result does not. States plainly that the effect on
review quality is unmeasured.

## comparison-vs-kreview.md

A blind-scored comparison of this skill against Sashiko's own `/kreview` on 8
blob-verified patches with published hosted reviews as ground truth. Includes
the cost metering, the sampling procedure, and the false positive this skill
produced. Read its "What this measurement does NOT support" section before
quoting any number from it.

## severity-calibration.py

Produces the tables behind `SKILL.md` section 6b, from 951 hosted findings
across 316 patchsets:

| hosted findings | Crit | High | Med | Low | H+C |
|---|---|---|---|---|---|
| all (n=951) | 112 | 447 | 280 | 112 | 58.8% |
| pre-existing (n=131) | 23 | 103 | 5 | **0** | **96.2%** |
| introduced (n=820) | 89 | 344 | 275 | 112 | 52.8% |

Hosted grades pre-existing bugs **higher**, and files none as Low. We had been
using the flag as a discount ("LOW, PRE-EXISTING"). On five patches reviewed
both ways, hosted filed 8 High / 2 Medium; we filed 1 High / 9 Medium / 10 Low,
with four of five top findings exactly one level low.

Two causes, both of them written guidance that was not applied:
1. `false-positive-guide.md` section 6 governs **attribution** ("the patch
   neither causes nor worsens"), not level. It was read as a level rule.
2. `severity.md`'s High bar already lists *kernel panic or oops* and *logic
   errors leading to incorrect functional behavior*. A remotely-reachable
   uninitialised stack read is that. It was filed Medium.

**Do not simply match hosted.** It calls 59% of findings High-or-Critical and
the project estimates its own false-positive rate near 20%. The corrections are
directional (pre-existing is not a discount) and definitional (apply the stated
bar), not "be more alarmed".

### Reproducing

The corpus is not shipped with this repo -- it is refetched from the public
sashiko.dev JSON API (`/api/patchsets`, `/api/review`), which is what the web
UI at <https://sashiko.dev/#/?list=dev.linux.lists.mptcp> reads. The hosted
reviews are **not** on lore, so lore cannot be used as the source.

```sh
../corpus/fetch-sashiko-hosted.sh          # ~316 MPTCP patchsets, ~13 MB
. ../config.sh && ./severity-calibration.py --per-patch
```

Numbers below were measured on the MPTCP list; refetching later will include
patchsets posted since, so exact counts drift.

### A trap this script documents
The patchset index records carry `findings_critical/high/medium/low` integers.
They are unpopulated zeros for some patchsets -- 24559 reads 0/0/0/0 while its
review holds two Highs. Using them gave a plausible but wrong 52.8% baseline.
The real data needs a second JSON parse of `reviews[].output`.
