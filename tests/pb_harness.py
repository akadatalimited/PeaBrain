"""PeaBrain test-harness guard (Gate 1). Every test script that launches the
server must import this module and obtain its state EXCLUSIVELY through it.

Contract:
- require_state(): the PEABRAIN_STATE_DIR override MUST already be set by the
  test workflow to an explicit unique dir under /scratch/tmp. Missing,
  non-/scratch/tmp, or live-canonical values REFUSE execution (exit 2).
  Never falls back to ~/.local/share/peabrain. Never modifies production.
- new_state(sub): fresh unique scratch dir for per-case/per-binary state.
  Requires a validated base (refuses otherwise). Does not mutate os.environ.
- seed_from_live(dest): the ONLY sanctioned live touch: read-only copy of
  the canonical db+weights into a scratch dir (0700/0600). Never writes live.
- safe_rmtree(path): removes ONLY paths strictly under /scratch/tmp that are
  not the live canonical dir. Anything else refuses.
"""
import os
import shutil
import stat
import sys
import time

LIVE_STATE = os.path.realpath(os.path.expanduser("~/.local/share/peabrain"))
SCRATCH = "/scratch/tmp"


def _refuse(msg):
    sys.stderr.write(f"pb_harness: REFUSING: {msg}\n")
    sys.stderr.flush()
    raise SystemExit(2)


def _real(p):
    try:
        return os.path.realpath(p)
    except Exception:
        return p


def require_state():
    """Validate the workflow-provided override. Returns its real path."""
    v = os.environ.get("PEABRAIN_STATE_DIR", "")
    if not v:
        _refuse("PEABRAIN_STATE_DIR is not set; refusing to fall back to "
                f"production ({LIVE_STATE}). The test workflow must export an "
                "explicit unique dir under /scratch/tmp.")
    r = _real(v)
    if r == LIVE_STATE or r.startswith(LIVE_STATE + os.sep):
        _refuse(f"PEABRAIN_STATE_DIR={v!r} targets live canonical state.")
    if not (r == SCRATCH or r.startswith(SCRATCH + os.sep)):
        _refuse(f"PEABRAIN_STATE_DIR={v!r} is not under /scratch/tmp.")
    try:
        os.makedirs(r, mode=0o700, exist_ok=True)
        os.chmod(r, 0o700)
    except Exception as e:
        _refuse(f"cannot prepare {r}: {e}")
    return r


def new_state(sub):
    """Fresh unique scratch dir. Refuses unless a valid base is set."""
    base = require_state()
    tag = "".join(c if (c.isalnum() or c in "-_") else "_" for c in str(sub))[:40]
    d = os.path.join(SCRATCH, f"pbstate-{tag}-{os.getpid()}-{int(time.time()*1000)}")
    if _real(d) == LIVE_STATE:
        _refuse("generated state path collides with live (impossible).")
    os.makedirs(d, mode=0o700, exist_ok=False)
    return d


def seed_from_live(dest):
    """Read-only copy of canonical db+weights into dest (created 0700),
    renamed to current filenames (peabrain.db / peabrain-rank.pbmd)."""
    os.makedirs(dest, mode=0o700, exist_ok=True)
    os.chmod(dest, 0o700)
    for dst_name, candidates in (("peabrain.db", ("peabrain.db", "tinythink.db")),
                              ("peabrain-rank.pbmd", ("peabrain-rank.pbmd", "rank.pbmd"))):
        src = next((os.path.join(LIVE_STATE, c) for c in candidates
                    if os.path.isfile(os.path.join(LIVE_STATE, c))), None)
        if src is None:
            _refuse(f"live canonical file missing (tried {candidates})")
        assert src is not None
        shutil.copy2(src, os.path.join(dest, dst_name))
        os.chmod(os.path.join(dest, dst_name), 0o600)
    return dest


def safe_rmtree(path):
    """Remove a scratch test dir. Refuses live/foreign/empty targets."""
    if not path:
        _refuse("safe_rmtree called with empty path.")
    r = _real(path)
    if r == LIVE_STATE or r.startswith(LIVE_STATE + os.sep):
        _refuse(f"safe_rmtree target is live canonical state: {path!r}")
    if not r.startswith(SCRATCH + os.sep):
        _refuse(f"safe_rmtree target not under /scratch/tmp: {path!r}")
    if len(r) <= len(SCRATCH) + 1:
        _refuse(f"safe_rmtree target too broad: {path!r}")
    shutil.rmtree(r, ignore_errors=True)
