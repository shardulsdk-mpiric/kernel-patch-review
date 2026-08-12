# The review lenses

Sashiko's eleven stages, restated as lenses to apply in-session. Stages 1-7 are
analysis and run independently of each other in the harness; 8-11 consolidate.
Work each one deliberately and write findings before moving on.

## Analysis lenses

**1. Goal and architecture.** What is the commit trying to achieve? Are there
architectural flaws, UAPI breakage, backwards-compatibility problems, or a
fundamentally flawed concept? Question the author's assumptions and consider
whether a simpler design exists.

**2. Does the code do what the message claims?** Verify each claim in the commit
message against the diff. Look for undocumented side effects, missing pieces (a
core change without updating callers, a struct change without updating all
initializers), missing callbacks, off-by-one errors, and incorrect bitwise
operations. Assume the message may be wrong.

**3. Execution flow.** Trace control flow exhaustively. Logic errors, loop
conditions, unhandled error paths, missing return-value checks, every branch and
switch. NULL dereferences — remember that reading a pointer field is not a
dereference, only accessing its contents is. Walk every `goto cleanup`.

**3b. State effects across functions.** The class most often missed, because the
defect is a mismatch between a write here and a read elsewhere. Decompose it:
  1. List every value the patch assigns that outlives the function — struct
     fields, control-block members, globals, per-connection state.
  2. `git_grep` each one and collect the functions that READ it.
  3. For each (assignment, reader) pair, ask whether the reader compares the
     value against zero/a constant/another field, whether it uses it as a count
     or position that must stay in step with something else, and whether any
     `if` in the reader now becomes always-true or always-false.
  4. **Then look for the assignment that is MISSING.** Name the struct the value
     belongs to, list its other fields, and grep for a function where two of
     those field names appear in the same expression or comparison. If the patch
     assigns one and not the other, and something reads both, that is a defect
     with no trace in the diff.

**4. Resource management.** Leaks, use-after-free, double free, uninitialized
variables, unbalanced alloc/init/use/cleanup/free. Error paths especially.
Reference counting. Asynchronous handoffs: if an object goes to a timer,
workqueue or notifier, prove the task is cancelled before the memory is freed.

**5. Locking and synchronization.** Which lock protects which field, and is it
held at every access? Lockless reads needing `READ_ONCE`/`WRITE_ONCE`. Ordering
and memory barriers. Sleeping in atomic context. Note that the caller may hold
the lock — check before claiming an unlocked access.

**6. Security.** Reachability from untrusted, remote or unprivileged input.
Integer overflow and truncation, bounds, TOCTOU, information leaks to userspace.

**7. Hardware and platform.** 32-bit versus 64-bit behaviour, endianness,
alignment, DMA, per-CPU assumptions. Kernel bugs frequently live in the
32-bit-only arithmetic path.

## Consolidation lenses

**8. Deduplicate.** Merge findings with the same root cause or line. Two
descriptions of one bug are one finding.

**9. Resolve conflicts.** Where one lens raised something another dismissed,
decide with evidence rather than by majority.

**10. Verify and assign severity.** See
[verification-discipline.md](verification-discipline.md). Severity comes from
consequence first, then reachability. Never lower a finding merely because you
cannot establish reachability — that buries real bugs. Lower it only when the
code disproves it.

**11. Report.** Quote the code, give the mechanism, state the consequence, and
ask the author a question rather than issuing an instruction where the call is
genuinely theirs.
