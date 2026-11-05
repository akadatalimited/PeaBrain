"""PEABRAIN_STATE_DIR battery: override fresh/refuse, default path, no-home,
explicit user paths, isolation, retrain, perms, CWD-ignored."""
import json, subprocess, os, shutil, sys, stat

BIN = "/scratch/tmp/stbuild"
import sys as _pb_sys
_pb_sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pb_harness
_PB_BASE = pb_harness.require_state()
fails = []
def check(name, cond, extra=""):
    print(("PASS " if cond else "FAIL ") + name, flush=True)
    if not cond:
        fails.append(name); print("   extra:", str(extra)[:300], flush=True)

def run_raw(work, binary, env_extra=None, reqs=()):
    env = dict(os.environ)
    if env_extra:
        env.update(env_extra)
    p = subprocess.Popen([binary], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                         stderr=subprocess.PIPE, cwd=work, text=True, bufsize=1, env=env)
    outs = []
    for i, (name, args) in enumerate(reqs, 1):
        p.stdin.write(json.dumps({"jsonrpc":"2.0","id":i,"method":"tools/call",
                                  "params":{"name":name,"arguments":args}}) + "\n")
        p.stdin.flush()
        line = p.stdout.readline()
        outs.append(json.loads(line) if line.strip() else None)
    try:
        p.stdin.close(); rc = p.wait(timeout=15)
    except Exception:
        p.kill(); rc = "killed"
    try:
        err = p.stderr.read() or ""
    except Exception:
        err = ""
    return outs, rc, err

def run(work, binary, env_extra=None, reqs=()):
    return run_raw(work, binary, env_extra, reqs)

def text(r):
    return r["result"]["content"][0]["text"]

def fresh(work):
    shutil.rmtree(work, ignore_errors=True); os.makedirs(work)
    shutil.copy(BIN, work + "/tt")

# T1: override fresh dir -> creates DB there on first write; perms
W1 = "/scratch/tmp/st-t1"
fresh(W1)
S1 = W1 + "/state1"
outs, rc, err = run(W1, W1 + "/tt", {"PEABRAIN_STATE_DIR": S1},
                    [("write_fact", {"name": "s1", "text": "x"}),
                     ("health", {})])
check("T1 boots+writes", rc == 0, (rc, err[-200:]))
st = os.stat(S1 + "/tinythink.db")
check("T1 db 0600", oct(st.st_mode & 0o777) == "0o600", oct(st.st_mode))
check("T1 dir 0700", oct(os.stat(S1).st_mode & 0o777) == "0o700",
      oct(os.stat(S1).st_mode))
check("T1 health fresh", json.loads(text(outs[1]))["tables"] == 7,
      text(outs[1])[:120])

# T2: override empty + populated legacy (exe-dir AND cwd) -> loud refusal
# (no stdout response by design: the server exits during boot).
W2 = "/scratch/tmp/st-t2"
fresh(W2)
shutil.copy("/scratch/fasm-webserver/tinythink/tinythink.db.bak-20261105-rank",
            W2 + "/tinythink.db")
S2 = W2 + "/empty-state"
outs, rc, err = run(W2, W2 + "/tt", {"PEABRAIN_STATE_DIR": S2},
                    [("health", {})])
check("T2 refuses (nonzero exit)", rc not in (0, "killed"), rc)
check("T2 no response (refused at boot)", outs == [None], outs)
check("T2 names both paths", "empty-state" in err and "tinythink.db" in err,
      err[-300:])
check("T2 creates nothing", not os.path.exists(S2 + "/tinythink.db") and
      not os.path.exists(S2), (os.listdir(W2)))

# T3: default path via fake HOME
W3 = "/scratch/tmp/st-t3"
fresh(W3)
FH = W3 + "/fakehome"
os.makedirs(FH, mode=0o700)
env = dict(os.environ); env["HOME"] = FH
env.pop("PEABRAIN_STATE_DIR", None)
p = subprocess.Popen([W3 + "/tt"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                     cwd=W3, text=True, bufsize=1, env=env)
p.stdin.write('{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"write_fact","arguments":{"name":"h","text":"y"}}}\n')
p.stdin.flush(); json.loads(p.stdout.readline())
try: p.stdin.close(); p.wait(timeout=15)
except Exception: p.kill()
check("T3 default path used", os.path.exists(FH + "/.local/share/peabrain/tinythink.db"))
check("T3 default dir 0700",
      oct(os.stat(FH + "/.local/share/peabrain").st_mode & 0o777) == "0o700")

# T4: no HOME, no override -> clean fatal
W4 = "/scratch/tmp/st-t4"
fresh(W4)
env = {k: v for k, v in os.environ.items() if k not in ("HOME", "PEABRAIN_STATE_DIR")}
p = subprocess.Popen([W4 + "/tt"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                     cwd=W4, text=True, bufsize=1, env=env)
try: rc = p.wait(timeout=15)
except Exception: p.kill(); rc = "killed"
check("T4 no-home fatal", rc not in (0, None) and rc != "killed", rc)

# T5: explicit user-model paths stay CWD-relative
W5 = "/scratch/tmp/st-t5"
fresh(W5)
S5 = W5 + "/s5"
outs, rc, err = run(W5, W5 + "/tt", {"PEABRAIN_STATE_DIR": S5},
                    [("model_init", {"hidden": 4}),
                     ("model_save", {"path": "mymodel.pbmd"})])
check("T5 explicit save lands in CWD", os.path.exists(W5 + "/mymodel.pbmd"),
      os.listdir(W5))
check("T5 no stray in state", not os.path.exists(S5 + "/mymodel.pbmd"))

# T6: independent stores via separate overrides
WA = "/scratch/tmp/st-t6a"
WB = "/scratch/tmp/st-t6b"
for W in (WA, WB):
    fresh(W)
outs, _, _ = run(WA, WA + "/tt", {"PEABRAIN_STATE_DIR": WA + "/sa"},
                 [("write_fact", {"name": "onlyA", "text": "a"})])
outs, _, _ = run(WB, WB + "/tt", {"PEABRAIN_STATE_DIR": WB + "/sb"},
                 [("write_fact", {"name": "onlyB", "text": "b"})])
import sqlite3
na = sqlite3.connect(f"file:{WA}/sa/tinythink.db?mode=ro", uri=True).execute(
    "select name from facts").fetchall()
nb = sqlite3.connect(f"file:{WB}/sb/tinythink.db?mode=ro", uri=True).execute(
    "select name from facts").fetchall()
check("T6 isolation", na == [("onlyA",)] and nb == [("onlyB",)], (na, nb))

# T7: missing rank.pbmd + present examples -> trains from scratch
W7 = "/scratch/tmp/st-t7"
fresh(W7)
S7 = W7 + "/s7"
os.makedirs(S7, mode=0o700)
shutil.copy("/scratch/fasm-webserver/tinythink/tinythink.db",
            S7 + "/tinythink.db")
outs, rc, err = run(W7, W7 + "/tt", {"PEABRAIN_STATE_DIR": S7},
                    [("search_nodes", {"query": "the", "limit": 5}),
                     ("model_status", {})])
st = json.loads(outs[1]["result"]["content"][0]["text"])
check("T7 examples load without weights", st["rank"]["examples"] > 0,
      str(st["rank"])[:160])

# T9: inaccessible override -> clean fatal, nothing elsewhere
W9 = "/scratch/tmp/st-t9"
fresh(W9)
S9 = W9 + "/noperm"
os.makedirs(S9, mode=0o700)
os.chmod(S9, 0)
outs, rc, err = run(W9, W9 + "/tt", {"PEABRAIN_STATE_DIR": S9},
                    [("health", {})])
os.chmod(S9, 0o700)
check("T9 denied fatal", rc not in (0, "killed"), rc)
check("T9 message", "inaccessible" in err or "denied" in err.lower() or "state" in err,
      err[-200:])

# T10: populated CWD db ignored when canonical populated (different sources
# so the served side is distinguishable: canonical=live, CWD=old backup).
W10 = "/scratch/tmp/st-t10"
fresh(W10)
S10 = W10 + "/s10"
os.makedirs(S10, mode=0o700)
shutil.copy("/scratch/fasm-webserver/tinythink/tinythink.db",
            S10 + "/tinythink.db")
shutil.copy("/scratch/fasm-webserver/tinythink/tinythink.db.bak-20261105-rank",
            W10 + "/tinythink.db")
import hashlib
before = hashlib.md5(open(W10 + "/tinythink.db", "rb").read()).hexdigest()
outs, rc, err = run(W10, W10 + "/tt", {"PEABRAIN_STATE_DIR": S10},
                    [("health", {})])
after = hashlib.md5(open(W10 + "/tinythink.db", "rb").read()).hexdigest()
check("T10 CWD copy untouched", before == after)
served = json.loads(text(outs[0]))["usage_tracked"]
check("T10 canonical served (live count, not backup)", served != 19203, served)

print("FAILURES:", fails if fails else "none", flush=True)
sys.exit(1 if fails else 0)
