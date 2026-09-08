#!/usr/bin/env python3
# Copyright 2026 Shardul Bankar <shardul.b@mpiricsoftware.com>
# SPDX-License-Identifier: Apache-2.0
#
# Measures repeated tool calls in recorded review runs.
#
# Reads turn logs written by harness/logging-proxy.py, one JSON object per
# request, and reports three things: how often a call repeats an earlier
# identical one, how far back the call it repeats is, and whether the rate
# changes as the conversation grows.
#
#   ./tool-call-repetition.py <dir containing */proxy/turns.jsonl>
import json, glob, sys, collections, statistics

root = sys.argv[1] if len(sys.argv) > 1 else "."
runs, dist, buckets, tools = [], collections.Counter(), collections.defaultdict(lambda: [0, 0]), collections.defaultdict(lambda: [0, 0])
total_repeats = 0

for f in sorted(glob.glob(f"{root}/*/proxy/turns.jsonl")):
    seq = []
    for line in open(f):
        try:
            d = json.loads(line)
        except Exception:
            continue
        for tc in (d.get("tool_calls") or []):
            seq.append(((tc.get("name"), json.dumps(tc.get("arguments"), sort_keys=True)),
                        d.get("n_messages") or 0, (d.get("model") or "?").split("/")[-1]))
    if len(seq) < 20:
        continue
    last, reps = {}, 0
    for i, (key, nmsg, _) in enumerate(seq):
        b = min(nmsg // 20 * 20, 200)
        buckets[b][1] += 1
        tools[key[0]][1] += 1
        if key in last:
            reps += 1; total_repeats += 1
            dist[i - last[key]] += 1
            buckets[b][0] += 1
            tools[key[0]][0] += 1
        last[key] = i
    runs.append((f.split("/")[-3], seq[0][2], len(seq), round(100 * reps / len(seq))))

print(f"{len(runs)} runs, {sum(r[2] for r in runs)} tool calls, {total_repeats} repeats\n")
print("repeat rate by model")
bym = collections.defaultdict(list)
for _, m, _, r in runs:
    bym[m].append(r)
for m, rs in sorted(bym.items(), key=lambda x: -statistics.mean(x[1])):
    print(f"  {statistics.mean(rs):5.1f}%  over {len(rs):>2} runs   {m}")

print("\nrepeat rate against conversation length")
for b in sorted(buckets):
    r, t = buckets[b]
    if t >= 40:
        print(f"  n_messages {b:>4}-{b+19:<4}  {100*r/t:>3.0f}%   ({t} calls)")

print("\ndistance back to the call being repeated")
cum = 0
for d in sorted(dist):
    if d > 10:
        break
    cum += dist[d]
    print(f"  {d:>2} calls back: {100*dist[d]/total_repeats:>4.1f}%   cumulative {100*cum/total_repeats:>4.1f}%")
for w in (1, 5, 10, 20):
    c = sum(v for k, v in dist.items() if k <= w)
    print(f"  a guard remembering {w:>2} calls would catch {100*c/total_repeats:>4.1f}%")

print("\nrepeat rate by tool")
for name, (r, t) in sorted(tools.items(), key=lambda x: -x[1][0])[:6]:
    if t >= 20:
        print(f"  {100*r/t:>3.0f}%  {r:>4} of {t:<5} {name}")
