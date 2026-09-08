# Why an LLM review agent repeats tool calls it has already made

Measured on 25 recorded local review runs of Sashiko, 4813 tool calls,
1295 of them repeats of a call already made in the same stage.
Reproduce with `evidence/tool-call-repetition.py <runs dir>`.

## The setup

A review stage is a loop. The harness sends a prompt plus tool definitions;
the model answers with either a final result or tool calls; the harness runs
the tools, appends each result to the conversation, and sends the whole
conversation again. Nothing is trimmed or summarised inside a stage.

So when the model asks for the same file twice, the first answer is already
in the message it was just handed. Re-running the call cannot produce new
information: the worktree is detached and read-only, and the read tools are
deterministic against a fixed revision.

That makes the behaviour look irrational, and the obvious response is to
block it. That response is where the interesting part starts.

## What the data says

**Repeats are near, not distant.** Half of them repeat a call made within the
last nine, and the single most common distance is two.

```
   1 calls back:  9.9%
   2 calls back: 14.7%
   3 calls back:  8.5%
  ...
  cumulative within 10 calls: 54.7%
```

**The rate climbs with conversation length.**

```
  n_messages  20-39    18%
  n_messages  60-79    26%
  n_messages 100-119   41%
  n_messages 120-139   50%
  n_messages 200-219   76%
```

**It is not one bad tool.** git_read_files 25%, git_grep 26%, git_show 32%.

**Smaller models repeat more.** qwen3-coder-30b 40.7% mean, glm-4.5-air 25.0%,
qwen3-coder (480b) 15.4%. Capability moves the rate but does not remove it.

## The mechanism

The result is not missing from the context. It is buried in it.

A repeated call does not fetch new data. What it does is move data the model
already had from the middle of a long conversation to the end, where it is
most salient. The model is not recovering from amnesia; it is restoring
recency.

That single idea accounts for all three observations. Repeats cluster at short
distances because the model reasons from recent context. The rate climbs with
length because a longer conversation has more middle to bury things in. And it
predicts something about the fix, below.

## Why blocking the call made it worse

The obvious guard is to refuse a call that repeats an earlier one, answering
with an error that says so. That was tried:

> A repeated call was answered with an error telling the model not to repeat
> it. That withholds the very thing the model asked for, so it asks again: one
> stage produced thirty one refusals and did not change course.

A run with that guard enabled still showed a 39 percent repeat rate.

The mechanism explains why. The model's problem was salience, and an error
does not restore salience: it removes the data entirely and adds a message the
model has no useful action for. It asks again, gets refused again, and the
loop tightens instead of ending.

## What works instead

Return the earlier result rather than an error, annotated with which call
produced it. The tool is not re-executed, so it costs only the memory to hold
the result, and the data lands at the end of the conversation where the model
was reaching for it. The refusal becomes a cache hit.

Two constraints fall out of the same reasoning:

- **Cache successes only.** A call that failed once may succeed later, and
  replaying a stale failure is worse than repeating the call.
- **Only for deterministic tools.** These are reads against a fixed revision
  in a read-only tree. A tool touching the network or the clock would need
  excluding, since replaying it would be wrong rather than merely stale.

## What is not measured

Whether any of this changes review quality. The numbers here are about
repetition and the turns it costs, not about findings found or missed. A guard
that keeps the model from looping might also keep it from a second look that
would have mattered. Answering that needs the same patches reviewed with the
behaviour on and off, scored against known findings, and that has not been
done.

Two maintainers have independently raised this. It is the open question, and
the cost numbers should not be presented as if it were settled.
