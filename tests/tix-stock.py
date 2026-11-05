"""Stock-sqlite3 cross-check: server index verdicts vs ground truth.
Samples 250 tombstoned + 250 live names; exact-match search must surface
live names and suppress tombstoned ones. Compares NEW binary vs stock."""
import json, sqlite3, subprocess, os, shutil, random, sys

import sys as _pb_sys
_pb_sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pb_harness
_PB_BASE = pb_harness.require_state()
_LD = os.path.expanduser("~/.local/share/peabrain")  # ground-truth READS only
LIVE = _LD
LIVE_DB = next((_LD + "/" + c for c in ("peabrain.db", "tinythink.db") if os.path.isfile(_LD + "/" + c)))
NEW = "/scratch/tmp/PeaBrain"

random.seed(20261105)
con = sqlite3.connect(f"file:{LIVE_DB}?mode=ro", uri=True)
tombs = [r[0] for r in con.execute("SELECT name FROM tombstones")]
lives = [r[0] for r in con.execute("SELECT DISTINCT name FROM facts "
                                  "WHERE name NOT IN (SELECT name FROM tombstones) LIMIT 4000")]
con.close()
sample = (random.sample(tombs, 250), random.sample(lives, 250))
truth = {}
for t in sample[0]:
    truth[t] = False
for t in sample[1]:
    truth[t] = True

w = pb_harness.new_state("tixstock-srv")
pb_harness.seed_from_live(w)

reqs = [("search_nodes", {"query": nm, "limit": 5}) for nm in list(truth)]
env = dict(os.environ, PEABRAIN_STATE_DIR=w)
js = "\n".join(json.dumps({"jsonrpc": "2.0", "id": i + 1, "method": "tools/call",
                           "params": {"name": n, "arguments": a}})
               for i, (n, a) in enumerate(reqs))
p = subprocess.run([NEW], input=js + "\n", capture_output=True, text=True,
                   timeout=1200, cwd="/tmp", env=env)
lines = [l for l in p.stdout.strip().split("\n") if l.strip()]
assert len(lines) == len(reqs), f"got {len(lines)} responses for {len(reqs)} reqs"
bad = 0
for (nm, want_live), line in zip(truth.items(), lines):
    txt = json.loads(line)["result"]["content"][0]["text"]
    names = [r["name"] for r in json.loads(txt).get("results", [])]
    if want_live and nm not in names:
        print(f"MISS live {nm!r}"); bad += 1
    if not want_live and nm in names:
        print(f"LEAK tomb {nm!r}"); bad += 1
print(f"checked={len(reqs)} mismatches={bad}", flush=True)
sys.exit(1 if bad else 0)
