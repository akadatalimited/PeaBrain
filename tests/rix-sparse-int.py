"""Sparse rowid (60000 < cap, index path) and huge rowid (70000 >= cap,
legacy fallback) differentials. Reuses the proven forge mechanics."""
import json, subprocess, os, shutil, sys, sqlite3, struct

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pb_harness
BASE = pb_harness.require_state()
OLD = "/scratch/tmp/tixbuild"
NEW = "/scratch/tmp/int-master"
fails = []
def check(name, cond, extra=""):
    print(("PASS " if cond else "FAIL ") + name, flush=True)
    if not cond:
        fails.append(name); print("   extra:", str(extra)[:400], flush=True)

def u16(b, o): return struct.unpack(">H", b[o:o + 2])[0]
def vd(d, o):
    r = 0
    for i in range(9):
        b = d[o + i]
        if i == 8: r = (r << 8) | b; return r, 9
        r = (r << 7) | (b & 0x7F)
        if not b & 0x80: return r, i + 1
    raise ValueError("bad varint")
def ve(v):
    assert 0 <= v < 1 << 64
    if v.bit_length() <= 56:
        groups = []; vv = v
        while True:
            groups.append(vv & 0x7F); vv >>= 7
            if vv == 0: break
        out = bytearray()
        for g in reversed(groups[1:]): out.append(0x80 | g)
        out.append(groups[0])
        return bytes(out)
    out = bytearray()
    for i in range(7, -1, -1): out.append(0x80 | ((v >> (8 * i + 8)) & 0x7F))
    out.append(v & 0xFF)
    return bytes(out)
def walk(d, pgno, pages):
    b = 100 if pgno == 1 else 0
    t = d[b]
    if t == 0x0D:
        for i in range(u16(d, b + 3)): yield pgno, u16(d, b + 8 + 2 * i)
    elif t == 0x05:
        for i in range(u16(d, b + 3)):
            co = u16(d, b + 8 + 2 * i)
            ch = struct.unpack(">I", d[co:co + 4])[0]
            yield from walk(d, ch, pages)
        yield from walk(d, struct.unpack(">I", d[b + 8:b + 12])[0], pages)
    else: raise ValueError((pgno, t))
def pc(d, off):
    plen, l1 = vd(d, off); o = off + l1
    rid, l2 = vd(d, o); o += l2
    hs, l3 = vd(d, o); ho = o; o += l3
    ss = []
    while o < ho + hs:
        s, l = vd(d, o); ss.append(s); o += l
    vv = []; oo = o
    for s in ss:
        if s == 0: vv.append(b""); ln = 0
        elif s == 1: vv.append(bytes(d[oo:oo + 1])); ln = 1
        elif 2 <= s <= 6:
            ln = {2: 2, 3: 3, 4: 4, 5: 6, 6: 8}[s]
            vv.append(int.from_bytes(d[oo:oo + ln], "big"))
        elif s >= 13:
            ln = (s - 13) // 2 if s % 2 == 1 else (s - 12) // 2
            vv.append(bytes(d[oo:oo + ln]))
        else: raise ValueError(s)
        oo += ln
    return plen, l1, rid, l2, ss, vv
def table_root(pages, table):
    for _, co in walk(pages[1], 1, pages):
        plen, l1, rid, l2, ss, vv = pc(pages[1], co)
        if len(vv) >= 5 and vv[0] == b"table" and vv[1] == table.encode():
            r = vv[3]
            return r if isinstance(r, int) else int.from_bytes(r, "big")
    raise ValueError(table)
def forge_2col(path, match_rowid, c0, c1):
    raw = bytearray(open(path, "rb").read())
    pages = {p: raw[(p - 1) * 4096:p * 4096] for p in range(1, len(raw) // 4096 + 1)}
    root = table_root(pages, "usage")
    c0b, c1b = c0.encode(), c1.encode()
    s0, s1 = 13 + 2 * len(c0b), 13 + 2 * len(c1b)
    hdr = ve(1 + len(ve(s0)) + len(ve(s1))) + ve(s0) + ve(s1)
    while True:
        h = ve(len(hdr)) + ve(s0) + ve(s1)
        if len(h) == len(hdr): hdr = h; break
        hdr = h
    for pgno, co in walk(pages[root], root, pages):
        plen, l1, rid, l2, ss, vv = pc(pages[pgno], co)
        if rid != match_rowid: continue
        base = (pgno - 1) * 4096
        body = bytes(raw[base + co + l1:base + co + l1 + l2]) + hdr + c0b + c1b
        newplen = ve(len(body))
        assert len(newplen) == l1
        full = newplen + body
        oldlen = l1 + plen
        assert len(full) <= oldlen, f"too big {len(full)} > {oldlen}"
        raw[base + co:base + co + len(full)] = full
        for i in range(len(full), oldlen): raw[base + co + i] = 0
        open(path, "wb").write(raw)
        # re-parse gate
        d2 = open(path, "rb").read()[base:base + 4096]
        plen2, _, rid2, _, ss2, vv2 = pc(d2, co)
        assert rid2 == match_rowid and len(ss2) == 2
        assert vv2[0].decode() == c0 and vv2[1].decode() == c1
        return
    raise ValueError(match_rowid)

def spawn(work, binary, state, timing=False):
    shutil.copy(binary, work + "/tt")
    env = dict(os.environ, PEABRAIN_STATE_DIR=state)
    if timing: env["PEABRAIN_TIMING"] = "1"
    return subprocess.Popen([work + "/tt"], stdin=subprocess.PIPE,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE
                            if timing else subprocess.DEVNULL,
                            cwd=work, text=True, bufsize=1, env=env)
_i = [2000]
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
    try: return p.stderr.read() if p.stderr else ""
    except Exception: return ""

K = lambda kind, rid: str((kind << 56) | rid)

def build_case(tag, bigrowid):
    wd = f"/scratch/tmp/rix-{tag}-src"
    pb_harness.safe_rmtree(wd); os.makedirs(wd)
    st = pb_harness.new_state(f"rix-{tag}-src")
    p = spawn(wd, NEW, st)
    nm = f"sparse-target-with-long-name-{tag}"
    call(p, "write_fact", {"name": nm, "text": "sparse body here"})
    stop(p)
    db = st + "/peabrain.db"
    con = sqlite3.connect(db)
    frow = con.execute("select rowid from facts where name=?", (nm,)).fetchone()[0]
    con.execute("insert into facts(rowid,name,body) values(?,?,?)",
                (bigrowid, f"sparsefact-{bigrowid}", "sparse body"))
    con.commit()
    # move the facts row to bigrowid by rewriting name? simpler: feedback the
    # bigrowid fact via its name, then forge its usage row to legacy K(2,bigrowid)
    con.close()
    p = spawn(wd, NEW, st)
    call(p, "feedback", {"name": f"sparsefact-{bigrowid}", "signal": "useful"})
    stop(p)
    con = sqlite3.connect(db)
    urow = con.execute("select rowid from usage").fetchall()[-1][0]
    con.close()
    forge_2col(db, urow, K(2, bigrowid), "11")
    return db, nm, f"sparsefact-{bigrowid}"

def run_case(tag, bigrowid, expect_ok):
    db, nm, bighame = build_case(tag, bigrowid)
    outs = {}
    for label, binary in (("old", OLD), ("new", NEW)):
        work = f"/scratch/tmp/rix-{tag}-{label}"
        pb_harness.safe_rmtree(work); os.makedirs(work)
        st = pb_harness.new_state(f"rix-{tag}-{label}")
        shutil.copy(db, st + "/peabrain.db")
        p = spawn(work, binary, st, timing=(label == "new"))
        h = text(call(p, "health", {}))
        e1 = text(call(p, "explain_rank", {"name": nm}))
        e2 = text(call(p, "explain_rank", {"name": bighame}))
        s = text(call(p, "search_nodes", {"query": "sparse", "limit": 10}))
        err = stop(p)
        outs[label] = (h, e1, e2, s, err)
    ho, e1o, e2o, so, _ = outs["old"]
    hn, e1n, e2n, sn, errn = outs["new"]
    check(f"{tag} tracked equal",
          ho.split('"usage_tracked":')[1].split(",")[0] ==
          hn.split('"usage_tracked":')[1].split(",")[0], (ho, hn))
    check(f"{tag} explains identical", e1o == e1n and e2o == e2n,
          f"{e1o[-120:]} vs {e1n[-120:]} / {e2o[-120:]} vs {e2n[-120:]}")
    check(f"{tag} search identical", so == sn, f"{so[:160]} vs {sn[:160]}")
    import re
    m = re.search(r"rindex_ok=(\d)", errn)
    check(f"{tag} rindex_ok={expect_ok}", m and m.group(1) == str(expect_ok),
          errn.strip().split("\n")[1] if errn else "no stderr")

run_case("sparse60000", 60000, 1)
run_case("huge70000", 70000, 0)
print("FAILURES:", fails if fails else "none", flush=True)
sys.exit(1 if fails else 0)
