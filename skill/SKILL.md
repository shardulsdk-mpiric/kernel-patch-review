---
name: kernel-patch-review
description: Review a Linux kernel patch to the standard of the hosted Sashiko reviewer, run directly in this session instead of through the Sashiko harness. Applies Sashiko's multi-lens protocol, its false-positive and severity guidance, and a verification discipline derived from measured failures. Use when the user asks to review a kernel patch or series before sending it to a mailing list, to check a patch against a published Sashiko review, or says "review this patch like Sashiko would".
---

# Kernel patch review (Sashiko protocol, run in-session)

Sashiko's review quality comes from three things, none of which require its
harness: a **decomposition into independent analytical lenses**, a **large
false-positive and severity corpus**, and a **consolidation discipline** that
verifies findings before reporting them.

## Why run it in-session rather than through the harness

Not because the analysis is better -- it is not, and nothing here has been
measured against the harness on equal footing. The reason is the **cost
mechanism**, which differs structurally.

Sashiko drives its pipeline by spawning one process per stage. With the
Claude Code CLI provider that invocation is (verified by observing the running
processes):

    claude --print --output-format json --no-session-persistence

`--no-session-persistence` means every stage starts from an empty context, and
`--print` runs the CLI in text-completion mode -- no tools, no file access -- so
Sashiko gathers the code itself and builds each stage's prompt in full. That
prompt is therefore sent once per stage. It is largely a *cache read* rather
than fresh input (hence the cached-token count below), which is cheap against an
API key and still consumes quota against a subscription. What is not reused is
conversation state, with no conversation state carried between stages. Verified
measurements from runs of this pipeline:

| measured | value |
|---|---|
| one single stage | 1.6M cached input tokens against 57k output |
| one patch, 10 stages, wall clock | 45m10s |
| what one patch costs a fixed-quota subscription | roughly one full usage window |

In-session the same bundle is read once into one context and every later step
is a cache read against that same prefix. **Assumption, not measurement:** that
this makes a full review materially cheaper in tokens. The in-session side has
not been metered, and the saving is conditional -- every subagent dispatched
under sections 1b, 4 and 5 starts a fresh context and pays part of the re-send
back. A wide fan-out could plausibly cost more than the harness. Fan out on
purpose, not by habit.

Note this is not "API versus Claude Code". Sashiko against an API key spends
money and no quota; against the CLI provider it spends quota and no money. The
token volume is the same either way, and it is driven by the per-stage re-send.

## What running in-session costs you

**Stage independence.** The harness runs its stages blind to each other, so
they cannot anchor on one another's conclusions. In one context you cannot
un-see your own earlier conclusion. Compensate deliberately -- see section 4.

## 0. Where things live

This skill and its harness are one repository, cloned anywhere. No *site* path
is hardcoded: `config.sh` at the repo root defines every one of them, and each
can be overridden by an environment variable of the same name or by an
untracked `config.local.sh`. The only absolute paths written below are the
skill's own scripts, quoted at their default install location.

```
<repo>/config.sh                     site paths -- edit this, not the scripts
<repo>/skill/SKILL.md                this file
<repo>/skill/references/             lenses, verification discipline
<repo>/skill/scripts/                setup-review-target.sh
<repo>/harness/                      prepare-bench-tree, recover-findings, proxy
<repo>/evidence/                     the measurements each rule rests on
```

Paths the skill uses, all from `config.sh`:

| variable | what it points at |
|---|---|
| `KERNEL_TREE` | the kernel clone under review |
| `REVIEW_WORKROOT` | where review worktrees are created |
| `SASHIKO_PROMPTS` | Sashiko's prompt corpus (`severity.md`, `false-positive-guide.md`) |
| `HOSTED_REVIEWS` | hosted reviews used as ground truth, one JSON per patchset |
| `BENCH_TREES` | verified trees built by the harness |

**Read the corpus before adding a rule.** Four times now a rule was written
into this skill that `SASHIKO_PROMPTS` already stated, and in three of those the
corpus version was better. The failures were never missing guidance -- they were
guidance not applied. Grep there first.

## 0b. Check the prerequisites, and ASK rather than work around a gap

Run this first, every time. It lives in `scripts/` beside this file; with the
install the README describes, that is:

    ~/.claude/skills/kernel-patch-review/scripts/preflight.sh

If the skill was installed under a different name, use that path instead.

It reports three tiers and exits non-zero if anything REQUIRED is missing.

**If something REQUIRED is missing, stop and ask the user to arrange it.** Do
not review anyway, do not substitute your own knowledge for the corpus, and do
not quietly skip the step. The failure this guards against is silent: a review
run without the prompt bundle still produces a confident-looking report, and
nothing in that report says it was written without the false-positive and
severity guidance it is supposed to defer to. Quote the `[MISSING]` lines and
the remediation the script printed, and wait.

**If something RECOMMENDED is missing**, say so in the report's blind-spots
section and name which step you could not perform -- for example, guard
reasoning without `pointer-guards.md`, or `Fixes:` verification without
`fixes-tag.md`. Continue; do not stop.

**If something CONDITIONAL is missing**, it only matters if the user asked for
that path. A missing `b4` blocks a message-id review and nothing else; an
unpopulated corpus blocks section 7 scoring and `--patchset`. Tell the user
what it blocks and offer the alternative the script names.

## 1. Establish exactly what you are reviewing — run the resolver, do not improvise

Whatever the user gave you — "review HEAD", a sha, a range, a message-id, a
lore URL, a Sashiko patchset id, or a saved mbox — resolve it with:

    ~/.claude/skills/kernel-patch-review/scripts/setup-review-target.sh <what they said>

(again, `scripts/` beside this file, whatever the skill is installed as)

It prints `TREE=`, `RANGE=` and `VERIFIED=`, and exits non-zero with a reason if
it cannot produce a trustworthy target. **Review only what it printed.** Do not
hand-pick a commit by subject: one subject in this corpus is committed EIGHT
times across a month, and choosing by subject produced a review of code the
author never posted.

What it does per input:

| input | behaviour |
|---|---|
| `HEAD`, a sha, a range | uses the tree as-is; warns if the worktree is dirty |
| a message-id or lore URL | fetches with `b4 am`, finds a base (see below), makes a detached worktree under `.claude/worktrees/`, applies the series |
| `--patchset <id>` | delegates to the corpus verifier, which checks the pre- AND post-image blob hashes against the published review and REJECTS a mismatch |
| `--file <mbox>` | same as message-id, minus the fetch |

**Base selection for a posted patch**, in descending order of trust: a
`base-commit:` trailer in the patch, then `REVIEW_BASE=<sha>` from the
environment, then the newest commit on `mptcp/export` (or `master`, or
`origin/master`) dated before the patch's own `Date:` header. If the series
still does not apply, it searches the 25 commits before that date on each
tracked branch. It reports which method it used as `BASE_SOURCE=` — read that
line, because "kernel tree HEAD" means the base is a guess and line numbers in
your findings may not match the author's.

**Read `VERIFIED=` and say so in the report.** `yes` means blob hashes match a
published review. `content-only` means the series applied cleanly but nothing
independent confirms it is the same bytes the author posted. `no` means you are
reviewing a working tree as it stands.

## 1b. Then decide who does the review

The measured difference is large and it is about CONTEXT, not instructions.
Across six patches: reviews run in a **fresh** context scored 4 of 6 findings;
reviews run inside a long working session scored 1 of 7 — same skill, same
patches, same ground truth. Accumulated framing about a patch family is
actively harmful.

So if you are a session that has been working on this code for a while:

**Dispatch a subagent.** Give it only the resolver's output, this skill's path,
and the instruction to write a report file. Do NOT give it your reasoning or
your suspicions — that is what destroys the independence you are paying for.
Then read its report and verify its claims against the source yourself before
relaying them.

**If subagents are unavailable**, print a ready-to-paste prompt and ask the user
to run it in a fresh session. It needs exactly four things: use this skill, the
TREE and RANGE, "this is blind — do not read any existing review", and the
output path.

Either way you still own the last step: **verify before relaying.** A subagent
that says "I confirmed X" has been wrong here, and so has this skill's author.

## 1c. Record the target in the report

State the commit and the blob hashes of the touched files
(`git rev-parse --short HEAD:<file>`), plus the `VERIFIED=` level the resolver
reported. A later reader must be able to confirm which bytes were reviewed —
that is the whole point of section 1, and it is cheap to write down.

## 2. Read the patch and its neighbourhood before forming any opinion

Read the full enclosing function, not the diff hunk. **Most false positives come
from judging a construct visible in three lines of context.** Then read, from
the Sashiko prompt corpus (paths relative to the prompt bundle, default
`~/.local/share/sashiko/prompts/<hash>/kernel/`):

- `false-positive-guide.md` — the single highest-value document here
- `severity.md` — calibration, and why unreachability is not a reason to lower
- `subsystem/<relevant>.md` — pick 2-4, not everything

## 2b. Set the scope from the INVARIANT, not from the diff

The largest single gap measured against the hosted reviewer was scope, not
depth. Hosted's Critical finding on one patch was a use-after-free in a function
**the diff does not touch**. It was in scope because the patch changed a rule
about a shared lock and two shared lists, and that function is a participant in
the same rule.

So before reviewing, write down what invariant the patch changes — a lock
discipline, an object lifetime, a state bit, an ordering, a refcount rule — and
then enumerate every function that participates in it:

    git_grep for the lock, the list heads, the state field, the struct
    -> list every function that takes that lock or touches those objects
    -> those functions are in scope even if the diff never mentions them

Review the diff first, then walk that list. A patch that changes an invariant
puts every participant in the invariant at risk, and reviewing only the changed
lines will miss exactly the bugs that matter most.

## 2c. Build the case matrix for any changed condition

An independent reviewer found both hosted findings on a two-line patch that I
scored 0/2 on, and this is the technique that separated us.

When a patch changes a condition, do not reason about the new condition. **List
every combination of its inputs and mark which cells changed.** For a patch that
added `&& (flags & X)` to a test on `opsize`:

| X flag | opsize | changed? |
|---|---|---|
| 1 | 24 (with csum) | no |
| 1 | 22 (no csum) | **no — and this is the case the commit message claims to fix** |
| 0 | 24 | yes — the only cell that changes |
| 0 | 22 | no |

The matrix makes it immediate that the patch cannot fix the bug its own message
describes, because that cell is untouched. Adding a conjunct only ever *removes*
cases; it cannot affect a branch that was already not taken. Reading the changed
line and its consumer — what I did — never surfaces this.

## 2d. Read the commit named in Fixes: as a witness to intent

If the patch has a `Fixes:` tag, read that commit's message. It states what the
original design was for, which is the strongest available evidence about whether
the current patch is removing something load-bearing.

On the same patch, the fixed commit said verbatim: "We always parse any
csum/nocsum combination and delay the presence check to later code, to allow
reset if missing." That single sentence establishes that the deleted line was
deliberate and load-bearing — which turned a plausible-looking simplification
into a real finding. Grepping the current tree cannot tell you this; only the
history can.

## 2e. Load the corpus the staged pipeline never sees

Sashiko's own review pipeline loads exactly SIX files from its prompt bundle,
by stage number: `callstack.md` and `technical-patterns.md` (stage 3),
`subsystem/locking.md` (stage 5), `false-positive-guide.md` and `severity.md`
(stage 10), `inline-template.md` (stage 11).

The bundle ships roughly 1,590 further lines that the staged path never loads.
They are reachable only through Sashiko's slash-command entry points. Reading
them here is therefore an advantage the hosted pipeline does not have:

| file | lines | what it gives you |
|---|---|---|
| `review-core.md` | 305 | the full analysis protocol: context management, change categorisation, regression tasks, commit-tag verification |
| `fixes-tag.md` | 220 | Fixes: tag verification, including when a tag should be present and a self-verification gate |
| `pointer-guards.md` | 139 | guard analysis done properly: find guards, guard ORDERING, guard implications, prove or disprove coupling, final validation |
| `missing-fixes-tag.md` | 64 | detecting a missing Fixes: tag |
| `lore-thread.md` | 126 | reading the mailing-list thread around a patch |
| `coccinelle.md` | 595 | generating a semantic patch to check a pattern mechanically across the tree |

**Read `pointer-guards.md` before doing any guard reasoning** — it is more
developed than the guard rules in this skill's verification-discipline, which
were written from scratch after a failure and lack its ordering and coupling
steps. **Read `fixes-tag.md` whenever the patch carries or should carry a
`Fixes:` tag.** Locate the bundle with:

    ls -dt ~/.local/share/sashiko/prompts/*/ | head -1

## 3. Apply the lenses

See [references/lenses.md](references/lenses.md) for the full set with the
questions each one asks. Work through them deliberately and write findings as
you go; do not merge them into one pass.

## 4. Independence: when to fan out to subagents

Anchoring is the real cost of running in one context. You cannot un-see your own
stage-3 conclusion while doing stage 5.

**Fan out** (one subagent per lens, each given only the patch, the tree path and
that lens's questions) when: the patch is subtle or security-relevant, an
earlier pass produced a confident conclusion you want challenged independently,
or the user is deciding whether to send the patch to a list.

**Stay in one context** when: the patch is small and mechanical, the user wants
a quick opinion, or cost matters more than coverage.

A middle option that is usually the best value: do the lenses yourself, then
spawn **one** adversarial subagent whose only job is to refute your findings,
given the code but not your reasoning.

## 4b. Sweep for SIBLINGS of the defect class (MANDATORY)

This step exists because of a measured, repeated miss. Across three patches
reviewed with this skill, the first hosted finding was found every time and the
second was missed every time — and all three second findings had the same shape:

| patch | what was found | what was missed |
|---|---|---|
| A | the patch's fix is incomplete for field X | the SAME root cause reaching a different field, `csum` |
| B | the commit message contradicts the code | the same object read unprotected in a function the diff never touches |
| C | the patch does not fix its own stated bug | the downstream consumer of the behaviour the patch REMOVED |

**Finding the bug the patch is about is not the job. The job is finding the
class.** A patch that fixes one instance of a defect is evidence that the
defect's class exists in this code; the author fixed the instance they hit.

So once you have characterised the defect the patch addresses, write the class
down in one sentence — "a flag is assigned before the length check, so a
malformed option leaves dependent fields unwritten" — and then sweep:

1. **Same root cause, other fields.** If the mechanism leaves one field
   unwritten, list every other field written in that same block and check each.
   Fields declared OUTSIDE any bulk-cleared group are the dangerous ones.
2. **Same object, other accessors.** `git_grep` the object the patch changes the
   rules for and open every reader, including ones the diff never mentions.
   Softirq, timer and BPF paths are the ones most often forgotten.
3. **Same pattern, sibling branches.** If the defect lives in one `case` of a
   switch or one option handler, read the neighbouring cases. Parsers repeat
   their own mistakes.
4. **The removed behaviour's consumers.** If the patch deletes or narrows
   something, find who depended on it. Deletion has no diff at the call site.

Report a sibling even when it is pre-existing — mark it so, per rule 1 in the
verification discipline. An author fixing one instance is exactly the moment to
raise the others.

## 5. Verify every finding, and try to REFUTE it

This is not optional and it is where most of the value is. Follow
[references/verification-discipline.md](references/verification-discipline.md).

**Attack the premise before the consequences.** The most expensive error
measured here was a confident High built on an unchecked premise, with four
correct consequence links stacked on top — the correctness of the chain
disguised the falsity of its root. For each finding, write the single claim it
depends on and try to disprove that claim specifically.

**Then run a refutation pass.** Ideally spawn one subagent per surviving
finding, giving it the code, the claim, and NOT your reasoning, instructed to
disprove it. An in-context self-check inherits the assumption that produced the
error; a subagent that never saw the reasoning does not. If cost forbids
subagents, re-derive the claim from the source as though you had never seen it,
starting from the declaration of every symbol involved.

**If the refutation pass could not run, say so and cap what it would have
checked.** Subagents are sometimes unavailable -- budget exhausted, concurrency
limit, no subagent tool. When that happens the in-context fallback is a weaker
check, not an equivalent one, and the report must not read as though the finding
survived independent refutation. Then:

- state in the report which findings were **not** independently refuted, and why
- cap those findings at Medium unless the mechanism is proved by code you quote
- name them as the ones a reader should re-check first

This is measured, not hypothetical. Across eight patches reviewed with this
skill, exactly one had its refutation pass fail this way, and that patch is the
only one that produced a Critical false positive. Its reviewer flagged the right
two findings as needing re-checking and filed them at full severity anyway. See
`evidence/comparison-vs-kreview.md`.

**Before filing any NULL-dereference or missing-check finding, enumerate the
guards in EVERY frame between the entry point and the dereference -- not only
the frame in front of you -- and state in the finding which frames you checked.**
A guard one call above the code in view is the most common way a confident
NULL-deref finding turns out to be wrong: the false positive above was a
dereference genuinely unguarded in its own function and guarded in its caller,
which the reviewer never opened. `pointer-guards.md` already requires this --
*"CRITICAL: You need to find the callers of these functions as well"* -- so read
it rather than relying on this paragraph.

## 5b. Three outcomes, not two — never drop an established mechanism

A finding has three possible fates, and collapsing them into "keep or dismiss"
loses real bugs. Measured: a reviewer identified a hosted High **exactly** — the
right object, the right mechanism, the right consequence — then dropped it
because it could not prove the path was reachable in this tree. The hosted
reviewer filed it as High.

| what you established | what to do |
|---|---|
| the code in view makes the claim **impossible** (a guard, an early return, an invariant) | **dismiss**, quoting the lines that disprove it |
| the mechanism holds, but you cannot show a path that reaches it | **REPORT IT**, cap the level at Medium, and mark it speculative, saying exactly which precondition you could not establish |
| the mechanism holds and the path is shown | report at the level the consequence warrants |

The middle row is the one that gets lost. `severity.md` is explicit about it and
says so twice: *"still report the finding and mark it speculative"*, and *"Do
not lower a finding because you believe it is unreachable: reachability is hard
to establish from a diff, and a wrong call buries a real bug."* **Unproven
reachability is not disproof.** Only the first row is disproof.

**A finding lives in the findings list.** If a sweep from section 4b turns up a
real mechanism, it belongs in the findings — marked speculative if that is what
it is — not in the prose describing what the sweep did. A maintainer reads the
findings; nobody reads the methodology section for buried bugs.

**When dispatching a subagent, do not tell it to "dismiss or lower" what it
cannot support.** That instruction reads as permission to drop, and it
contradicts the severity guide. Say instead: *dismiss only what the code
disproves; report the rest, capped and marked speculative.*

## 6. Report

For each finding: severity, the exact file/function/line, the mechanism in one
paragraph, and the consequence. Mark anything that predates the patch with
`PRE-EXISTING` and say the patch neither causes nor worsens it — a real bug is
still worth reporting, it just is not this author's to fix.

State what you did NOT check. A review that lists its blind spots is more useful
than one that implies completeness.

## 6b. Severity: grade the consequence, not the patch

Measured against 951 hosted findings on the same subsystem, we undercall by
almost exactly one level. On five patches reviewed both ways, hosted filed 8
High and 2 Medium; we filed 1 High, 9 Medium, 10 Low. Four of the five top
findings were one level low. Two causes, both of them us not applying rules
that were already written down.

**1. `preexisting` is an attribution flag, not a severity discount.**

| hosted findings | Crit | High | Med | Low |
|---|---|---|---|---|
| pre-existing (n=131) | 23 | 103 | 5 | **0** |
| introduced (n=820) | 89 | 344 | 275 | 112 |

96% of hosted pre-existing findings are High or Critical and **none** is Low.
The reasoning holds up: a pre-existing bug is live in the shipping kernel right
now, while a bug introduced by a patch under review will most likely be caught
before it merges. Old means *already exploitable*, not *less important*.

`false-positive-guide.md` section 6 says to set the flag and to state that the
patch "neither causes nor worsens" the defect. That is about **who is asked to
fix it**. It says nothing about the level, and it must not be read as
permission to lower one. Do not write "LOW, PRE-EXISTING": grade the bug, then
flag the attribution separately.

**2. Grade what the bug does, not how wrong the patch is.**

"The patch is incomplete" is a description of the patch. The level comes from
the consequence, and `severity.md` already lists the bar: kernel panic or oops,
logic errors causing incorrect functional behaviour, resource leaks, violated
locking rules. A remotely-reachable uninitialised stack read, a NULL deref
reachable from a received packet, or a protocol-compliance break that lets a
peer bypass a mandatory reset is a **High** under that definition, whoever
introduced it and however small the patch's role.

Before writing a level, state the consequence in one sentence beginning
"Consequence:" and the path in one beginning "Triggering path:". If the
consequence sentence names a crash, an uninitialised read, or memory
corruption, and the path is reachable from outside, the level is High. If you
cannot write the path sentence, you have a speculative finding -- see 5b: it is
still reported, capped at Medium.

**Do not simply match hosted's numbers.** Hosted calls 59% of all findings
High-or-Critical, and the project itself estimates a false-positive rate around
20%. That bar may be inflated. The two corrections above are not "be more
alarmed" -- they are a directional fix (pre-existing is not a discount) and a
definitional one (apply the bar severity.md already states).

## 7. If a published Sashiko review exists, score against it

Corpus: `$HOSTED_REVIEWS/<id>.json`; the findings are
in `review.output`, a JSON string requiring a second `json.loads`. Match on
function plus mechanism, not on wording. Report hits, misses and extras
separately, and never let a grep decide a match — grep to find candidates, then
read both texts.
