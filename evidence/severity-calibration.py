#!/usr/bin/env python3
"""Re-derive the severity numbers that SKILL.md section 6b rests on.

Reads $HOSTED_REVIEWS (one JSON per patchset) and prints the hosted severity
distribution, overall and split by the `preexisting` flag.

The findings are NOT the integer `findings_high`-style fields on the patchset
index records -- those are unpopulated zeros for some patchsets (24559 reads
0/0/0/0 while its review carries two Highs). The real data is at
  patchset.reviews[].output.findings[].severity
where `output` is a JSON *string* needing a second parse. Reading the index
field instead gave a wrong baseline that nearly shipped.
"""
import json, glob, os, sys, collections

# Prefer the environment (config.sh exports it); otherwise fall back to the
# same repo-relative default config.sh uses, so this runs without sourcing it.
D = os.environ.get("HOSTED_REVIEWS") or os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "corpus", "sashiko-hosted", "mptcp", "reviews")
if not os.path.isdir(D) or not glob.glob(os.path.join(D, "*.json")):
    sys.exit("no corpus at %s\n"
             "fetch it with corpus/fetch-sashiko-hosted.sh, "
             "or point HOSTED_REVIEWS at one" % D)

sev = collections.Counter()
by_pre = {True: collections.Counter(), False: collections.Counter()}
per_patch = {}
npatch = nrev = 0

for f in sorted(glob.glob(os.path.join(D, "*.json"))):
    pid = os.path.basename(f)[:-5]
    try:
        d = json.load(open(f))
    except Exception:
        continue
    npatch += 1
    c = collections.Counter()
    for rv in d.get("patchset", {}).get("reviews") or []:
        o = rv.get("output")
        if isinstance(o, str):
            try:
                o = json.loads(o)
            except Exception:
                continue
        if not isinstance(o, dict):
            continue
        nrev += 1
        for fd in o.get("findings") or []:
            s = (fd.get("severity") or "?").strip().lower()
            sev[s] += 1
            c[s] += 1
            by_pre[bool(fd.get("preexisting"))][s] += 1
    per_patch[pid] = dict(c)

N = sum(sev.values())
if not N:
    sys.exit("no findings parsed -- is HOSTED_REVIEWS right?")

print(f"{npatch} patchsets, {nrev} reviews, {N} findings\n")
print(f"{'':16}{'crit':>6}{'high':>6}{'med':>6}{'low':>6}{'H+C':>9}")
def row(label, c):
    n = sum(c.values()) or 1
    print(f"  {label:14}{c['critical']:>6}{c['high']:>6}{c['medium']:>6}{c['low']:>6}"
          f"{100*(c['critical']+c['high'])/n:>8.1f}%   (n={n})")
row("ALL", sev)
row("pre-existing", by_pre[True])
row("introduced", by_pre[False])
print("\nThe pre-existing row is the one that matters: hosted grades old bugs\n"
      "HIGHER, not lower. A pre-existing bug is live in the shipping kernel now.")

if "--per-patch" in sys.argv:
    print("\nper patch (only those with findings):")
    for pid, c in sorted(per_patch.items()):
        if c:
            print(f"  {pid:8} " + "/".join(str(c.get(k, 0))
                  for k in ("critical", "high", "medium", "low")))
