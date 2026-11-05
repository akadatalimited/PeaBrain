import json, subprocess, os, shutil, sys, sqlite3, re
import sys as _pb_sys
_pb_sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import pb_harness
_PB_ST = pb_harness.require_state()

BIN = sys.argv[1] if len(sys.argv) > 1 else "/scratch/tmp/rixbuild"
WORK = "/scratch/tmp/rank/t_restart"
shutil.rmtree(WORK, ignore_errors=True)
os.makedirs(WORK)
shutil.copy(BIN, WORK + "/tt")
fails = []
def check(name, cond, extra=""):
    print(("PASS " if cond else "FAIL ") + name, flush=True)
    if not cond:
        fails.append(name); print("   extra:", str(extra)[:400], flush=True)

def spawn():
    return subprocess.Popen([WORK + "/tt"], stdin=subprocess.PIPE,
                            stdout=subprocess.PIPE, cwd=WORK, text=True, bufsize=1)
def raw(p, line, note=""):
    p.stdin.write(line + "\n"); p.stdin.flush()
    r = p.stdout.readline()
    try:
        return json.loads(r)
    except Exception:
        fails.append(note); print("BADJSON", note, repr(r[:160]), flush=True); return {}
_i = [1]
def call(p, name, args):
    _i[0] += 1
    return raw(p, json.dumps({"jsonrpc":"2.0","id":_i[0],"method":"tools/call",
                              "params":{"name":name,"arguments":args}}), f"{name}{_i[0]}")
def text(r):
    return r.get("result", {}).get("content", [{}])[0].get("text", "")
def neural_of(ex):
    m = re.search(r'"neural":(null|-?\d+\.\d+)', ex)
    return m.group(1) if m else "?"

# ---- process A: learn ----
p = spawn()
for n, t in [("salpha","loop token alpha"),("sbeta","loop token beta")]:
    call(p, "write_fact", {"name":n,"text":t})
call(p, "search_nodes", {"query":"loop token","limit":10})
for _ in range(6):
    call(p, "feedback", {"name":"sbeta","signal":"useful"})
r = call(p, "explain_rank", {"name":"sbeta"})
n1 = neural_of(text(r))
check("A neural scored", n1 not in ("null","?"), text(r)[-200:])
r = call(p, "model_predict", {"xs":[0.5],"ys":[0.5]})
p1 = text(r)
check("A predict ok", '"values":[' in p1, p1[:160])
r = call(p, "model_status", {})
stA = text(r)
m = re.search(r'"step":(\d+)', stA)
stepA = m.group(1) if m else "?"
p.stdin.close()
try: p.wait(timeout=5)
except Exception: p.kill()

# examples persisted independently of PBMD?
con = sqlite3.connect(WORK + "/peabrain.db")
rows = con.execute("select name,kind,seq,x0,x1,target,det,rev from rankex").fetchall()
con.close()
check("rankex rows durable", len(rows) == 6, rows)
check("peabrain-rank.pbmd exists", os.path.exists(WORK + "/peabrain-rank.pbmd"), os.listdir(WORK))

# ---- process B: restart, same dir ----
# NOTE: no search before the first explain — search bumps access counters by
# design ("surfaced -> learn"), which would change features. status#1 proves
# weights-only restore (no DB open); explain proves exact round-trip.
p = spawn()
r = call(p, "model_status", {})
stB = text(r)
check("B initialized (weights only)", '"initialized":true' in stB, stB[-300:])
check("B owner ranker", '"owner":"ranker"' in stB, stB[-300:])
m = re.search(r'"step":(\d+)', stB)
check("B step restored", m and m.group(1) == stepA, f"{m.group(1) if m else '?'} vs {stepA}")
r = call(p, "explain_rank", {"name":"sbeta"})
n2 = neural_of(text(r))
check("B neural equals A (weights+features restored)", n2 == n1, f"{n1} vs {n2}")
r = call(p, "explain_rank", {"name":"sbeta"})
check("B neural deterministic", neural_of(text(r)) == n2, n2)
r = call(p, "model_status", {})
stB = text(r)
check("B examples restored", '"examples":6' in stB, stB[-300:])

# fresh-model reference: different weights must give a different prediction
r = call(p, "model_init", {"hidden":4,"seed":999,"activation":"leaky"})
check("explicit init ok", '"hidden":4' in text(r), text(r)[:160])
r = call(p, "model_status", {})
check("B owner now user", '"owner":"user"' in text(r), text(r)[-300:])
r = call(p, "explain_rank", {"name":"sbeta"})
n3 = neural_of(text(r))
check("user-owned: neural null", n3 == "null", text(r)[-200:])
p.stdin.close()
try: p.wait(timeout=5)
except Exception: p.kill()

# ---- process C: ownership separation — explicit model never auto-overwritten ----
W2 = "/scratch/tmp/rank/t_owned"
shutil.rmtree(W2, ignore_errors=True); os.makedirs(W2); shutil.copy(BIN, W2 + "/tt")
p = subprocess.Popen([W2 + "/tt"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                     cwd=W2, text=True, bufsize=1)
_i[0] = 100
call(p, "write_fact", {"name":"oalpha","text":"owned token alpha"})
call(p, "model_init", {"hidden":8,"seed":7,"activation":"leaky"})
r = call(p, "model_status", {})
check("C hidden 8 kept", '"hidden":8' in text(r), text(r)[-300:])
call(p, "search_nodes", {"query":"owned token","limit":10})
call(p, "feedback", {"name":"oalpha","signal":"useful"})
call(p, "feedback", {"name":"oalpha","signal":"useful"})
r = call(p, "model_status", {})
stC = text(r)
check("C no rank training under user model", '"revision":0' in stC, stC[-300:])
check("C model_owned rejects counted", '"rejected":[0,0,0,0,0,2]' in stC, stC[-300:])
check("C still hidden 8", '"hidden":8' in stC, stC[-300:])
check("C no peabrain-rank.pbmd", not os.path.exists(W2 + "/peabrain-rank.pbmd"), os.listdir(W2))
m = re.search(r'"step":(\d+)', stC)
check("C user step untouched", m and m.group(1) == "0", stC[-300:])
p.stdin.close()
try: p.wait(timeout=5)
except Exception: p.kill()

# ---- process D: fresh dir — public-tool round-trip of A's weights ----
W3 = "/scratch/tmp/rank/t_file"
shutil.rmtree(W3, ignore_errors=True); os.makedirs(W3); shutil.copy(BIN, W3 + "/tt")
shutil.copy(WORK + "/peabrain-rank.pbmd", W3 + "/peabrain-rank.pbmd")
p = subprocess.Popen([W3 + "/tt"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                     cwd=W3, text=True, bufsize=1)
_i[0] = 200
r = call(p, "model_load", {"path":"peabrain-rank.pbmd"})
check("D load peabrain-rank.pbmd", f'"step":{stepA}' in text(r), text(r)[:160])
r = call(p, "model_predict", {"xs":[0.5],"ys":[0.5]})
check("D predict equals A (bit-exact file round-trip)", text(r) == p1,
      f"{text(r)[:120]} vs {p1[:120]}")
r = call(p, "model_init", {"hidden":4,"seed":42,"activation":"leaky"})
check("D fresh init ok", '"hidden":4' in text(r), text(r)[:160])
r = call(p, "model_predict", {"xs":[0.5],"ys":[0.5]})
check("D fresh differs (learning changed predictions)", text(r) != p1,
      text(r)[:120])
p.stdin.close()
try: p.wait(timeout=5)
except Exception: p.kill()

print("FAILURES:", fails if fails else "none", flush=True)
sys.exit(1 if fails else 0)
