import json, subprocess, sys, os, shutil
import sys as _pb_sys
_pb_sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import pb_harness
_PB_ST = pb_harness.require_state()
BIN_SRC = sys.argv[1] if len(sys.argv) > 1 else "/scratch/tmp/rk-ttm"
BACKEND = sys.argv[2] if len(sys.argv) > 2 else "avx2fma"
WORK = "/scratch/tmp/rk-mdtest2"
shutil.rmtree(WORK, ignore_errors=True)
os.makedirs(WORK)
shutil.copy(BIN_SRC, WORK + "/tt")
BIN = WORK + "/tt"
p = subprocess.Popen([BIN], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                     cwd=WORK, text=True, bufsize=1)
fails = []
def check(name, cond, extra=""):
    print(("PASS " if cond else "FAIL ") + name, flush=True)
    if not cond:
        fails.append(name)
        print("   extra:", str(extra)[:300], flush=True)
nid = [0]
def call(name, args):
    nid[0] += 1
    p.stdin.write(json.dumps({"jsonrpc": "2.0", "id": nid[0], "method": "tools/call",
                              "params": {"name": name, "arguments": args}}) + "\n")
    p.stdin.flush()
    return json.loads(p.stdout.readline())
def text(r):
    try: return r["result"]["content"][0]["text"]
    except Exception: return ""
def jtext(r):
    try: return json.loads(text(r))
    except Exception: return {"_raw": text(r)[:200]}
p.stdin.write('{"jsonrpc":"2.0","id":100,"method":"tools/list","params":{}}\n'); p.stdin.flush()
tools = [t["name"] for t in json.loads(p.stdout.readline())["result"]["tools"]]
check("27-tools", len(tools) == 27, len(tools))
for _t in ["model_init", "model_train", "model_predict", "model_save", "model_load", "model_status"]:
    check("has-" + _t, _t in tools)
t = jtext(call("model_status", {}))
check("status-uninit", t.get("initialized") is False and t.get("step") == 0, t)
r = call("model_train", {"xs": [1.0], "ys": [0.0], "targets": [1.0]})
check("train-no-model-err", "error" in r, r)
r = call("model_predict", {"xs": [1.0], "ys": [0.0]})
check("predict-no-model-err", "error" in r, r)
r = call("model_init", {"hidden": 0})
check("init-hidden0-err", "error" in r, r)
r = call("model_init", {"hidden": 17})
check("init-hidden17-err", "error" in r, r)
r = call("model_init", {"activation": "sigmoid"})
check("init-badact-err", "error" in r, r)
t = jtext(call("model_init", {"hidden": 8}))
check("init-ok", t.get("ok") is True, t)
t = jtext(call("model_status", {}))
check("status-init", t.get("initialized") is True and t.get("backend") == BACKEND, t)
def tgt(x, y): return 2.5 * x - 1.7 * y + 0.8
grid = [(-1.5 + i * 0.4, -1.0 + j * 0.5) for i in range(8) for j in range(4)]
losses = []
for _ in range(25):
    t = jtext(call("model_train", {"xs": [g[0] for g in grid],
                                   "ys": [g[1] for g in grid],
                                   "targets": [tgt(*g) for g in grid],
                                   "lr": 0.02, "steps": 20}))
    losses.append(t.get("train_loss", 9))
check("train-falls", losses[-1] < losses[0] * 0.05, (losses[0], losses[-1]))
ux, uy = [0.9, -0.7, 0.1, -1.3], [-0.35, 0.15, -0.75, -0.55]
vs = jtext(call("model_predict", {"xs": ux, "ys": uy})).get("values", [])
check("unseen", len(vs) == 4 and all(abs(v - tgt(x, y)) < 0.05 for v, x, y in zip(vs, ux, uy)), vs)
mp = WORK + "/m.pbmd"
t = jtext(call("model_status", {}))
check("status-steps", t.get("step") == 500, t)
t = jtext(call("model_save", {"path": mp}))
check("save-ok", t.get("ok") is True, t)
check("save-840", os.path.isfile(mp) and os.path.getsize(mp) == 840,
      os.path.getsize(mp) if os.path.isfile(mp) else "missing")
r = call("model_save", {"path": "../evil.pbmd"})
check("save-traversal-err", "error" in r, r)
# same-process roundtrip (the Codex catch)
t = jtext(call("model_init", {"hidden": 8}))
t = jtext(call("model_load", {"path": mp}))
check("live-load", t.get("ok") is True and t.get("step") == 500, t)
vb = jtext(call("model_predict", {"xs": ux, "ys": uy})).get("values")
check("live-identical", vb == vs, (vs, vb))
p.stdin.close(); p.wait()
p = subprocess.Popen([BIN], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                     cwd=WORK, text=True, bufsize=1)
nid[0] = 1000
t = jtext(call("model_load", {"path": mp}))
check("fresh-load", t.get("ok") is True and t.get("step") == 500, t)
vc = jtext(call("model_predict", {"xs": ux, "ys": uy})).get("values")
check("fresh-identical", vc == vs, (vs, vc))
t = jtext(call("model_train", {"xs": [g[0] for g in grid],
                               "ys": [g[1] for g in grid],
                               "targets": [tgt(*g) for g in grid],
                               "lr": 0.02, "steps": 5}))
check("resume-trains", t.get("step") == 505, t)
with open(WORK + "/bad.pbmd", "wb") as f:
    f.write(b"GARBAGE" * 10)
r = call("model_load", {"path": WORK + "/bad.pbmd"})
check("load-bad-err", "error" in r, r)
t = jtext(call("model_status", {}))
check("model-survives-badload", t.get("step") == 505, t)
r = call("model_load", {"path": WORK + "/nonexistent.pbmd"})
check("load-missing-err", "error" in r, r)
t = jtext(call("write_fact", {"name": "probe1", "text": "hello"}))
t2 = jtext(call("read_fact", {"name": "probe1"}))
check("fact-roundtrip", "hello" in json.dumps(t2), t2)
t = jtext(call("health", {}))
check("health-ok", "tables" in json.dumps(t), str(t)[:100])
p.stdin.close(); p.wait()
print("FAILURES:", fails if fails else "none")
sys.exit(1 if fails else 0)
