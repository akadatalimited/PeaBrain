import json, subprocess, sys, os, shutil
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pb_harness
_PB_BASE = pb_harness.require_state()
BIN = sys.argv[1] if len(sys.argv) > 1 else "/scratch/tmp/PeaBrain"
WORK = "/scratch/tmp/concblast-work"
ST = pb_harness.new_state("concblast")  # one state shared by all 4 procs: real lock contention
ENV = dict(os.environ, PEABRAIN_STATE_DIR=ST)
pb_harness.safe_rmtree(WORK); os.makedirs(WORK)
shutil.copy(BIN, WORK + "/tt")
def gen(k):
    lines = []
    i = 0
    for r in range(15):
        i += 1; lines.append(json.dumps({"jsonrpc":"2.0","id":i,"method":"tools/call","params":{"name":"write_fact","arguments":{"name":"mi-p%d-f%d"%(k,r),"text":"t%d%d"%(k,r)}}}))
        i += 1; lines.append(json.dumps({"jsonrpc":"2.0","id":i,"method":"tools/call","params":{"name":"feedback","arguments":{"name":"mi-p%d-f%d"%(k,r),"signal":"useful"}}}))
        i += 1; lines.append(json.dumps({"jsonrpc":"2.0","id":i,"method":"tools/call","params":{"name":"conclusion","arguments":{"reason":"mr-p%d-%d"%(k,r),"conclusion":"c"}}}))
    return "\n".join(lines) + "\n"
procs = []
for k in range(4):
    p = subprocess.Popen([WORK+"/tt"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, cwd=WORK, text=True, env=ENV)
    procs.append((p, gen(k)))
for p, inp in procs: p.stdin.write(inp)
errs = 0
for p, inp in procs:
    p.stdin.close()
    for line in p.stdout.read().strip().split("\n"):
        if '"error"' in line:
            errs += 1; print("ERR:", line[:160])
    p.wait()
print("total errors:", errs)
sys.exit(1 if errs else 0)
