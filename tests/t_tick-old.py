"""Shared-tick verification: repeat stability, feedback authority, restart,
tombstones, multi-page. BIN patched per run."""
import json, subprocess, os, shutil, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pb_harness
BASE = pb_harness.require_state()
BIN = "/scratch/fasm-webserver/tinythink/tinythink"
WORK = "/scratch/tmp/tick-verify"
fails = []
def check(name, cond, extra=""):
    print(("PASS " if cond else "FAIL ") + name, flush=True)
    if not cond:
        fails.append(name); print("   extra:", str(extra)[:400], flush=True)

pb_harness.safe_rmtree(WORK); os.makedirs(WORK)
shutil.copy(BIN, WORK + "/tt")
ST = pb_harness.new_state("t-tick")
ENV = dict(os.environ, PEABRAIN_STATE_DIR=ST)
p = subprocess.Popen([WORK + "/tt"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                     cwd=WORK, text=True, bufsize=1, env=ENV)
_i = [1]
def call(name, args):
    _i[0] += 1
    p.stdin.write(json.dumps({"jsonrpc":"2.0","id":_i[0],"method":"tools/call",
                              "params":{"name":name,"arguments":args}}) + "\n")
    p.stdin.flush()
    return json.loads(p.stdout.readline())
def text(r):
    return r.get("result", {}).get("content", [{}])[0].get("text", "")
def names(r):
    return [e["name"] for e in json.loads(text(r))["results"]]

for n in range(20):
    call("write_fact", {"name": f"altprobe-{n:02d}", "text": "alt token"})
outs = [names(call("search_nodes", {"query": "alt token", "limit": 20})) for _ in range(4)]
check("repeats 2+ stable", outs[1] == outs[2] == outs[3], outs)
# feedback authority: useful on the LAST row must promote and HOLD it
call("feedback", {"name": outs[1][-1], "signal": "useful"})
o5 = names(call("search_nodes", {"query": "alt token", "limit": 20}))
o6 = names(call("search_nodes", {"query": "alt token", "limit": 20}))
check("feedback promotes", o5[0] == outs[1][-1], o5[:3])
check("promotion holds (no oscillation)", o5 == o6, (o5[:3], o6[:3]))
# tombstones: bury two, they vanish and stay vanished without disturbing rest
call("delete_fact", {"name": outs[1][5]})
call("delete_fact", {"name": outs[1][6]})
o7 = names(call("search_nodes", {"query": "alt token", "limit": 20}))
check("tombstoned absent", outs[1][5] not in o7 and outs[1][6] not in o7, o7)
check("rest intact", len(o7) == 18, len(o7))
p.stdin.close()
try: p.wait(timeout=10)
except Exception: p.kill()
# restart: learned ordering persists
p = subprocess.Popen([WORK + "/tt"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                     cwd=WORK, text=True, bufsize=1, env=ENV)
o8 = names(call("search_nodes", {"query": "alt token", "limit": 20}))
check("order survives restart", o8 == o7, (o8[:4], o7[:4]))
p.stdin.close()
try: p.wait(timeout=10)
except Exception: p.kill()
print("FAILURES:", fails if fails else "none", flush=True)
sys.exit(1 if fails else 0)
