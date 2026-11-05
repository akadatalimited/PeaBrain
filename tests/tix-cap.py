"""Capacity/fallback gate (Gate 1: state-isolated). Grows a seeded scratch
store past the 24576-entry index cap via write/delete pairs, then requires
OLD and NEW to agree byte-identically on a tomb-heavy query (fallback is
correct, merely slow). Refuses without a workflow override; never live."""
import json, subprocess, os, shutil, sqlite3, sys, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pb_harness

BASE = pb_harness.require_state()
OLD = sys.argv[1] if len(sys.argv) > 1 else "/scratch/tmp/tixbuild"
NEW = sys.argv[2] if len(sys.argv) > 2 else "/scratch/tmp/PeaBrain"
NPAIRS = int(sys.argv[3]) if len(sys.argv) > 3 else 14000
fails = []
def check(name, cond, extra=""):
    print(("PASS " if cond else "FAIL ") + name, flush=True)
    if not cond:
        fails.append(name); print("   extra:", str(extra)[:300], flush=True)

grow = pb_harness.new_state("tixcap-grow")
pb_harness.seed_from_live(grow)
env = dict(os.environ, PEABRAIN_STATE_DIR=grow)
reqs = []
i = 0
for n in range(NPAIRS):
    nm = f"capfill_{n:05d}_padding_to_add_length_xx"
    i += 1
    reqs.append(json.dumps({"jsonrpc": "2.0", "id": i, "method": "tools/call",
                            "params": {"name": "write_fact",
                                       "arguments": {"name": nm, "text": "capacity filler"}}}))
    i += 1
    reqs.append(json.dumps({"jsonrpc": "2.0", "id": i, "method": "tools/call",
                            "params": {"name": "delete_fact",
                                       "arguments": {"name": nm}}}))
p = subprocess.run([NEW], input="\n".join(reqs) + "\n", capture_output=True, text=True,
                   timeout=3000, cwd="/tmp", env=env)
ntombs = sqlite3.connect(f"file:{grow}/peabrain.db?mode=ro", uri=True).execute(
    "select count(*) from tombstones").fetchone()[0]
print(f"tombs after growth: {ntombs}", flush=True)
check("over index cap", ntombs > 24576, ntombs)

def snap(src, tag):
    d = pb_harness.new_state(f"tixcap-{tag}")
    for f, alt in (("peabrain.db", "tinythink.db"),
                   ("peabrain-rank.pbmd", "rank.pbmd")):
        shutil.copy2(os.path.join(src, f), os.path.join(d, f))
        shutil.copy2(os.path.join(src, f), os.path.join(d, alt))
    return d

outs = {}
for label, binary in (("old", OLD), ("new", NEW)):
    d = snap(grow, label)
    e2 = dict(os.environ, PEABRAIN_STATE_DIR=d)
    js = json.dumps({"jsonrpc": "2.0", "id": 1, "method": "tools/call",
                     "params": {"name": "search_nodes",
                                "arguments": {"query": "probe", "limit": 20}}})
    t0 = time.monotonic()
    q = subprocess.run([binary], input=js + "\n", capture_output=True, text=True,
                       timeout=1200, cwd="/tmp", env=e2)
    outs[label] = (time.monotonic() - t0, q.stdout)
    print(f"{label}: wall={outs[label][0]:.2f}s bytes={len(q.stdout)}", flush=True)
check("fallback output identical", outs["old"][1] == outs["new"][1], "diverged past cap")
print("FAILURES:", fails if fails else "none", flush=True)
sys.exit(1 if fails else 0)
