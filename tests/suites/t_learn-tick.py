import json, subprocess, os, shutil, sys
import sys as _pb_sys
_pb_sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import pb_harness
_PB_ST = pb_harness.require_state()

BIN = "/scratch/tmp/rixbuild"
WORK = "/scratch/tmp/rank/t_learn"
shutil.rmtree(WORK, ignore_errors=True)
os.makedirs(WORK)
shutil.copy(BIN, WORK + "/tt")
p = subprocess.Popen([WORK + "/tt"], stdin=subprocess.PIPE,
                     stdout=subprocess.PIPE, cwd=WORK, text=True, bufsize=1)
fails = []
def raw(line, note=""):
    p.stdin.write(line + "\n"); p.stdin.flush()
    r = p.stdout.readline()
    try:
        return json.loads(r)
    except Exception:
        fails.append(note); print("BADJSON", note, repr(r[:160])); return {}
def call(name, args, i):
    return raw(json.dumps({"jsonrpc":"2.0","id":i,"method":"tools/call",
                           "params":{"name":name,"arguments":args}}), f"{name}{i}")
def text(r):
    return r.get("result", {}).get("content", [{}])[0].get("text", "")
def check(name, cond, extra=""):
    print(("PASS " if cond else "FAIL ") + name, flush=True)
    if not cond:
        fails.append(name); print("   extra:", str(extra)[:400], flush=True)

i = 1
for n, t in [("rkalpha","shared token alpha"),("rkbeta","shared token beta"),
             ("rkgamma","shared token gamma")]:
    r = call("write_fact", {"name":n,"text":t}, i); i += 1
    check(f"write {n}", "rowid" in text(r), text(r)[:120])

r = call("search_nodes", {"query":"shared token","limit":10}, i); i += 1
res = text(r)
check("search 3 hits", all(n in res for n in ["rkalpha","rkbeta","rkgamma"]), res[:300])
order_before = [n for n in ["rkalpha","rkbeta","rkgamma"] if n in res]

r = call("model_status", {}, i); i += 1
st = text(r)
check("status owner none", '"owner":"none"' in st, st[-300:])
check("status zero examples", '"examples":0' in st, st[-300:])

# feedback useful on gamma (likely last by insertion/score); join needs a search first (done above)
r = call("feedback", {"name":"rkgamma","signal":"useful"}, i); i += 1
check("feedback recorded", '"recorded":true' in text(r), text(r)[:200])

r = call("model_status", {}, i); i += 1
st = text(r)
check("examples 1", '"examples":1' in st, st[-300:])
check("revision 1", '"revision":1' in st, st[-300:])
check("owner ranker", '"owner":"ranker"' in st, st[-300:])
check("initialized", '"initialized":true' in st, st[-300:])
check("train loss set", '"last_loss":' in st and "null" not in st.split('"last_loss":')[1][:12], st[-300:])

r = call("explain_rank", {"name":"rkgamma"}, i); i += 1
ex = text(r)
check("explain has neural", '"neural":' in ex and '"neural":null' not in ex, ex[-300:])

r = call("search_nodes", {"query":"shared token","limit":10}, i); i += 1
res2 = text(r)
order_after = [n for n in ["rkalpha","rkbeta","rkgamma"] if n in res2]
check("deterministic order unchanged", order_after == order_before,
      f"{order_before} vs {order_after}")

check("rank.pbmd written", os.path.exists(WORK + "/rank.pbmd"),
      os.listdir(WORK))

# obs feedback path (dec_parse gate fix): observe, then feedback kind=observation.
# Obs rowids aren't surfaced by MCP reads, so the test resolves one from the
# scratch DB directly (server itself never touches sqlite3 here).
r = call("add_observations", {"name":"rkalpha","observations":["obs one"]}, i); i += 1
d = text(r)
check("add obs", "error" not in json.dumps(r), d[:200])
import sqlite3
con = sqlite3.connect(WORK + "/tinythink.db")
oid = con.execute("select rowid from observations limit 1").fetchone()[0]
con.close()
check("obs rowid found", oid is not None and oid > 0, oid)
if oid:
    # search first so the snapshot ring holds the obs hit, then feedback it
    r = call("search_nodes", {"query":"obs one","limit":10}, i); i += 1
    r = call("feedback", {"name":str(oid),"signal":"useful","kind":"observation"}, i); i += 1
    check("obs feedback recorded", '"recorded":true' in text(r), text(r)[:200])
    i += 1
    r = call("model_status", {}, i); i += 1
    check("examples 2", '"examples":2' in text(r), text(r)[-300:])

p.stdin.close()
try:
    p.wait(timeout=5)
except Exception:
    p.kill()
print("FAILURES:", fails if fails else "none", flush=True)
sys.exit(1 if fails else 0)
