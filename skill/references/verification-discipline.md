# Verification discipline

Every rule here comes from a measured failure during the Sashiko evaluation,
either by an open model, by the hosted reviewer's own verification stage, or by
me. They are ordered by how often they bite.

## 1. A construct that predates the patch is not this patch's defect

Measured: **7 of 12** findings from one model were objections to code the
enclosing function already contained — the same call, the same non-atomic
updates — copied into a new branch and therefore looking new.

Before keeping a finding, read the function at `<revision>^` with `git_show` or
`git_read_files`. If the construct is already there unchanged:
- **already there and harmless** → dismiss it;
- **already there and genuinely a bug** → keep it, mark `preexisting`, and say
  the patch neither causes nor worsens it. A real bug is worth reporting
  whoever wrote it.

Exception: if the patch changes the *conditions* under which pre-existing code
runs, the defect is the changed condition. Quote both versions.

## 2. Walk the guards before assigning High or Critical

Measured: a Critical was filed for an underflow in `a - b` when the branch three
lines above returns unless `a > b`. The model had quoted that branch itself.

From the reported line, read upward to the function's opening and list every
`if`, `return`, `goto`, bounds check and assignment affecting the values in your
claim. For each, state what it implies at your line and whether the claim
survives. **Record this list in the finding even when nothing refutes it** —
otherwise nobody can tell a verified claim from a guess.

If the claim needs an argument to hold some value, the guard may be in the
caller: grep for callers and check the code before the call site.

## 3. Open any function your claim depends on, and PASTE what you read

Measured twice, in opposite directions:
- A use-after-free was claimed because a helper "may free" a buffer. It frees
  only on its success path, and the caller returns on success — so the pointer
  is always live.
- A verification stage asserted that `__mptcp_try_coalesce` "only guards on
  cant_coalesce, size and skb_try_coalesce failure — there is no offset check",
  citing lines 162-165. Line **163** is the offset check. It quoted the correct
  range and read it backwards, then used that to justify a High and to overturn
  a correct earlier finding.

The second is the dangerous shape, and it is the reason this section changed.
Telling a reviewer to "check the guards" does not work: it checked them, cited
the right lines, and drew the opposite conclusion. **A comprehension failure
cannot be instructed away.** What can be done is to make it visible.

**So: paste the lines, do not describe them.**

When a finding depends on what some code does, the finding must contain the
relevant lines **verbatim**, copied from tool output, immediately followed by
the claim they are supposed to support. Not a summary, not a line range, not
"lines 162-165 only check X" — the actual text.

    __mptcp_try_coalesce lines 162-166:
    > if (unlikely(MPTCP_SKB_CB(to)->cant_coalesce) ||
    >     MPTCP_SKB_CB(from)->offset ||
    >     ((to->len + from->len) > (limit >> 3)) ||
    >     !skb_try_coalesce(to, from, fragstolen, delta))
    >         return false;
    Claim: this rejects any skb with a non-zero offset.

Written that way, a wrong reading is obvious to the next reader in one glance.
Described instead of quoted, it is invisible. The goal is not to prevent the
error — it is to stop the error from silently overturning a correct finding.

**Before using a quote to DISMISS an existing finding**, read it once more and
ask only: does this text, as written, say what I am about to claim it says? A
dismissal is the one move that destroys information, so it carries the higher
burden of proof.

## 3b. A negative claim needs the DECLARATION, not a grep for assignments

Measured on my own review, which is why it sits this high. I claimed a status
bit was "never cleared" on a socket-reuse path, having grepped for `pm.status =`
and `status = 0` and found only the final-destruction path. The field is
declared inside a `struct_group(reset, ...)` and is cleared by
`memset(&pm->reset, 0, sizeof(pm->reset))` — invisible to any search for an
assignment to its name. The hosted reviewer had raised the same idea and
dismissed it.

**For any claim of the form "X is never set / never cleared / never
initialised":**
1. Read X's DECLARATION. Note the enclosing struct, union, and any
   `struct_group` it belongs to.
2. Grep for aggregate operations that could cover it: `memset`, `memcpy`,
   `bzero`, assignment of the containing struct, `= {}`, `kzalloc` of the
   parent.
3. Only then grep for direct assignment to the name.

I verified four links of the consequence chain and every one was correct, which
made the finding feel rigorous. **Verifying the consequences of a claim is not
verifying the claim.** Attack the premise first: it is cheaper, and it is where
the error usually is.

## 3c. A MOVED assignment creates invariants that early exits can break

Measured: a one-line patch moved `mp_opt->data_fin = ...` inside
`if (use_map)` so that setting it would imply the mapping fields were valid.
Twelve lines later an option-size check does `break` — before those mapping
fields are parsed. A malformed option therefore still sets the flag without the
data, and the uninitialised read the patch was fixing remains reachable. The
hosted reviewer caught this; I did not.

**When a patch moves an assignment**, enumerate every `break`, `goto`, `return`
and early `continue` between the NEW assignment site and the point where the
values it implies are populated. An assignment placed before a bail-out
establishes an invariant that the bail-out then violates.

**And when a declaration shows which fields are cleared in bulk** (a
`struct_group` under `memset`, a `kzalloc`, an `= {}`), write down BOTH lists:
the covered fields and the uncovered ones. In the same struct, `data_fin` was
covered — safe when never assigned — while `data_seq` and `data_len` sat
outside the group and were not. I read that declaration, used it for the first
conclusion, and failed to carry it to the second.

## 4. Never let a grep adjudicate a finding

Failed three separate times in one evaluation. A control run was scored as
missing a bug because it wrote "map_seq is not updated alongside offset" where
the grep looked for "map_seq is never updated". Compliance checks reported
ABSENT for instructions that had in fact been followed, because they searched
the rendered report for text that lives in the reasoning field.

Grep to find candidates. Then read both texts and decide.

## 5. Distinguish "the model did not do it" from "I measured it wrongly"

Before concluding that a check, prompt or model failed, confirm the artefact you
inspected is the one that would carry the evidence. Rendered reports do not
carry reasoning fields; `claude-cli` runs have no proxy log; a failed report
stage does not mean the findings do not exist (recover them from the proxy
replies or the response cache).

## 6. Do not validate a weak-model aid on a strong model

An instruction written to compensate for a specific weakness cannot be validated
on a model that lacks that weakness. A state-effect enumeration task aimed at a
model that misses cross-function bugs showed no benefit when A/B tested on a
model that finds them anyway — which says nothing about whether it helps the
intended subject. Test the fix on the model with the disease.

## 7. Report your blind spots

Say which lenses you applied, which you skipped, and what you could not
establish. A review that claims less and marks its uncertainty is more useful
than one that implies completeness.
