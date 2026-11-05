"""Focused quux/stock oracle for the tix build: seed a scratch store with
interleaved live/tomb quux facts across pages, then:
(a) no tombstoned name surfaced; (b) every returned name is stock-visible;
(c) count == min(limit, visible); (d) OLD and NEW binaries agree
byte-identically on twin snapshots (ranking is newest-first by score,
so insertion order is NOT the expectation)."""
import json, subprocess, os, shutil, sqlite3, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pb_harness

BASE = pb_harness.require_state()
OLD = "/scratch/tmp/tixbuild"
NEW = "/scratch/tmp/PeaBrain"

S = pb_harness.new_state("tixquux")
env = dict(os.environ, PEABRAIN_STATE_DIR=S)
p = subprocess.Popen([NEW], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                     stderr=subprocess.DEVNULL, cwd="/tmp", env=env, text=True, bufsize=1)
rid = [0]
def call(n, a):
    rid[0] += 1
    p.stdin.write(json.dumps({"jsonrpc": "2.0", "id": rid[0], "method": "tools/call",
                              "params": {"name": n, "arguments": a}}) + "\n")
    p.stdin.flush()
    return json.loads(p.stdout.readline())["result"]["content"][0]["text"]

for i in range(60):
    call("write_fact", {"name": f"quux-live-{i}", "text": f"live quux record {i}"})
    call("write_fact", {"name": f"quux-tomb-{i}", "text": f"doomed quux record {i}"})
    call("write_fact", {"name": f"filler-{i}", "text": "padding " * 20})
for i in range(60):
    call("delete_fact", {"name": f"quux-tomb-{i}"})
p.stdin.close(); p.wait(timeout=120)

con = sqlite3.connect(f"file:{S}/peabrain.db?mode=ro", uri=True)
visible = {r[0] for r in con.execute(
    "SELECT name FROM facts WHERE name LIKE '%quux%' AND name NOT IN "
    "(SELECT name FROM tombstones)")}
con.close()

T = pb_harness.new_state("tixquux-twin")
for f, alt in (("peabrain.db", "tinythink.db"),
               ("peabrain-rank.pbmd", "rank.pbmd")):
    src_f = os.path.join(S, f)
    if os.path.exists(src_f):
        shutil.copy2(src_f, os.path.join(T, f))
        shutil.copy2(src_f, os.path.join(T, alt))

def query(binary, state):
    e2 = dict(os.environ, PEABRAIN_STATE_DIR=state)
    js = json.dumps({"jsonrpc": "2.0", "id": 1, "method": "tools/call",
                     "params": {"name": "search_nodes",
                                "arguments": {"query": "quux", "limit": 20}}})
    q = subprocess.run([binary], input=js + "\n", capture_output=True, text=True,
                       timeout=300, cwd="/tmp", env=e2)
    return q.stdout

so, sn = query(OLD, T), query(NEW, S)
got = [r["name"] for r in json.loads(json.loads(sn)["result"]["content"][0]["text"])["results"]]
fails = []
if so != sn:
    fails.append("old-vs-new differ")
if any(n.startswith("quux-tomb-") for n in got):
    fails.append("tomb leak")
if any(n not in visible for n in got):
    fails.append("non-visible name returned")
if len(got) != min(20, len(visible)):
    fails.append(f"count {len(got)} != min(20,{len(visible)})")
print(f"visible={len(visible)} returned={len(got)} leaks=0")
print("PASS quux-oracle" if not fails else f"FAIL quux-oracle: {fails}")
sys.exit(1 if fails else 0)
