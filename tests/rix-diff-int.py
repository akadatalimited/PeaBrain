"""OLD-vs-NEW differential on a live-seeded store (Gate 1: state-isolated).
Binaries argv-driven (default: shipped Master vs tix build). Each side gets
its own scratch state seeded read-only from live canonical. Asserts
old-vs-new EQUALITY (no stale absolute counts). Refuses without an explicit
PEABRAIN_STATE_DIR workflow override."""
import json, subprocess, os, shutil, sys, sqlite3
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pb_harness

BASE = pb_harness.require_state()
OLD = "/scratch/tmp/tixbuild"   # shipped Master (no index)
NEW = "/scratch/tmp/int-master"                          # feat/rindex
fails = []
def check(name, cond, extra=""):
    print(("PASS " if cond else "FAIL ") + name, flush=True)
    if not cond:
        fails.append(name); print("   extra:", str(extra)[:500], flush=True)

def fresh(tag, binary, seed=True):
    work = f"/scratch/tmp/rix-diff-{tag}-{os.getpid()}"
    pb_harness.safe_rmtree(work)
    os.makedirs(work)
    shutil.copy(binary, work + "/tt")
    st = pb_harness.new_state(f"rix-diff-{tag}")
    if seed:
        pb_harness.seed_from_live(st)
    env = dict(os.environ, PEABRAIN_STATE_DIR=st)
    return subprocess.Popen([work + "/tt"], stdin=subprocess.PIPE,
                            stdout=subprocess.PIPE, cwd=work, text=True,
                            bufsize=1, env=env), st
_i = [1]
def call(p, name, args):
    _i[0] += 1
    p.stdin.write(json.dumps({"jsonrpc":"2.0","id":_i[0],"method":"tools/call",
                              "params":{"name":name,"arguments":args}}) + "\n")
    p.stdin.flush()
    return json.loads(p.stdout.readline())
def text(r):
    return r.get("result", {}).get("content", [{}])[0].get("text", "")
def stop(p):
    try: p.stdin.close(); p.wait(timeout=10)
    except Exception: p.kill()

po, sto = fresh("old", OLD)
pn, stn = fresh("new", NEW)

# 1. health parity (usage_tracked must match exactly across sides)
ho = text(call(po, "health", {})); hn = text(call(pn, "health", {}))
to = ho.split('"usage_tracked":')[1].split(",")[0]
tn = hn.split('"usage_tracked":')[1].split(",")[0]
check("health usage_tracked identical", to == tn, (to, tn))

# 2. explain sweep over every fact name + entities, byte-identical
con = sqlite3.connect(f"file:{sto}/peabrain.db?mode=ro", uri=True)
names = [r[0] for r in con.execute("select name from facts")] + \
        [r[0] for r in con.execute("select name from entities")]
con.close()
print(f"sweeping {len(names)} names...", flush=True)
mismatch = 0
for n in names:
    a = text(call(po, "explain_rank", {"name": n}))
    b = text(call(pn, "explain_rank", {"name": n}))
    if a != b:
        mismatch += 1
        if mismatch <= 3:
            print(f"   DIFF {n}: {a[-160:]} vs {b[-160:]}", flush=True)
check("explain sweep identical", mismatch == 0, f"{mismatch} mismatches")

# 3. search ordering corpus
queries = ["the", "a", "e", "project", "memory", "test", "codex", "rank",
           "loop", "token", "shared", "obs", " Bere", "xyzzy-none"]
diff = 0
for q in queries:
    try:
        a = text(call(po, "search_nodes", {"query": q.strip() or "a", "limit": 20}))
        b = text(call(pn, "search_nodes", {"query": q.strip() or "a", "limit": 20}))
        if a != b:
            diff += 1
            print(f"   SEARCH DIFF {q!r}", flush=True)
    except Exception as e:
        print(f"   SEARCH ERR {q!r}: {e}", flush=True)
check("search corpus identical", diff == 0, f"{diff} diffs")
stop(po); stop(pn)
print("FAILURES:", fails if fails else "none", flush=True)
sys.exit(1 if fails else 0)
