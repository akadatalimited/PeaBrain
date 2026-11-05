"""Gate 3 regression runner. Runs every suite with a fresh workflow base
dir, records live canonical fingerprints before/after EACH suite, and
refuses to continue if live moves (proving isolation, not just asserting).
Usage: PEABRAIN_STATE_DIR must NOT be preset; the runner mints per-suite
dirs itself. Exits nonzero on any suite failure or live drift."""
import os, subprocess, sys, hashlib

LIVE_DIR = os.path.expanduser("~/.local/share/peabrain")
def _live_file(*names):
    for n in names:
        p = os.path.join(LIVE_DIR, n)
        if os.path.isfile(p):
            return p
    raise SystemExit("g3-run: no live canonical file (tried %s)" % (names,))
LIVE_DB = _live_file("peabrain.db", "tinythink.db")
LIVE_RK = _live_file("peabrain-rank.pbmd", "rank.pbmd")
TIX = "/scratch/tmp/PeaBrain"
TIXSC = "/scratch/tmp/PeaBrain-scalar"
OLD = "/scratch/tmp/tixbuild"
SUITES = "/scratch/fasm-webserver/tinythink/tests/suites"

def fp():
    h1 = hashlib.md5(open(LIVE_DB, 'rb').read()).hexdigest()
    h2 = hashlib.md5(open(LIVE_RK, 'rb').read()).hexdigest()
    return h1, h2

def sh(cmd, base):
    env = dict(os.environ, PEABRAIN_STATE_DIR=base)
    return subprocess.run(cmd, capture_output=True, text=True, timeout=3000,
                          cwd="/tmp", env=env)

PLAN = [
    ("strunc-matrix", ["python3", "/scratch/fasm-webserver/tinythink/tests/strunc-matrix.py", TIX]),
    ("tix-quux", ["python3", "/scratch/fasm-webserver/tinythink/tests/tix-quux.py"]),
    ("tix-stock", ["python3", "/scratch/fasm-webserver/tinythink/tests/tix-stock.py"]),
    ("tix-oracle", ["python3", "/scratch/fasm-webserver/tinythink/tests/tix-oracle.py"]),
    ("v3diff", ["python3", f"{SUITES}/v3diff-c.py", OLD, TIX]),
    ("advtest", ["python3", f"{SUITES}/advtest-st.py", TIX]),
    ("memtest", ["python3", f"{SUITES}/memtest-st.py", TIX]),
    ("conctest", ["python3", f"{SUITES}/conctest-st.py", TIX]),
    ("thinktest", ["python3", f"{SUITES}/thinktest-st.py", TIX]),
    ("mdtest2-avx2", ["python3", f"{SUITES}/mdtest2-st.py", TIX, "avx2fma"]),
    ("mdtest2-scalar", ["python3", f"{SUITES}/mdtest2-st.py", TIXSC, "reference"]),
    ("st-battery", ["python3", "/scratch/fasm-webserver/tinythink/tests/st-battery-tix.py"]),
    ("t-tick", ["python3", "/scratch/fasm-webserver/tinythink/tests/t_tick.py", TIX]),
    ("rix-diff", ["python3", "/scratch/fasm-webserver/tinythink/tests/rix-diff.py", OLD, TIX]),
    ("rix-edge", ["python3", "/scratch/fasm-webserver/tinythink/tests/rix-edge.py", OLD, TIX]),
    ("rix-edge2", ["python3", "/scratch/fasm-webserver/tinythink/tests/rix-edge2.py", OLD, TIX]),
    ("rix-sparse", ["python3", "/scratch/fasm-webserver/tinythink/tests/rix-sparse.py", OLD, TIX]),
    ("tix-cap", ["python3", "/scratch/fasm-webserver/tinythink/tests/tix-cap.py", OLD, TIX]),
]

def main():
    import time as _t
    global RUNID
    RUNID = f"{os.getpid()}-{int(_t.time())}"
    base_fp = fp()
    print(f"live before: db={base_fp[0]} rk={base_fp[1]}", flush=True)
    bad = []
    for i, (name, cmd) in enumerate(PLAN):
        base = f"/scratch/tmp/g3-{RUNID}-{i:02d}-{name}"
        os.makedirs(base, mode=0o700, exist_ok=True)
        r = sh(cmd, base)
        tail = (r.stdout.strip().split("\n")[-1] if r.stdout.strip() else "?")
        now = fp()
        drift = now != base_fp
        print(f"[{name}] rc={r.returncode} tail={tail[:90]} live_drift={drift}",
              flush=True)
        if r.returncode != 0:
            bad.append(name + " FAILED")
            print(f"--- stdout tail ---\n" + "\n".join(r.stdout.split("\n")[-8:]))
            print(f"--- stderr tail ---\n" + "\n".join(r.stderr.split("\n")[-8:]))
        if drift:
            bad.append(name + " MOVED LIVE")
            print(f"LIVE DRIFT: {base_fp} -> {now}", flush=True)
            break
    print("G3:", "FAIL: " + str(bad) if bad else "ALL GREEN, LIVE UNCHANGED", flush=True)
    sys.exit(1 if bad else 0)

if __name__ == "__main__":
    main()
