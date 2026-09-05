# Pre-publication checklist

Run through this before the repository goes public, and again before any
version of it is announced on a mailing list. Most items have a command; run
the command rather than trusting a memory of having done it.

Status markers below record what was verified for **this** repository at the
`publish-prep` commit. They are a snapshot, not a permanent pass -- re-run
anything the change touched.

---

## 1. Licensing and provenance

- [x] **A LICENSE file exists.** Apache-2.0, matching Sashiko so that work here
      can be absorbed upstream by it. *Verified: Apache-2.0 is GPLv3-compatible
      but NOT GPLv2-compatible, so a GPLv2 choice here would have permanently
      barred Sashiko from taking any of this.*
- [ ] **A copyright holder is named.** Apache-2.0 is valid without one, but the
      convention in this space is a per-file header -- Sashiko uses
      `Copyright <year> The Sashiko Authors`. Decide individual vs company
      before announcing; it is awkward to change after other people have forks.
- [x] **Nothing third-party is redistributed.** The Sashiko prompt bundle is
      read from disk, never vendored. Verify no copy has crept in:

          git ls-files | grep -iE 'false-positive-guide|severity\.md|review-core' && echo LEAK

- [x] **Dependencies are named with their licenses and origin**, and the README
      states plainly that this is a companion rather than an affiliated or
      endorsed project.
- [ ] **No implied endorsement.** Do not use another project's or maintainer's
      name in a way that suggests they reviewed, approved, or sponsored this.
- [x] **Commit trailers match the conventions of the project this could be
      ported to.** *Verified against Sashiko's own history: `Signed-off-by:` on
      155 of its last 156 commits and enforced by `scripts/check-sob.sh` in
      `.github/workflows/pull-requests.yml`; AI assistance is recorded as
      `Assisted-by: <model>` (observed values include `claude-opus-4.6
      <noreply@anthropic.com>`, `gemini-3.1-pro`, `deepseek-v4-flash`), not
      `Co-Authored-By:`, which appears only twice.*
- [ ] **Sign-off, if these commits are ever to be ported.** DCO sign-off is a
      certification by the person named and must be added by that person, not
      on their behalf. `git commit -s`, or `git rebase --signoff` for existing
      commits.

## 2. Leakage

Everything here is a hard blocker. Once pushed, it is in the git history even
if a later commit deletes it.

- [x] **No local absolute paths.**

          git ls-files -z | xargs -0 grep -nE '/home/|/Users/|/mnt/|C:\\\\'

- [x] **No personal names or private context** where a neutral description
      works. Check both the working tree and the history you are about to push.
- [ ] **No offlist or private correspondence**, and nothing said to you in
      confidence by a maintainer, in any file, commit message, or example.
- [x] **No local task or session material.** `.claude/` is gitignored here; a
      `.claude/tasks/` directory was found untracked in this repo and would
      otherwise have shipped.
- [ ] **No credentials, tokens, keys, or API secrets** anywhere in the history:

          git log -p | grep -inE 'api[_-]?key|secret|token|BEGIN .*PRIVATE KEY'

- [ ] **No third-party data you do not have the right to redistribute.** Fetched
      corpora are gitignored here; the fetcher ships instead of the data.

## 3. Claim honesty

This is the section that decides whether the work is taken seriously by people
who will check it.

- [x] **Every measured number is reproducible by a reader**, with the command
      that produces it. *Verified: `severity-calibration.py` reproduces its
      published tables (951 findings, 58.8% H+C, 96.2% pre-existing) from a
      corpus a reader can fetch.*
- [x] **Anything not measured is labelled as an assumption**, in the same place
      as the claim, not in a footnote.
- [x] **Comparative claims are scoped to what was actually compared.** Do not
      say "better than X" without having run X on the same inputs.
- [x] **Known weaknesses are stated by the authors**, not left for a reviewer to
      find. A reader who discovers an unstated limitation stops trusting the
      stated ones.
- [ ] **Nothing overstates the maturity of the work.** No "production-ready",
      no implied track record that does not exist.

## 4. Reproducibility on a machine that is not yours

The test is a clone into a clean directory as a user who has never seen it.

- [ ] **Repository topics are set.** GitHub repositories are a flat namespace --
      there are no folders or nested repos -- so topics are the only indexing
      mechanism. Up to 20 per repo, lowercase letters/numbers/hyphens, 50 chars
      each. For this repo:

          linux-kernel  code-review  static-analysis  claude-code
          ai-code-review  mptcp  patch-review  developer-tools

      The first four carry the most search traffic; `mptcp` is where the
      measurements actually come from and should not be dropped just because
      the method generalises.
- [x] **The README's clone URL is real.** Points at
      `github.com/shardulsdk-mpiric/kernel-patch-review`. *The repository must
      exist under that name before this is published, or the first command in
      the README 404s.*
- [x] **Clone, follow the README verbatim, and run the first real command.**
      *Done once, by a reader with no knowledge of the repo, against a clone
      at a path unrelated to the source. It found five blockers, all of them
      shell fragments that assumed a working directory the README never
      established, plus an ordering bug that wrote `config.local.sh` before
      the directory it belongs in existed. Re-run this after any README edit
      -- the author cannot perform it, because the author cannot un-know the
      setup.*
- [x] **Prerequisites are listed and machine-checkable.** `preflight.sh` reports
      REQUIRED / RECOMMENDED / CONDITIONAL with a remediation command each.
- [x] **Missing prerequisites fail loudly, never silently.** *Verified in four
      states: healthy, no kernel tree, no prompt bundle, and a gutted bundle.
      The dangerous case is silent degradation -- a review that runs without
      the corpus still looks confident.*
- [x] **No hardcoded site paths remain**, and defaults are discovered or XDG.
- [x] **Every command in the README was executed as written, from the working
      directory the README puts the reader in** -- not from wherever the author
      happened to be standing.
- [ ] **Scripts do not assume your shell, locale, or tool versions.** Note the
      minimum versions you actually tested against.

## 5. Repository hygiene

- [ ] **README works top to bottom.** Every command runs; every link resolves.
- [ ] **No dead references** to files, sections, or scripts that were renamed.
- [ ] **No hardcoded counts of data that grows.** The corpus was 316 patchsets
      when first fetched and 415 four weeks later; a fixed number in the README
      is wrong by the time anyone reads it.

          grep -roE '\[[^]]+\]\([^)h][^)]*\)' --include='*.md' . | ...  # check paths resolve

- [x] **`.gitignore` covers generated and local material** -- fetched corpora,
      run output, local config, editor swap files.
- [ ] **No large binaries or generated artifacts** in history.
- [ ] **Commit messages explain why, not just what**, and contain nothing from
      section 2.

## 6. Before posting to a kernel mailing list

These follow list conventions rather than anything specific to this repository.

- [ ] **Plain text only.** No HTML, no attachments, no marketing formatting.
      Wrap around 72 columns.
- [ ] **ASCII only** in anything that lands in a list archive.
- [ ] **Reply in the right thread**, and to the right list. Do not widen the
      CC beyond what the topic warrants.
- [ ] **No AI-assistance trailers on kernel patches.** This is a separate
      tooling repository, not a kernel patch, so its own commits are not bound
      by that -- but anything sent as a patch is.
- [ ] **Link to lore, not to tree-local commit hashes**, which do not exist
      outside the tree that made them.
- [ ] **Claims in the mail match the claims in the repo.** The mail is the part
      people quote back at you.
- [ ] **State what you want from the reader** -- feedback, testing, or nothing
      at all. An announcement with no ask reads as promotion.
- [ ] **Be able to answer "how is this different from what already exists"** in
      two sentences, honestly, including the parts where it is not different.
