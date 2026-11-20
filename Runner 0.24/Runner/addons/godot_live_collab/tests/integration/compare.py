#!/usr/bin/env python3
"""Reads host.json / client.json written by a scenario and prints a verdict. Exit code 0 = converged."""
import json, os, sys
OUT = os.environ.get("OUT", os.path.join(os.environ.get("TMPDIR", "/tmp"), "glc_out"))
def load(n):
    try: return json.load(open(os.path.join(OUT, n + ".json")))
    except Exception as e: return {"ok": False, "why": str(e)}
h, c = load("host"), load("client")
verdicts = []
print("host ok:", h.get("ok"), h.get("why", ""), "| client ok:", c.get("ok"), c.get("why", ""))
verdicts.append(bool(h.get("ok")) and bool(c.get("ok")))
for side, r in (("host", h), ("client", c)):
    for k, v in (r.get("checks") or {}).items():
        print("  %-7s %-34s %s" % (side, k, "PASS" if v else "FAIL <<<<<<"))
        verdicts.append(bool(v))
if "dump" in h or "dump" in c:
    hd, cd = h.get("dump", []), c.get("dump", [])
    if hd == cd:
        print("TREES IDENTICAL (%d nodes)" % len(hd)); verdicts.append(True)
    else:
        print("TREES DIVERGE"); verdicts.append(False)
        hs = {n["path"]: n for n in hd}; cs = {n["path"]: n for n in cd}
        print("  only host  :", sorted(set(hs) - set(cs))[:10]); print("  only client:", sorted(set(cs) - set(hs))[:10])
        for k in sorted(set(hs) & set(cs)):
            if hs[k] != cs[k]: print("  first diff:", k, hs[k], cs[k]); break
if "text" in h or "text" in c:
    if h.get("text") == c.get("text"):
        print("SCRIPT TEXT IDENTICAL, %d chars" % len(h.get("text") or "")); verdicts.append(True)
    else:
        print("SCRIPT TEXT DIVERGES\n  host  :", repr(h.get("text")), "\n  client:", repr(c.get("text"))); verdicts.append(False)
if "files" in h or "files" in c:
    hf, cf = h.get("files", {}), c.get("files", {})
    bad = [k for k in sorted(set(hf) | set(cf)) if hf.get(k) != cf.get(k)]
    print("FILES %s (host=%d client=%d)" % ("IDENTICAL" if not bad else "DIFFER", len(hf), len(cf))); verdicts.append(not bad)
    for k in bad: print("  DIFF %-40s host=%s client=%s" % (k, hf.get(k), cf.get(k)))
    s1h, s1c = h.get("stage1", {}), c.get("stage1", {})
    bad1 = [k for k in sorted(set(s1h) | set(s1c)) if s1h.get(k) != s1c.get(k)]
    print("after-join reconcile: %s" % ("identical" if not bad1 else "DIFF " + str(bad1))); verdicts.append(not bad1)
    print("backups host:", h.get("backups"), " client:", c.get("backups"))
if "journal_delta" in h: print("operations sent for the new subtree:", h["journal_delta"])
sys.exit(0 if all(verdicts) else 1)
