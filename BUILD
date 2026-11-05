tinythink - thinking + memory MCP server in pure x86-64 assembly
===============================================================

Sequential-thinking mimic plus a conclusion tool and a small memory
core, backed by a real SQLite database written in pure asm (model code
in model/*.asm includes, no libc). One ~49K statically-linked Linux binary.

Needs: fasm (flat assembler) 1.73+, Linux x86-64 with x86-64-v3
microarchitecture (AVX/AVX2/FMA/BMI1/BMI2/LZCNT; check
/proc/cpuinfo). The binary gates on CPUID at startup (stderr +
exit 1 on older CPUs) because FASM emits no runtime check.

Build
-----
  fasm -m 65536 tinythink.asm tinythink            # v3 baseline binary
  fasm -m 65536 -dUSE_SCALAR=1 tinythink.asm tinythink-scalar   # scalar A/B reference
(-m 65536: trailing BSS outgrew FASM's default 16 MB heap.)

Run (MCP stdio: newline-delimited JSON-RPC on stdin/stdout)
-----
  ./tinythink

Use
---
Register as a local MCP server, e.g. opencode.json:

  { "mcp": { "tinythink": {
      "type": "local",
      "command": ["/path/to/tinythink"],
      "enabled": true } } }

Serves both protocol eras: 2026-07-28 clients (server/discover, no
handshake) and 2025-era clients (initialize). Methods: initialize,
server/discover, ping, tools/list, tools/call. No-id = notification.

Thinking tools
--------------
sequential_thinking: record thoughts, revise, branch, track progress.
  Required: thought (1..2048), nextThoughtNeeded (bool),
  thoughtNumber/totalThoughts (ints >= 1). Optional: isRevision,
  revisesThought, branchFromThought, branchId (0..40), needsMoreThoughts.
  revisesThought/branchFromThought must name recorded thoughts
  (1..hcount) or the call is refused with "unknown thought".
  History lives in RAM per connection (64-slot ring, one process =
  one isolated session).
thought_history {limit? 1..64, default 10}: last N thoughts, oldest first.
thought_reset {confirm:true}: clear the connection history.

Memory tools (tinythink.db, created on first use beside the executable)
-----------------------------------------------------------------------
conclusion {reason, thought?, conclusion?, valid?}: conclusions table
  (reason TEXT, thought TEXT, conclusion TEXT, valid INTEGER).
  reason 1..64 ascii; thought 0..512; conclusion 1..512.
  conclusion present -> insert (duplicate reason refused); else valid
  present -> set the valid flag (invalidate false / revalidate true);
  else read the row by reason.
read_fact {name} / write_fact {name,text} / list_facts {}: facts table
  (name TEXT, body TEXT), append-only versions, latest rowid wins.
  Names 1..128 [A-Za-z0-9._@:+#~-]; bodies 0..4096 ascii.
delete_fact {name} / delete_fact_prefix {prefix} / read_fact_versions {name}:
  tombstones(name) table; tombstoned names read as missing everywhere
  (facts, entities, search, open) and refuse writes ("tombstoned",
  write-once, no resurrect). Prefix bulk-tombstones benchmark
  namespaces (cap 128, reports capped). Versions lists every version
  newest-first with a current flag plus tombstone state. Tombstones
  hide rows but bytes remain on disk: NOT secure deletion.
health {}: {tables, pages, journal, cache_used, usage_tracked,
  pending_flush} for operators.
create_entities {name, type?, project?, observations?[]}: entities table.
  Duplicate names return the existing row with created:false.
add_observations {name, observations[1..16]}: appends (auto-creates
  the entity as a stub). Bodies 0..1024 ascii each.
create_relations {from, to, type}: relations table, duplicate triples
  return the existing row.
search_nodes {query, limit? 1..20}: case-sensitive substring over
  entity names/types, observation bodies, fact names/bodies.
open_nodes {names[1..16]}: entities with observations (cap 50) and
  relations both directions (cap 50); missing names report missing:true.
create_task_or_note {title, body?, status?, project?, priority?}:
  tasks table with stable integer ids (header taskseq). Status one of
  not_started/in_progress/done/archived/cancelled (default not_started);
  priority low/medium/high/critical (default medium).
query_tasks {status?, project?, search?, limit? 1..50}: newest-first,
  one row per task id (latest version wins).
update_task {id, title?, body?, status?, project?, priority?}: records
  a new version under the same id; id stays stable.

Simplified vs full knowledge-graph semantics: no FTS/BM25 ranking
(substring match), no visibility/projects graph, no debate/bridge
machinery. Documented limits: cells <= ~1100B, interiors split at any
depth (right-edge appends; root keeps its number, no master rewrite),
output budgets cap large listings, seen-sets cap distinct scans
(facts 128, tasks 512). Validated: 100K-row volume, depth 3, zero
orphans, pragma integrity_check clean throughout.

SQLite subset (genuine on-disk format: pragma integrity_check passes,
opens in real sqlite3, bidirectional, old DBs gain new tables on open):
page size 4096, UTF-8, sqlite_master + data tables, rowid leaf pages,
size-ordered leaf splits, root interior on first split, dead space on
the freelist, whole-db flock, fsync per write txn. No overflow pages;
rollback journal (TJRR) with recovery + truncate on open, commit
(fsync, unlink, dirsync) on close. Read-only txns skip fsync entirely.
Master rootpage uses minimal width (int8 to 127 pages, int16 to 32767;
read side always supported both). A corrupt master row for the
engine-owned usage table is dropped and recreated on open (validated
by root range); user tables are never auto-repaired.

  Multi-access (no WAL file; lock modes instead): reads take LOCK_SH
  and run fully concurrently; writes take LOCK_EX. A reader escalates
  (UN then EX — never upgrade, which could deadlock two upgraders)
  only when mutation may be needed: empty DB, a leftover journal, or
  a missing table. Recovery always runs under EX. One pipe still
  serves requests sequentially: concurrent clients must match replies
  by id (pipelined 20/20 verified); naive FIFO pairing garbles.

Connection-warm caches (per-process, generation-guarded by db
ino/size/mtime, write-through, flushed on mismatch):
  - 16-slot LRU page cache (64KB): repeated reads serve from RAM.
    Full-scan loops (scan_max, search) probe but never fill, so scans
    cannot evict the hot set. Journal pre-images bypass the cache.
  - Open-state skip: unchanged DBs skip ensure_tables/scan_max walks;
    roots/maxrowid/taskseq are already live (writes maintain them).
  Measured (ZFS, persistent connection): 100 hot reads 200.4ms ->
  1.4ms (~140x, fsync removal + cache); pread count on a
  read+read+search mix 37 -> 9 (~4x). Cold single-shot and write
  throughput unchanged (writes stay fsync-bound by design).

Learning: usage-ranked search_nodes over a 262,144-slot hot table
(USLOT_BITS/MASK/SZ are the single growth point). Stable identity:
facts/entities/tasks hash their machine name (FNV-1a-64, low 56 bits;
observations use immutable rowids); a second 32-bit hash makes 88-bit
identity, so collisions resolve to separate slots via probing instead
of merging, and the persistent table keeps original names for audit.
Per-slot signals (all saturating): access reads, useful/misleading
explicit feedback, recency tick, confidence from repeat versions.
Score (u64, overflow-impossible by clamped inputs, floored at zero):
gated access + 8*useful + 2*confidence + recency(1024-tick window)
- 8*misleading, where popularity counts only when useful >=
misleading. Searches collect up to 64 hits, stable-sort by score
descending. feedback {name,signal} teaches (durable on return);
explain_rank {name} shows signals, score, and weights, so benchmarks
verify learning rather than observing order.

Persistence: learned signals live in shape-versioned `usage` rows
(legacy 2-col plus v2 8-col side by side; readers key off actual
column count, schemas never rewritten). Legacy rowid keys resolve to
names via rowid->name scans (private buffers; unresolvable rows are
skipped, never merged). Hot slots hold hashes only, so a pending-name
queue records (slot,name) at slot-create and flush drains it; flush
re-verifies each entry by rehash before writing (evicted slots skip).
Rowids come from a txn-fresh [maxrowid] (++ per row; concurrent writers
are locked out), never from per-write full-table scans: a rightmost-
descent tail_max() sizes new rows in O(depth), keeping flush O(1)
amortized (262,144-row fill in seconds, not hours). The invariant is
stronger than the lock: EVERY new rowid in every table derives from a
maximum read back from disk after the write lock is held (tail_max per
append path; max-tracking inside walks that already run, e.g. the
conclusions duplicate check; the usage flush re-syncs on entry, keeps
its high-water mark on success instead of restoring the pre-flush
value, and re-syncs on abort since placed rows persist with the outer
txn). A shared in-memory counter alone is unsound across processes and
across tables — it once issued duplicate/out-of-order usage rowids
(and stale conclusions ids under concurrency). Verified with
barrier-synced concurrent writers: zero duplicate or out-of-order
rowids in all 8 tables, integrity_check clean throughout, and every
MCP op returns success (feedbacks included: use_flush returning the
counter instead of 0 once broke them visibly).
At capacity the
table degrades gracefully via min-score eviction (proven: 239,911 live
slots + 22,233 evictions over a 262,144 fill, zero false hits).
Saved on clean process exit and piggybacked onto write-txn commits;
loaded once per process at first open, tick resuming past persisted
recency. Verified: useful beats 300x-popular-plus-misleading after
restart; live-DB migration restores exact legacy counts.

Value cap: no single TEXT value over 1024 bytes (fact bodies included).
Max cell ~1.2KB < page/3, so both split halves always fit; oversize
cells are refused ("too large"), never written.

Security posture (see TT-01..TT-05 review cycle):
- TT-01 file privacy: the database is created 0600 and any existing
  database is fchmod'd to 0600 and ownership-checked (must be ours)
  on every open; violators fail the whole operation closed.
- TT-02 argument integrity: JSON keys resolve by structural scope
  (top-level vs immediate-object, string/escape/brace aware), and any
  duplicate key within one object rejects the whole request. Nested
  decoys and key-like string contents can no longer override arguments.
  The parser is still intentionally narrow (documented key order,
  bounded sizes) and must not face untrusted clients directly.
- TT-03 crash consistency: header (size/counter/taskseq) is written
  last, page counts come from the header (never beyond the file), and
  tree walks refuse out-of-range pages. Every overwrite journals its
  pre-image ([pgno][page] + fsync) under flock; open rolls back torn
  txns (restore + truncate to orig size) and close commits (fsync db,
  unlink/ truncate journal, dirsync). Verified by SIGKILL +
  integrity_check, torn-tail + growth-truncate recovery tests.
- TT-04 hardening: ET_DYN (PIE, ASLR slides verified) + PT_GNU_STACK
  with no exec permission + separated R E / RW segments. No W+X.
- TT-05 conformance: every tools/call result uses the MCP content
  envelope (verified per tool).

x86-64-v3 use (explicit 32B lanes, unaligned ops, scalar tails,
vzeroupper hygiene; VEC_ZERO128 macro): 4K page zeroing, ascii
validation bulk lanes, JSON-escape clean-block copies, substring
first-byte filters. Deliberately scalar: JSON parser, b-tree splits,
thought recording (pointer-chasing/varints/branches; SIMD-hostile).

Measured on i9-13900K, pinned core, interleaved rounds, medians
(v3 vs scalar reference, same workload):
  search full-scan miss, 2k obs:  0.072ms vs 0.097ms  (~1.35x)
  search hit, 2k obs:             0.091ms vs 0.110ms  (~1.2x)
  thought record:                 parity (scalar path, as expected)
  write 1K (fsync-dominated):     parity
  read 1K clean / escape-dense:   parity / ~0.87x (fast path never
                                  triggers on adversarial input; typical
                                  text is clean and neutral-or-better)
Behavioural identity v3 vs scalar verified by differential suites.

Model tools (on-board trainable MLP, 2->H->1, H 1..16, FP32):
model_init {hidden?, seed?, activation? leaky|linear} (He init,
bias 0.1, velocities zeroed); model_train {xs,ys,targets,lr,steps}
(full-batch SGD+momentum 0.9, batch <= 128, MSE loss, magnitude guard
|v| <= 1e6); model_predict {xs,ys}; model_save/model_load {path?}
(PBMD v2: 64B header magic/version/arch/count/H/step/payload-bytes/
table+payload FNV-64 hashes/activation, 8-entry region table, region
payloads; tmp sibling + fsync + atomic rename + dirsync; two-pass load
(stream-verifies table + every region crc + cumulative hash before
touching live state, then resets the arena and stages — bad files are
rejected with the live model intact, and load works in a live process,
not just a fresh one); model_status
(initialized/hidden/step/loss/allocated+mincore-committed/backend/gpu).
Paths [A-Za-z0-9._/-]{1,256}, no "..", default peabrain.pbmd. Math:
handwritten AVX2/FMA matmul + scalar reference (USE_SCALAR selects;
 differential suites assert identity); leaky-ReLU 0.01; LCG-seeded.
Arena: 4GiB mmap NORESERVE bump allocator, page-aligned, 8 regions max.
Validated: linear-map loss -> ~1e-5, in-domain unseen error < 0.05,
save file exactly 840B (64+256+520), reload predictions identical,
training resumes from checkpoint step. GPU unavailable by review (no
libcuda; CPU reference is the supported backend). model/ holds the
stage prototypes (arena/matmul/mlp/quant) and the MODEL verdict note.

Continual-learning ranker (shadow mode, deterministic order authoritative)
--------------------------------------------------------------------------
  Retrieval snapshots per search hit (kind/key/h2/x0/x1/det-score/tick,
  256-entry ring): x0 = clamp(pos-neg,-8,8)/8, x1 = .5*recency +
  .25*access/32 + .25*conf/64 from live usage counters. Explicit
  useful/misleading feedback joins the newest fresh (<4096 ticks) snapshot;
  misses counted (no_snapshot/stale/tombstone/invalid). Training consumes
  ONLY snapshot-time features — counters are never re-read after feedback.
  Examples persist in append-only rankex table
  (name,kind,seq,x0,x1,target,det,rev; x0/x1 as f32-bit decimals; cap 4096,
  then store_full rejects), independent of PBMD. Bounded incremental train
  piggybacks feedback: newest-first window skipping held-out, batch <= 128,
  H=4 leaky fixed, lr 0.05, 5 steps, momentum path reused; weights
  auto-saved to rank.pbmd (best effort) and auto-loaded at boot/on demand.
  Ownership safeguard: any successful model_init/model_load sets rank_owned;
  rank automation (init/load/train/save/infer) then goes dormant with
  model_owned rejects — a user model is never overwritten. Rank weights
  live only in rank.pbmd, never peabrain.pbmd. Held-out is identity-grouped
  (((key>>4)+(h2>>4)+kind)%10==0; obs via ukey_rowid; same memory always
  one side; held never trained). model_status gains additive
  rank{owner,examples,heldout,revision,rejected[6],lift} where lift =
  held-out pairwise concordance (neural minus deterministic); explain_rank
  gains additive neural shadow score (null when no ranker model). 27-tool
  contracts otherwise unchanged (status/explain additive fields only).
  No reorder until lift demonstrates improvement: measured lift on 40
  mixed examples is negative, so deterministic ranking stays authoritative.
  Live DB untouched by development (scratch-only under /scratch/tmp);
  first boot with this binary creates the empty rankex table (one page).

Canonical state directory (PEABRAIN_STATE_DIR, else ~/.local/share/peabrain)
------------------------------------------------------------------------------
  Replaces historical executable-relative database resolution (readlink
  /proc/self/exe with CWD fallback), which silently split state across
  launch directories: the DB followed the exe/CWD while rank.pbmd followed
  the CWD, producing divergent weight lineages (repo step 10 vs live
  step 120) and forked empty stores.
  Contract: explicit PEABRAIN_STATE_DIR wins, else ~/.local/share/peabrain;
  tinythink.db + rank.pbmd resolve from the same dir; dirs 0700, files
  0600 (db open already enforces 0600+owner; creations use 0600+fchmod).
  Explicit user-model paths (model_save/load {path}) stay CWD-relative.
  Fresh-install guard: populated legacy store (exe-dir or CWD, any size>0)
  + empty canonical => loud refusal naming both paths (never silent fork);
  nothing anywhere => create fresh. Missing/inaccessible configured state
  fails clearly (exit 1 + reason); never falls back, never fabricates.
  Independent stores via separate explicit overrides (verified isolated).
  Test harnesses must export PEABRAIN_STATE_DIR per workdir.
  Verified: fresh/default/refuse/denied/explicit-path/isolation/retrain/
  perms/CWD-ignored battery green; full suites green via override.
  Migration (separate approval): quiesce writers, snapshot (cp -p, record
  fingerprints, require no journal or recover first), copy (never move)
  db + authoritative weights to canonical, archive (never delete) legacy
  files, boot-verify (usage_tracked, examples, step, predictions, restart
  training), then repoint. Rollback: restore archives + prior exe.

Per-query tombstone snapshot (branch feat/tomb-index, unmerged)
------------------------------------------------------------------------------
  search_table st_hit + op_flist ofl called is_tombstoned per hit (full
  210-page/11K-row tomb walk + childtab spill/restore + page re-read each);
  the 16-slot page cache cannot hold the facts+tomb working sets, so every
  hit re-read from disk with zero cross-query amortization (probe/lim20:
  0.93s warm, 1.3M pread64).
  Fix: tix_build snapshots tombstones once per read query after db_open
  (same SH hold as the walks) into a 32768-slot open-address table (FNV-1a,
  full key compare; 512KB) + 1MB name pool; cell rules mirror
  scan_key_latest (TEXT-only col0; len>128 skipped as provably unmatchable).
  ANY anomaly or capacity overflow (>24576 entries / pool full) abandons the
  build and the legacy path runs (bit-identical fallback, never wrong).
  tix_lookup is a pure predicate: no pagebuf/childtab clobber, so the spill/
  restore + restore-pread are skipped on the index path. Read-ops only
  (search, flist); never in tomb-writing loops. +1.5MB BSS (~+0.85MB RSS).
  Measured (scratch copies): probe 0.975s->0.014s (70x), syscalls
  1,304,553->6,253 (209x); hitless queries +1..5ms (build cost, no regression
  risk). Oracle: 16/16 byte-identical vs shipped binary; 500/500 names vs
  stock SQLite ground truth; corrupt-page and 25K-tomb overflow both agree
  with legacy byte-for-byte (incl. a pre-existing legacy OOB crash on garbage
  ncell, out of scope). Suites green AVX2+scalar with PEABRAIN_STATE_DIR
  isolation (memtest/advtest/thinktest/conctest/mdtest2, state battery).
  Lesson: stale-era harnesses that assume exe-relative stores MUST export
  PEABRAIN_STATE_DIR, else they write to live canonical (one such incident
  occurred during verification; repaired: test rows deleted, step-120 weights
  restored from pristine copy, integrity ok, full disclosure in checkpoint).

Timing instrumentation (opt-in: PEABRAIN_TIMING=1 in environ, branch only)
--------------------------------------------------------------------------
  CLOCK_MONOTONIC via clock_gettime; diagnostics to stderr (fd 2) with
  PB/READY/BOOT/FB prefixes; stdout stays pure MCP JSON-RPC. Disabled =
  one cmp+branch per hook (suites green, wall-identical). Enabled lines:
  READY (spawn->first-read ms), PB pid/op/idle/serve/lock/fsync ms per
  response (op name mirrored from dispatch, incl. error paths), BOOT
  (firstop/ensure/useload/rankboot/rindex_ok/user/sys ms via getrusage),
  FB (feedback persist/train/save ms split). flock/fsync sites wrapped as
  tm_flock/tm_fsync (per-op lock/fsync totals; unlock paths untouched).
  Same PID across PB lines proves a persistent server; one READY+BOOT per
  process, so N of them across N calls proves per-call spawning. BOOT is
  deferred until the first database initialisation completes (tm_dbready):
  protocol-only sessions (initialize/list/ping) emit READY+PB only, never
  misleading zero-valued database metrics; rindex_ok therefore reports the
  true index state.
  Measured (live-shaped 19,896-row copy): full 6-op learning sequence
  14.5s wall, ~14s of it first-op use_load (user ~2s, sys ~12s); steady
  ops: write ~9ms (fsync ~7), search ~6ms, feedback ~13-15ms
  (persist 3-5/train 9-10/save 3-4), status ~0ms. strace: 14.7M pread64
  per boot. Root cause: ~10K legacy 2-col usage rows each trigger
  rname_of = full facts/entities scan via pg_read_nc (probe+pread, never
  fills cache) at every boot; in-memory utab is rebuilt per process by
  design, so warm boots cost the same.

Reverse-identity index for legacy usage rows (boot, read-only)
----------------------------------------------------------------
  One pass over facts+entities at boot maps rowid -> (arena off, len);
  the legacy branch does O(1) lookup converging on the shared ull_named
  merge (identical hashing/collisions/scores). Extraction mirrors rname_of
  exactly (parse-ok, col0, len 1..128, no gcols check). All-or-nothing
  with explicit caps (rowid < 65536 via tail_max precheck; 2MB name
  arena): any miss aborts to the original resolver, so valid records are
  never silently skipped. Zero DB writes, format untouched. Layout is
  cache-dense: sequential build, 8B entries, ~256KB hot set (L2-resident);
  training batches (<=1KB + H=4 weights) stay L1-resident.
  Measured on live-shaped copy: useload 13,799ms -> 15ms, preads
  15,792,337 -> 3,566 (4,428x), user 1,955ms -> 2ms, sys 11,805ms -> 13ms,
  RSS 8.15MB -> 9.48MB (+1.33MB), file +4.6KB (rest NOBITS).
  Verified: 32,625 explain_rank byte-identical, tracked counts and search
  corpora identical, 7 malformed + sparse-60000 (rindex 1) + fallback-70000
  (rindex 0, legacy path) identical, full db/model/learning/concurrency
  suites green on both backends. BOOT line gains additive rindex_ok.
  Requires fasm -m 65536 (BSS outgrew the default 16MB assembler limit).
Search-truncation fix (nested walk clobbers outer walk state)
---------------------------------------------------------------
  Pathology (pre-existing since v1.0.0): is_tombstoned -> scan_key_latest
  -> walk_leaves overwrote the outer search walk's childtab/childn with
  tomb-table leaves. Every tomb-checked hit (visible or correctly skipped)
  derailed the rest of that table's scan into tomb pages: late matches
  silently missing (proven: six tombstoned deploy-probe-N rows hid a live
  probe; traced scan covered ~515 pages of 1,192 facts leaves), plus ~200
  wasted page reads per hit. Small DBs dodge it (single-page tables).
  Fix: spill childtab/childn to chsave around the check (mirror rname_of's
  sequential-use pattern), single restore site preserving rax. Audited all
  17 walk_leaves sites + 12 is_tombstoned sites: exactly one proven defect
  (op_flist accidentally safe via descending order + tomb self-skips +
  caps; op_open/collect_prefix/query/insert paths hold no live walk;
  use_load/rname_of already guarded). Tomb walk never touches gfo/gfl/
  gcols/stab (manual parse into tmprow); growid overwritten only on match,
  which always skips. Cost: ~9KB memcpy per hit; multi-match search +1.0s
  for a COMPLETE scan (old: instant but truncated to 1 row) on live-shaped
  data.   Verified: placement matrix (old hides all 12, new finds all 12),
  7 malformed + sparse + fallback identical, 32,625-explain sweep on
  tomb-free data identical, full suites green both backends.

Shared recency tick per search emission (ranking-semantics correction)
-----------------------------------------------------------------------
  Pathology: every surfaced hit took its own utick during emit, so each
  search inverted the recency gradient for the next one — repeated
  identical searches oscillated (19..00, 00..19, 19..00, ...), and a
  promoted row could not hold its position.
  Fix: op_search stamps one query tick (ulqtick = ++utick) served to every
  use_bump_name/id in its emission (tick passed in rcx, 0 = advance the
  clock as before); access accounting untouched; feedback/confidence paths
  keep individual ticks. Single-row reads (op_fread) pass 0 = auto.
  Verified: repeats 2+ identical, feedback promotes and holds, tombstoned
  absent, rest intact, order survives restart; old binary fails exactly
  the stability checks. First searches agree byte-for-byte with old code
  (genuine write-recency/feedback signals rank identically; 6/6 runs).
  One unreproduced outlier (old disagreed with itself once) on record.
  search_nodes schema now documents limit 1..20 (runtime unchanged).


Smoke test
----------
  printf '%s\n' \
    '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"sequential_thinking","arguments":{"thought":"hi","nextThoughtNeeded":false,"thoughtNumber":1,"totalThoughts":1}}}' \
  | ./tinythink
  printf '%s\n' \
    '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"write_fact","arguments":{"name":"sky","text":"blue"}}}' \
  | ./tinythink
  sqlite3 tinythink.db "select name,body from facts; pragma integrity_check;"
