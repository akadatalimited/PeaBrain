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
  fasm tinythink.asm tinythink            # v3 baseline binary
  fasm -dUSE_SCALAR=1 tinythink.asm tinythink-scalar   # scalar A/B reference

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

Smoke test
----------
  printf '%s\n' \
    '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"sequential_thinking","arguments":{"thought":"hi","nextThoughtNeeded":false,"thoughtNumber":1,"totalThoughts":1}}}' \
  | ./tinythink
  printf '%s\n' \
    '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"write_fact","arguments":{"name":"sky","text":"blue"}}}' \
  | ./tinythink
  sqlite3 tinythink.db "select name,body from facts; pragma integrity_check;"
