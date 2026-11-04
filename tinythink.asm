; think.asm - ultra tiny sequential-thinking MCP server, FASM ELF64, no libc.
;
; Mimics @modelcontextprotocol/server-sequential-thinking, plus a conclusion
; tool backed by a real SQLite database written in pure asm (no includes).
; Transport: newline-delimited JSON-RPC 2.0 on stdin/stdout (MCP stdio).
; Serves both eras: 2026-07-28 clients (server/discover, no handshake) and
; 2025-era clients (initialize). Thought history lives in RAM for as long as
; the client's connection (one process = one connection).
; Methods: initialize, server/discover, ping, tools/list, tools/call.
; No-id => notification, no reply.
; Tool sequential_thinking: required thought(string 1..2048),
;   nextThoughtNeeded(bool), thoughtNumber(int), totalThoughts(int);
;   optional isRevision(bool), revisesThought(int), branchFromThought(int),
;   branchId(string 0..40), needsMoreThoughts(bool). Ring: 64 thoughts.
; Tool conclusion: {reason, thought?, conclusion?, valid?} against
;   tinythink.db (created on first use, beside the executable):
;   conclusions(reason TEXT, thought TEXT, conclusion TEXT, valid INTEGER).
;   reason 1..64 ascii; thought 0..512 ascii; conclusion 1..512 ascii.
;   conclusion present -> insert (dup reason refused); else valid present ->
;   set valid flag (invalidate/revalidate); else read row by reason.
; Value cap everywhere: no single TEXT value over 1024 bytes (fact bodies
; included). Max cell ~1.2KB < page/3, so both split halves always fit;
; oversize cells are refused, never written (no overflow pages by design).
; SQLite subset (genuine file format, opens in real sqlite3):
;   page size 4096, UTF-8, single table + sqlite_master, rowid leaf pages,
;   size-ordered leaf splits, root interior once split, whole-db flock,
;   fsync per write txn. Limits: cell <= ~1100B, interior never splits
;   (~600 leaves, thousands of conclusions), no overflow pages, no journal.
; Assumes standard key order (method/id before params, name before arguments).
;
; BASELINE: x86-64-v3. The binary freely uses AVX/AVX2/FMA/BMI1/BMI2/LZCNT.
; FASM emits no runtime compatibility check, so start: runs a CPUID gate
; first (stderr + exit 1 on older CPUs). Scalar paths remain for tails and
; for branchy/pointer-chasing work where SIMD does not pay (JSON parser,
; b-tree splits, thought recording). Vectorized: 4K page zeroing, ascii
; validation bulk lanes, JSON-escape clean-block copies, substring
; first-byte filters. Build the scalar A/B reference with:
;   fasm -dUSE_SCALAR=1 tinythink.asm tinythink-scalar

format ELF64 dynamic 3
entry start

; ---- x86-64-v3 macro discipline ----
; Explicit 32B lanes (pack width in the name), unaligned (U) memory ops
; (our buffers carry no alignment guarantee), scalar tails. YMM0-YMM7 are
; scratch inside vector routines (never carry cross-call state); each
; vector routine ends with vzeroupper. Scalar reference builds select the
; scalar path with: fasm -dUSE_SCALAR=1 tinythink.asm tinythink-scalar
macro VEC_ZERO128 base* {
    vmovdqu [base + 0], ymm0
    vmovdqu [base + 32], ymm0
    vmovdqu [base + 64], ymm0
    vmovdqu [base + 96], ymm0
}
; callers zero ymm0 first: vpxor ymm0, ymm0, ymm0

segment readable executable

start:
    ; x86-64-v3 baseline gate (FASM emits none; without this the first
    ; v3-only instruction would die with SIGILL and no explanation).
    mov eax, 1
    cpuid                         ; ECX: FMA(12) MOVBE(22) OSXSAVE(27) AVX(28)
    mov eax, ecx
    and eax, 0x18401000
    cmp eax, 0x18401000
    jne v3_fail
    xor ecx, ecx
    xgetbv                        ; XCR0: XMM(1) + YMM(2) state enabled?
    and eax, 6
    cmp eax, 6
    jne v3_fail
    mov eax, 7
    xor ecx, ecx
    cpuid                         ; EBX: BMI1(3) AVX2(5) BMI2(8)
    mov eax, ebx
    and eax, 0x128
    cmp eax, 0x128
    jne v3_fail
    mov eax, 0x80000001
    cpuid                         ; ECX: LZCNT(5)
    test ecx, 0x20
    jz v3_fail
    jmp v3_ok
v3_fail:
    mov eax, 1
    mov edi, 2
    lea rsi, [v3msg]
    mov edx, v3msg_len
    syscall
    mov eax, 60
    mov edi, 1
    syscall
v3_ok:
    cld
    lea rax, [outbuf]
    mov [outptr], rax

read_loop:
    mov eax, 0                ; read(stdin, inbuf, 4096)
    xor edi, edi
    lea rsi, [inbuf]
    mov edx, 4096
    syscall
    cmp rax, 0
    jg have_input
    cmp qword [linelen], 0    ; EOF: flush partial line, then exit 0
    je quit0
    lea rsi, [line]
    mov rdx, [linelen]
    mov qword [linelen], 0
    call handle_line
quit0:
    call use_flush_exit         ; persist learned prefs on clean shutdown
    mov eax, 60
    xor edi, edi
    syscall

have_input:
    mov rbx, rax              ; n bytes
    lea r12, [inbuf]
    xor r13d, r13d
byte_loop:
    cmp r13, rbx
    jae read_loop
    mov al, [r12 + r13]
    inc r13
    cmp byte [discard], 1
    je in_discard
    cmp al, 10
    je end_of_line
    mov rcx, [linelen]
    cmp rcx, 8191
    jae line_overflow
    lea rdi, [line]
    mov [rdi + rcx], al
    inc qword [linelen]
    jmp byte_loop
in_discard:
    cmp al, 10
    jne byte_loop
    mov byte [discard], 0
    call err_line_too_long
    jmp byte_loop
end_of_line:
    lea rsi, [line]
    mov rdx, [linelen]
    mov qword [linelen], 0
    call handle_line
    jmp byte_loop
line_overflow:
    mov byte [discard], 1
    jmp byte_loop

; ---------------- output helpers (rax,rcx,rdx,rsi,rdi only) ----------------
out_reset:
    mov qword [outlen], 0
    ret

; out_bytes(rsi=ptr, rdx=len) -> [outptr]+[outlen]
out_bytes:
    test rdx, rdx
    jz ob_ret
    mov rcx, rdx
    mov rax, [outlen]
    mov rdi, [outptr]
    add rdi, rax
    add rax, rcx
    mov [outlen], rax
    rep movsb
ob_ret:
    ret

; out_cstr(rsi)
out_cstr:
    push rsi
    xor ecx, ecx
oc_len:
    cmp byte [rsi + rcx], 0
    je oc_go
    inc rcx
    jmp oc_len
oc_go:
    mov rdx, rcx
    pop rsi
    jmp out_bytes

; out_byte(al) -> [outptr]+[outlen]
out_byte:
    mov rcx, [outlen]
    mov rdi, [outptr]
    mov [rdi + rcx], al
    inc qword [outlen]
    ret

; out_uint(rax=signed value)
out_uint:
    push rbx
    push r8
    lea rdi, [numtmp + 32]
    mov rbx, rdi              ; rbx = end
    xor r8d, r8d              ; neg flag
    test rax, rax
    jns ou_conv
    neg rax
    js ou_min                 ; INT64_MIN edge
    mov r8d, 1
    jmp ou_conv
ou_min:
    mov rax, 0x7FFFFFFFFFFFFFFF
    mov r8d, 1
ou_conv:
    mov rcx, 10
ou_loop:
    xor edx, edx
    div rcx
    add dl, '0'
    dec rdi
    mov [rdi], dl
    test rax, rax
    jnz ou_loop
    test r8d, r8d
    jz ou_emit
    dec rdi
    mov byte [rdi], '-'
ou_emit:
    mov rsi, rdi
    mov rdx, rbx
    sub rdx, rdi
    pop r8
    pop rbx
    jmp out_bytes

; out_escaped(rsi=ptr, rdx=len). v3: 32B clean-block copies (no byte
; needing JSON escape in the lane) + scalar body/tail. Scalar build: body only.
out_escaped:
    test rdx, rdx
    jz oe_ret
    push rbx
    mov rbx, rsi
    add rdx, rsi
if defined USE_SCALAR
    jmp oe_loop
else
    vpxor ymm0, ymm0, ymm0
    vpbroadcastb ymm4, [c34]
    vpbroadcastb ymm5, [c92]
    vpbroadcastb ymm6, [c31]
    vpbroadcastb ymm7, [c127]
oe_blk:
    mov rax, rdx
    sub rax, rbx
    cmp rax, 32
    jb oe_loop
    vmovdqu ymm1, [rbx]
    vpcmpeqb ymm2, ymm1, ymm4    ; '"'
    vpmovmskb eax, ymm2
    mov r8d, eax
    vpcmpeqb ymm2, ymm1, ymm5    ; '\'
    vpmovmskb eax, ymm2
    or r8d, eax
    vpcmpgtb ymm2, ymm1, ymm6    ; > 31?
    vpmovmskb eax, ymm2
    not eax                     ; <= 31 (incl. >= 128 signed-negative)
    or r8d, eax
    vpcmpeqb ymm2, ymm1, ymm7    ; == 127?
    vpmovmskb eax, ymm2
    or r8d, eax
    test r8d, r8d
    jnz oe_loop                 ; lane needs escapes: one scalar byte
    vmovdqu ymm2, [rbx]
    mov rcx, [outlen]
    mov rdi, [outptr]
    add rdi, rcx
    vmovdqu [rdi], ymm2
    add qword [outlen], 32
    add rbx, 32
    jmp oe_blk
end if
oe_loop:
    cmp rbx, rdx
    jae oe_done
    mov al, [rbx]
    inc rbx
    cmp al, '"'
    jne oe_nq
    mov al, '\'
    call out_byte
    mov al, '"'
    call out_byte
    jmp oe_loop
oe_nq:
    cmp al, '\'
    jne oe_nbs
    mov al, '\'
    call out_byte
    mov al, '\'
    call out_byte
    jmp oe_loop
oe_nbs:
    cmp al, 10
    jne oe_nlf
    mov al, '\'
    call out_byte
    mov al, 'n'
    call out_byte
    jmp oe_loop
oe_nlf:
    cmp al, 13
    jne oe_ncr
    mov al, '\'
    call out_byte
    mov al, 'r'
    call out_byte
    jmp oe_loop
oe_ncr:
    cmp al, 9
    jne oe_ntab
    mov al, '\'
    call out_byte
    mov al, 't'
    call out_byte
    jmp oe_loop
oe_ntab:
    cmp al, 32
    jb oe_uni
    cmp al, 126
    jbe oe_raw
oe_uni:
    push rax
    mov al, '\'
    call out_byte
    mov al, 'u'
    call out_byte
    mov al, '0'
    call out_byte
    mov al, '0'
    call out_byte
    pop rax
    push rax
    shr al, 4
    call out_hex
    pop rax
    and al, 15
    call out_hex
    jmp oe_loop
oe_raw:
    call out_byte
    jmp oe_loop
oe_done:
    pop rbx
if defined USE_SCALAR
else
    vzeroupper
end if
oe_ret:
    ret

out_hex:
    cmp al, 9
    jbe oh_d
    add al, 'a' - 10
    jmp out_byte
oh_d:
    add al, '0'
    jmp out_byte

; write_all(rdi=fd, rsi=buf, rdx=len): rax=0 ok, 1 err.
write_all:
    test rdx, rdx
    jz wa_ok
wa_loop:
    push rdi
    push rsi
    push rdx
    mov eax, 1
    syscall
    pop rdx
    pop rsi
    pop rdi
    cmp rax, 0
    jle wa_bad
    add rsi, rax
    sub rdx, rax
    test rdx, rdx
    jnz wa_loop
wa_ok:
    xor eax, eax
    ret
wa_bad:
    mov eax, 1
    ret

emit:
    mov edi, 1                ; looped write: big history output may partial-write
    lea rsi, [outbuf]
    mov rdx, [outlen]
    jmp write_all

; ---------------- parsers ----------------
; find_val(rsi=start, rdi=key, rcx=keylen): rax=ptr after colon+ws, 0=no.
; reject_dups: structural walk of [lp]..[le]. Records (openoff,keyptr,keylen)
; for every "key": pattern (string-aware, escape-aware). Same (object,key)
; twice, or structural malformation, is rejected.
; rax 0 clean / 1 duplicate key / 2 malformed. Preserves rbx,rbp,r12-r15.
reject_dups:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov r12, [lp]                 ; cur
    mov rbx, [le]                 ; end
    xor r15d, r15d                ; depth
    xor r14d, r14d                ; key count
rd_loop:
    cmp r12, rbx
    jae rd_end
    mov al, [r12]
    cmp al, '{'
    je rd_open
    cmp al, '['
    je rd_open
    cmp al, '}'
    je rd_close
    cmp al, ']'
    je rd_close
    cmp al, '"'
    je rd_str
    inc r12
    jmp rd_loop
rd_open:
    cmp r15, 16
    jae rd_malformed
    lea rax, [sob]
    mov rcx, r15
    shl rcx, 3
    add rax, rcx
    mov [rax], r12                ; sob[depth] = brace offset
    inc r15
    inc r12
    jmp rd_loop
rd_close:
    test r15, r15
    jz rd_malformed
    dec r15
    inc r12
    jmp rd_loop
rd_str:
    mov rsi, r12
    inc rsi
rd_sq:
    cmp rsi, rbx
    jae rd_malformed              ; unterminated string
    mov al, [rsi]
    cmp al, '\'
    je rd_sesc
    cmp al, '"'
    je rd_send
    inc rsi
    jmp rd_sq
rd_sesc:
    inc rsi
    cmp rsi, rbx
    jae rd_malformed
    inc rsi
    jmp rd_sq
rd_send:
    ; key iff depth>=1 and optional ws + ':' follows
    test r15, r15
    jz rd_after
    mov rax, rsi
    inc rax
rd_sw:
    cmp rax, rbx
    jae rd_after
    mov cl, [rax]
    cmp cl, ' '
    je rd_swa
    cmp cl, 9
    je rd_swa
    cmp cl, 13
    je rd_swa
    cmp cl, 10
    je rd_swa
    cmp cl, ':'
    jne rd_after
    ; record (sob[depth-1], keyptr=r12+1, keylen=rsi-r12-1)
    cmp r14, 32
    jae rd_malformed
    lea rax, [sob]
    mov rcx, r15
    dec rcx
    shl rcx, 3
    add rax, rcx
    mov rcx, [rax]                ; openoff
    lea rax, [ktab]
    mov rdx, r14
    imul rdx, rdx, 24
    add rax, rdx
    mov [rax], rcx                ; +0 openoff
    lea rcx, [r12 + 1]
    mov [rax + 8], rcx            ; +8 keyptr
    mov rcx, rsi
    sub rcx, r12
    dec rcx                       ; keylen
    mov [rax + 16], rcx           ; +16 keylen
    ; pairwise dup check vs previous entries (r10=openoff, r11=keylen)
    mov r10, [rax]
    mov r11, [rax + 16]
    xor ecx, ecx
rd_dup:
    cmp rcx, r14
    jae rd_dupdone
    lea rax, [ktab]
    mov rdx, rcx
    imul rdx, rdx, 24
    add rax, rdx
    mov rdx, [rax]
    cmp rdx, r10
    jne rd_dupnext
    mov rdx, [rax + 16]
    cmp rdx, r11
    jne rd_dupnext
    push rcx
    push rsi
    push rdi
    mov rsi, [rax + 8]
    lea rdi, [r12 + 1]
    mov rcx, r11
    rep cmpsb
    pop rdi
    pop rsi
    pop rcx
    je rd_dupfound
rd_dupnext:
    inc rcx
    jmp rd_dup
rd_dupdone:
    inc r14
    jmp rd_after
rd_dupfound:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    mov eax, 1
    ret
rd_swa:
    inc rax
    jmp rd_sw
rd_after:
    mov r12, rsi
    inc r12
    jmp rd_loop
rd_end:
    test r15, r15                 ; balanced?
    jnz rd_malformed
    xor eax, eax
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret
rd_malformed:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    mov eax, 2
    ret

; find_val(rsi=start, rdi=key, rcx=keylen): rax = value ptr after colon+ws,
; 0 = none. Keys include both quotes (e.g. '"thought"').
; Scope contract (TT-02): start==[lp] matches top-level keys only (depth 1);
; otherwise start must be '{' and only its immediate children match.
; Brace depth plus string/escape tracking: nested decoys and key-like text
; inside strings never match. Same-object duplicates are rejected up front
; by reject_dups, so first-in-scope is the only in-scope match.
find_val:
    push rbx
    push r10
    push r12
    push r13
    push r14
    push r15
    cmp rsi, [lp]
    je fv_top
    ; scoped object scan
    mov r10, [le]
    cmp rsi, r10
    jae fv_no
    cmp byte [rsi], '{'
    jne fv_no
    mov r12, rsi
    inc r12                       ; enter object
    mov r13, rdi                  ; key
    mov r14, rcx                  ; keylen
    mov rbx, 1                    ; reldepth: 1 = immediate children
    jmp fv_sloop
fv_sloop:
    cmp r12, r10
    jae fv_no
    mov al, [r12]
    cmp al, '{'
    je fv_sopen
    cmp al, '['
    je fv_sopen
    cmp al, '}'
    je fv_sclose
    cmp al, ']'
    je fv_sclose
    cmp al, '"'
    je fv_sstr
    inc r12
    jmp fv_sloop
fv_sopen:
    inc rbx
    inc r12
    jmp fv_sloop
fv_sclose:
    dec rbx
    jz fv_no                      ; back to 0: end of our object
    inc r12
    jmp fv_sloop
fv_sstr:
    ; string end -> r9 (escape-aware)
    mov r9, r12
    inc r9
fv_sq:
    cmp r9, r10
    jae fv_no
    mov al, [r9]
    cmp al, '\'
    je fv_sesc
    cmp al, '"'
    je fv_send
    inc r9
    jmp fv_sq
fv_sesc:
    inc r9
    cmp r9, r10
    jae fv_no
    inc r9
    jmp fv_sq
fv_send:
    cmp rbx, 1
    jne fv_safter
    ; candidate: full key compare + closing quote is part of key
    mov rax, r10
    sub rax, r12
    cmp rax, r14
    jb fv_no
    mov r8, r12
    push r13
    mov rdi, r13
    mov rsi, r8
    mov rcx, r14
    rep cmpsb
    pop r13
    jne fv_safter2
    ; after key: optional ws, then ':'
    mov r8, r12
    add r8, r14
fv_sws:
    cmp r8, r10
    jae fv_no
    mov al, [r8]
    cmp al, ' '
    je fv_swsn
    cmp al, 9
    je fv_swsn
    cmp al, 13
    je fv_swsn
    cmp al, 10
    je fv_swsn
    cmp al, ':'
    jne fv_safter
    inc r8
fv_sws2:
    cmp r8, r10
    jae fv_no
    mov al, [r8]
    cmp al, ' '
    je fv_sws2n
    cmp al, 9
    je fv_sws2n
    cmp al, 13
    je fv_sws2n
    cmp al, 10
    je fv_sws2n
    mov rax, r8
    pop r15
    pop r14
    pop r13
    pop r12
    pop r10
    pop rbx
    ret
fv_swsn:
    inc r8
    jmp fv_sws
fv_sws2n:
    inc r8
    jmp fv_sws2
fv_safter2:
fv_safter:
    mov r12, r9
    inc r12
    jmp fv_sloop
fv_top:
    ; top-level scan from line start, depth from 0, match at depth 1
    mov r10, [le]
    mov r12, rsi
    mov r13, rdi
    mov r14, rcx
    xor ebx, ebx
fv_tloop:
    cmp r12, r10
    jae fv_no
    mov al, [r12]
    cmp al, '{'
    je fv_topen
    cmp al, '['
    je fv_topen
    cmp al, '}'
    je fv_tclose
    cmp al, ']'
    je fv_tclose
    cmp al, '"'
    je fv_tstr
    inc r12
    jmp fv_tloop
fv_topen:
    inc rbx
    inc r12
    jmp fv_tloop
fv_tclose:
    test rbx, rbx
    jz fv_tnextc
    dec rbx
fv_tnextc:
    inc r12
    jmp fv_tloop
fv_tstr:
    mov r9, r12
    inc r9
fv_tsq:
    cmp r9, r10
    jae fv_no
    mov al, [r9]
    cmp al, '\'
    je fv_tsesc
    cmp al, '"'
    je fv_tsend
    inc r9
    jmp fv_tsq
fv_tsesc:
    inc r9
    cmp r9, r10
    jae fv_no
    inc r9
    jmp fv_tsq
fv_tsend:
    cmp rbx, 1
    jne fv_tafter
    mov rax, r10
    sub rax, r12
    cmp rax, r14
    jb fv_no
    mov r8, r12
    push r13
    mov rdi, r13
    mov rsi, r8
    mov rcx, r14
    rep cmpsb
    pop r13
    jne fv_tafter
    mov r8, r12
    add r8, r14
fv_tws:
    cmp r8, r10
    jae fv_no
    mov al, [r8]
    cmp al, ' '
    je fv_twsn
    cmp al, 9
    je fv_twsn
    cmp al, 13
    je fv_twsn
    cmp al, 10
    je fv_twsn
    cmp al, ':'
    jne fv_tafter
    inc r8
fv_tws2:
    cmp r8, r10
    jae fv_no
    mov al, [r8]
    cmp al, ' '
    je fv_tws2n
    cmp al, 9
    je fv_tws2n
    cmp al, 13
    je fv_tws2n
    cmp al, 10
    je fv_tws2n
    mov rax, r8
    pop r15
    pop r14
    pop r13
    pop r12
    pop r10
    pop rbx
    ret
fv_twsn:
    inc r8
    jmp fv_tws
fv_tws2n:
    inc r8
    jmp fv_tws2
fv_tafter:
    mov r12, r9
    inc r12
    jmp fv_tloop
fv_no:
    xor eax, eax
    pop r15
    pop r14
    pop r13
    pop r12
    pop r10
    pop rbx
    ret

; cmp_name(rsi=buf, rdx=len, rdi=cstr): rax=1 equal.
cmp_name:
    push rsi
    push rdi
    xor eax, eax
cn_len:
    cmp byte [rdi + rax], 0
    je cn_have
    inc rax
    jmp cn_len
cn_have:
    cmp rax, rdx
    jne cn_no
    test rax, rax
    jz cn_no
    mov rcx, rax
    rep cmpsb
    jne cn_no
    mov eax, 1
    pop rdi
    pop rsi
    ret
cn_no:
    xor eax, eax
    pop rdi
    pop rsi
    ret

; parse_str(rsi at '"', rdi=dest, rcx=max): rax=after-quote or 0; rdx=len.
parse_str:
    cmp rsi, [le]
    jae ps_err
    cmp byte [rsi], '"'
    jne ps_err
    inc rsi
    xor edx, edx
ps_loop:
    cmp rsi, [le]
    jae ps_err
    mov al, [rsi]
    inc rsi
    cmp al, '"'
    je ps_done
    cmp al, '\'
    je ps_esc
    cmp rdx, rcx
    jae ps_err
    mov [rdi + rdx], al
    inc rdx
    jmp ps_loop
ps_esc:
    cmp rsi, [le]
    jae ps_err
    mov al, [rsi]
    inc rsi
    cmp al, '"'
    je ps_store
    cmp al, '\'
    je ps_store
    cmp al, '/'
    je ps_store
    cmp al, 'n'
    jne ps_nn
    mov al, 10
    jmp ps_store
ps_nn:
    cmp al, 'r'
    jne ps_nr
    mov al, 13
    jmp ps_store
ps_nr:
    cmp al, 't'
    jne ps_nt
    mov al, 9
    jmp ps_store
ps_nt:
    cmp al, 'b'
    jne ps_nb
    mov al, 8
    jmp ps_store
ps_nb:
    cmp al, 'f'
    jne ps_nf
    mov al, 12
    jmp ps_store
ps_nf:
    cmp al, 'u'
    jne ps_err
    mov rax, [le]
    sub rax, rsi
    cmp rax, 4
    jb ps_err
    cmp byte [rsi], '0'
    jne ps_err
    cmp byte [rsi + 1], '0'
    jne ps_err
    mov r8b, [rsi + 2]
    mov r9b, [rsi + 3]
    cmp r8b, '0'
    jb ps_err
    cmp r8b, '9'
    jbe ps_h1d
    cmp r8b, 'A'
    jb ps_err
    cmp r8b, 'F'
    jbe ps_h1u
    cmp r8b, 'a'
    jb ps_err
    cmp r8b, 'f'
    ja ps_err
    sub r8b, 'a' - 10
    jmp ps_h1x
ps_h1u:
    sub r8b, 'A' - 10
    jmp ps_h1x
ps_h1d:
    sub r8b, '0'
ps_h1x:
    cmp r9b, '0'
    jb ps_err
    cmp r9b, '9'
    jbe ps_h2d
    cmp r9b, 'A'
    jb ps_err
    cmp r9b, 'F'
    jbe ps_h2u
    cmp r9b, 'a'
    jb ps_err
    cmp r9b, 'f'
    ja ps_err
    sub r9b, 'a' - 10
    jmp ps_h2x
ps_h2u:
    sub r9b, 'A' - 10
    jmp ps_h2x
ps_h2d:
    sub r9b, '0'
ps_h2x:
    shl r8b, 4
    or r8b, r9b
    mov al, r8b
    add rsi, 4
    jmp ps_store
ps_store:
    cmp rdx, rcx
    jae ps_err
    mov [rdi + rdx], al
    inc rdx
    jmp ps_loop
ps_done:
    mov rax, rsi
    ret
ps_err:
    xor eax, eax
    ret

; parse_int(rsi=valptr): [numval]=value, rax=0 ok / 1 err.
parse_int:
    cmp rsi, [le]
    jae pi_err
    xor eax, eax              ; sign 0=pos (al), value in rdx
    xor edx, edx
    cmp byte [rsi], '-'
    jne pi_dig
    mov al, 1
    inc rsi
pi_dig:
    cmp rsi, [le]
    jae pi_err
    mov cl, [rsi]
    cmp cl, '0'
    jb pi_end
    cmp cl, '9'
    ja pi_end
    sub cl, '0'
    movzx ecx, cl
    imul rdx, rdx, 10
    add rdx, rcx
    inc rsi
    jmp pi_dig
pi_end:
    ; need >=1 digit and delimiter , } ] ws or end
    cmp rsi, [le]
    ja pi_delim_ok
    mov cl, [rsi]
    cmp cl, ','
    je pi_haved
    cmp cl, '}'
    je pi_haved
    cmp cl, ']'
    je pi_haved
    cmp cl, ' '
    je pi_haved
    cmp cl, 9
    je pi_haved
    cmp cl, 13
    je pi_haved
    cmp cl, 10
    je pi_haved
    jmp pi_err
pi_delim_ok:
pi_haved:
    ; detect zero digits: value 0 with no digits vs literal 0? track via rsi move?
    ; simplest: require last consumed char was digit -> check byte before rsi.
    ; rsi points at delimiter; byte [rsi-1] must be digit.
    mov cl, [rsi - 1]
    cmp cl, '0'
    jb pi_err
    cmp cl, '9'
    ja pi_err
    test al, al
    jz pi_pos
    neg rdx
pi_pos:
    mov [numval], rdx
    xor eax, eax
    ret
pi_err:
    mov eax, 1
    ret

; parse_bool(rsi=valptr): [boolval]=0/1, rax=0 ok / 1 err.
parse_bool:
    cmp rsi, [le]
    jae pb_err
    mov rax, [le]
    sub rax, rsi              ; remaining
    cmp byte [rsi], 't'
    je pb_true
    cmp byte [rsi], 'f'
    je pb_false
    jmp pb_err
pb_true:
    cmp rax, 4
    jb pb_err
    cmp byte [rsi], 't'
    jne pb_err
    cmp byte [rsi + 1], 'r'
    jne pb_err
    cmp byte [rsi + 2], 'u'
    jne pb_err
    cmp byte [rsi + 3], 'e'
    jne pb_err
    mov al, [rsi + 4]
    cmp al, ','
    je pb_tok
    cmp al, '}'
    je pb_tok
    cmp al, ']'
    je pb_tok
    cmp al, ' '
    je pb_tok
    cmp al, 9
    je pb_tok
    cmp al, 13
    je pb_tok
    cmp al, 10
    je pb_tok
    jmp pb_err
pb_tok:
    mov byte [boolval], 1
    xor eax, eax
    ret
pb_false:
    cmp rax, 5
    jb pb_err
    cmp byte [rsi], 'f'
    jne pb_err
    cmp byte [rsi + 1], 'a'
    jne pb_err
    cmp byte [rsi + 2], 'l'
    jne pb_err
    cmp byte [rsi + 3], 's'
    jne pb_err
    cmp byte [rsi + 4], 'e'
    jne pb_err
    mov al, [rsi + 5]
    cmp al, ','
    je pb_fok
    cmp al, '}'
    je pb_fok
    cmp al, ']'
    je pb_fok
    cmp al, ' '
    je pb_fok
    cmp al, 9
    je pb_fok
    cmp al, 13
    je pb_fok
    cmp al, 10
    je pb_fok
    jmp pb_err
pb_fok:
    mov byte [boolval], 0
    xor eax, eax
    ret
pb_err:
    mov eax, 1
    ret

; ---------------- responses ----------------
; send_static(rsi=result cstr) uses parsed id.
send_static:
    push rsi
    call out_reset
    lea rsi, [j1]
    call out_cstr
    lea rsi, [idbuf]
    mov rdx, [idlen]
    call out_bytes
    lea rsi, [jres]
    call out_cstr
    pop rsi
    call out_cstr
    mov al, '}'
    call out_byte
    mov al, 10
    call out_byte
    jmp emit

; err_id(rdi=code cstr, rsi=msg cstr)
err_id:
    push rsi
    push rdi
    call out_reset
    lea rsi, [j1]
    call out_cstr
    lea rsi, [idbuf]
    mov rdx, [idlen]
    call out_bytes
    lea rsi, [jerr1]
    call out_cstr
    pop rsi
    call out_cstr
    lea rsi, [jerr2]
    call out_cstr
    pop rsi
    call out_cstr
    lea rsi, [jerr3]
    call out_cstr
    mov al, '}'
    call out_byte
    mov al, 10
    call out_byte
    jmp emit

; err_null(rdi=code cstr, rsi=msg cstr)
err_null:
    push rsi
    push rdi
    call out_reset
    lea rsi, [j1]
    call out_cstr
    lea rsi, [jnull]
    call out_cstr
    lea rsi, [jerr1]
    call out_cstr
    pop rsi
    call out_cstr
    lea rsi, [jerr2]
    call out_cstr
    pop rsi
    call out_cstr
    lea rsi, [jerr3]
    call out_cstr
    mov al, '}'
    call out_byte
    mov al, 10
    call out_byte
    jmp emit

err_line_too_long:
    lea rdi, [c_parse]
    lea rsi, [m_toolong]
    jmp err_null

; ---------------- request handling ----------------
; handle_line(rsi=line, rdx=len). preserves rbx,rbp,r12-r15.
handle_line:
    push rbx
    push r12
    push r13
    push r14
    push r15
    test rdx, rdx
    jz hl_ret
    mov rax, rsi
    add rax, rdx
    cmp byte [rax - 1], 13
    jne hl_ns
    dec rdx
hl_ns:
    test rdx, rdx
    jz hl_ret
    cmp byte [rsi], '{'
    jne hl_parse
    mov [lp], rsi
    mov [ll], rdx
    add rsi, rdx
    mov [le], rsi
    call reject_dups               ; TT-02: duplicate keys / malformed
    cmp eax, 1
    je hl_dup
    test eax, eax
    jnz hl_parse
    mov rsi, [lp]
    lea rdi, [k_method]
    mov ecx, 8
    call find_val
    test rax, rax
    jz hl_parse
    cmp rax, [le]
    jae hl_parse
    cmp byte [rax], '"'
    jne hl_parse
    inc rax
    mov [tmp], rax
    mov rdx, rax
hl_mloop:
    cmp rdx, [le]
    jae hl_parse
    mov al, [rdx]
    cmp al, '"'
    je hl_mend
    cmp al, '\'
    je hl_parse
    inc rdx
    mov rax, rdx
    sub rax, [tmp]
    cmp rax, 32
    ja hl_parse
    jmp hl_mloop
hl_mend:
    mov rax, rdx
    sub rax, [tmp]
    test rax, rax
    jz hl_parse
    mov [methodlen], rax
    lea rdi, [methodbuf]
    mov rsi, [tmp]
    mov rcx, rax
    rep movsb
    cmp qword [methodlen], 14   ; notifications/* -> never reply
    jb hl_id
    lea rsi, [methodbuf]
    lea rdi, [m_notif]
    mov ecx, 14
    rep cmpsb
    je hl_ret
hl_id:
    mov rsi, [lp]
    lea rdi, [k_id]
    mov ecx, 4
    call find_val
    test rax, rax
    jz hl_ret
    mov rsi, rax
    lea rdi, [idbuf]
    call cap_id
    test rax, rax
    jnz hl_badid
    lea rsi, [methodbuf]
    mov rdx, [methodlen]
    lea rdi, [m_init]
    call cmp_name
    test rax, rax
    jnz hl_init
    lea rsi, [methodbuf]
    mov rdx, [methodlen]
    lea rdi, [m_disc]
    call cmp_name
    test rax, rax
    jnz hl_disc
    lea rsi, [methodbuf]
    mov rdx, [methodlen]
    lea rdi, [m_ping]
    call cmp_name
    test rax, rax
    jnz hl_ping
    lea rsi, [methodbuf]
    mov rdx, [methodlen]
    lea rdi, [m_list]
    call cmp_name
    test rax, rax
    jnz hl_tools
    lea rsi, [methodbuf]
    mov rdx, [methodlen]
    lea rdi, [m_call]
    call cmp_name
    test rax, rax
    jnz hl_docall
    lea rdi, [c_notfound]
    lea rsi, [m_nomethod]
    call err_id
    jmp hl_ret
hl_init:
    lea rsi, [r_init]
    call send_static
    jmp hl_ret
hl_disc:                        ; 2026-07-28 era: info + tools, no handshake needed
    call out_reset
    lea rsi, [j1]
    call out_cstr
    lea rsi, [idbuf]
    mov rdx, [idlen]
    call out_bytes
    lea rsi, [jres]
    call out_cstr
    lea rsi, [r_disc]
    call out_cstr
    lea rsi, [r_toolsarr]
    call out_cstr
    lea rsi, [r_disctail]
    call out_cstr
    mov al, '}'               ; close root
    call out_byte
    mov al, 10
    call out_byte
    call emit
    jmp hl_ret
hl_ping:
    lea rsi, [r_empty]
    call send_static
    jmp hl_ret
hl_tools:
    call out_reset
    lea rsi, [j1]
    call out_cstr
    lea rsi, [idbuf]
    mov rdx, [idlen]
    call out_bytes
    lea rsi, [jres]
    call out_cstr
    lea rsi, [r_listhead]
    call out_cstr
    lea rsi, [r_toolsarr]
    call out_cstr
    lea rsi, [r_listtail]
    call out_cstr
    mov al, '}'               ; close root
    call out_byte
    mov al, 10
    call out_byte
    call emit
    jmp hl_ret
hl_docall:
    call do_call
    jmp hl_ret
hl_badid:
    lea rdi, [c_invalid]
    lea rsi, [m_badid]
    call err_null
    jmp hl_ret
hl_parse:
    lea rdi, [c_parse]
    lea rsi, [m_parse]
    call err_null
    jmp hl_ret
hl_dup:
    lea rdi, [c_params]
    lea rsi, [m_dup]
    call err_null
hl_ret:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; cap_id(rsi=valptr, rdi=idbuf): raw copy incl quotes for strings. rax=0 ok.
cap_id:
    cmp rsi, [le]
    jae ci_err
    cmp byte [rsi], '"'
    je ci_str
    xor edx, edx
ci_tok:
    cmp rsi, [le]
    jae ci_tokend
    mov al, [rsi]
    cmp al, ','
    je ci_tokend
    cmp al, '}'
    je ci_tokend
    cmp al, ' '
    je ci_tokend
    cmp al, 9
    je ci_tokend
    cmp al, 13
    je ci_tokend
    cmp al, 10
    je ci_tokend
    cmp rdx, 32
    jae ci_err
    mov [rdi + rdx], al
    inc rsi
    inc rdx
    jmp ci_tok
ci_tokend:
    test rdx, rdx
    jz ci_err
    mov [idlen], rdx
    mov byte [idisstr], 1
    xor eax, eax
    ret
ci_str:
    xor edx, edx
    mov al, [rsi]
    mov [rdi + rdx], al
    inc rsi
    inc rdx
ci_sloop:
    cmp rsi, [le]
    jae ci_err
    cmp rdx, 94
    jae ci_err
    mov al, [rsi]
    inc rsi
    mov [rdi + rdx], al
    inc rdx
    cmp al, '\'
    jne ci_nesc
    cmp rsi, [le]
    jae ci_err
    cmp rdx, 94
    jae ci_err
    mov al, [rsi]
    inc rsi
    mov [rdi + rdx], al
    inc rdx
    jmp ci_sloop
ci_nesc:
    cmp al, '"'
    jne ci_sloop
    mov [idlen], rdx
    mov byte [idisstr], 1
    xor eax, eax
    ret
ci_err:
    mov eax, 1
    ret

; do_call
do_call:
    mov rsi, [lp]
    lea rdi, [k_params]
    mov ecx, 8
    call find_val
    test rax, rax
    jz dc_params
    mov [pp], rax
    cmp rax, [le]
    jae dc_params
    cmp byte [rax], '{'
    jne dc_params
    mov rsi, [pp]
    lea rdi, [k_name]
    mov ecx, 6
    call find_val
    test rax, rax
    jz dc_params
    cmp rax, [le]
    jae dc_params
    cmp byte [rax], '"'
    jne dc_params
    mov rsi, rax
    lea rdi, [toolbuf]
    mov ecx, 31
    call parse_str
    test rax, rax
    jz dc_params
    mov [toollen], rdx
    lea rsi, [toolbuf]
    mov rdx, [toollen]
    lea rdi, [t_think]
    call cmp_name
    test rax, rax
    jnz op_think
    lea rsi, [toolbuf]
    mov rdx, [toollen]
    lea rdi, [t_conc]
    call cmp_name
    test rax, rax
    jnz op_conclusion
    lea rsi, [toolbuf]
    mov rdx, [toollen]
    lea rdi, [t_hist]
    call cmp_name
    test rax, rax
    jnz op_history
    lea rsi, [toolbuf]
    mov rdx, [toollen]
    lea rdi, [t_reset]
    call cmp_name
    test rax, rax
    jnz op_reset
    lea rsi, [toolbuf]
    mov rdx, [toollen]
    lea rdi, [t_fread]
    call cmp_name
    test rax, rax
    jnz op_fread
    lea rsi, [toolbuf]
    mov rdx, [toollen]
    lea rdi, [t_fwrite]
    call cmp_name
    test rax, rax
    jnz op_fwrite
    lea rsi, [toolbuf]
    mov rdx, [toollen]
    lea rdi, [t_flist]
    call cmp_name
    test rax, rax
    jnz op_flist
    lea rsi, [toolbuf]
    mov rdx, [toollen]
    lea rdi, [t_mkentity]
    call cmp_name
    test rax, rax
    jnz op_mkentity
    lea rsi, [toolbuf]
    mov rdx, [toollen]
    lea rdi, [t_addobs]
    call cmp_name
    test rax, rax
    jnz op_addobs
    lea rsi, [toolbuf]
    mov rdx, [toollen]
    lea rdi, [t_search]
    call cmp_name
    test rax, rax
    jnz op_search
    lea rsi, [toolbuf]
    mov rdx, [toollen]
    lea rdi, [t_open]
    call cmp_name
    test rax, rax
    jnz op_open
    lea rsi, [toolbuf]
    mov rdx, [toollen]
    lea rdi, [t_mktask]
    call cmp_name
    test rax, rax
    jnz op_mktask
    lea rsi, [toolbuf]
    mov rdx, [toollen]
    lea rdi, [t_query]
    call cmp_name
    test rax, rax
    jnz op_query
    lea rsi, [toolbuf]
    mov rdx, [toollen]
    lea rdi, [t_updtask]
    call cmp_name
    test rax, rax
    jnz op_updtask
    lea rsi, [toolbuf]
    mov rdx, [toollen]
    lea rdi, [t_mkrel]
    call cmp_name
    test rax, rax
    jnz op_mkrel
    lea rsi, [toolbuf]
    mov rdx, [toollen]
    lea rdi, [t_delete]
    call cmp_name
    test rax, rax
    jnz op_delete
    lea rsi, [toolbuf]
    mov rdx, [toollen]
    lea rdi, [t_delprefix]
    call cmp_name
    test rax, rax
    jnz op_delprefix
    lea rsi, [toolbuf]
    mov rdx, [toollen]
    lea rdi, [t_versions]
    call cmp_name
    test rax, rax
    jnz op_versions
    lea rsi, [toolbuf]
    mov rdx, [toollen]
    lea rdi, [t_health]
    call cmp_name
    test rax, rax
    jnz op_health
    lea rsi, [toolbuf]
    mov rdx, [toollen]
    lea rdi, [t_feedback]
    call cmp_name
    test rax, rax
    jnz op_feedback
    lea rsi, [toolbuf]
    mov rdx, [toollen]
    lea rdi, [t_explain]
    call cmp_name
    test rax, rax
    jnz op_explain
    lea rsi, [toolbuf]
    mov rdx, [toollen]
    lea rdi, [t_modinit]
    call cmp_name
    test rax, rax
    jnz op_modinit
    lea rsi, [toolbuf]
    mov rdx, [toollen]
    lea rdi, [t_modtrain]
    call cmp_name
    test rax, rax
    jnz op_modtrain
    lea rsi, [toolbuf]
    mov rdx, [toollen]
    lea rdi, [t_modpredict]
    call cmp_name
    test rax, rax
    jnz op_modpredict
    lea rsi, [toolbuf]
    mov rdx, [toollen]
    lea rdi, [t_modsave]
    call cmp_name
    test rax, rax
    jnz op_modsave
    lea rsi, [toolbuf]
    mov rdx, [toollen]
    lea rdi, [t_modload]
    call cmp_name
    test rax, rax
    jnz op_modload
    lea rsi, [toolbuf]
    mov rdx, [toollen]
    lea rdi, [t_modstatus]
    call cmp_name
    test rax, rax
    jnz op_modstatus
    lea rdi, [c_params]
    lea rsi, [m_notool]
    jmp err_id
dc_params:
    lea rdi, [c_params]
    lea rsi, [m_params]
    jmp err_id

; op_conclusion: {reason, thought?, conclusion?, valid?} on tinythink.db
;   conclusion present -> insert (dup reason refused)
;   else valid present -> set valid flag (invalidate / revalidate)
;   else -> read row by reason.
op_conclusion:
    mov rsi, [pp]
    lea rdi, [k_args]
    mov ecx, 11
    call find_val
    test rax, rax
    jz dc_params
    mov [ap], rax
    ; reason required, ascii 1..64
    mov rsi, [ap]
    lea rdi, [k_reason]
    mov ecx, 8
    call find_val
    test rax, rax
    jz dc_params
    mov rsi, rax
    lea rdi, [rsnbuf]
    mov ecx, 128
    call parse_str
    test rax, rax
    jz dc_params
    test rdx, rdx
    jz dc_params
    mov [rsnlen], rdx
    lea rsi, [rsnbuf]
    mov rdx, [rsnlen]
    call ascii_only
    test rax, rax
    jnz oc_ascii
    mov qword [cmask], 0
    ; thought? ascii 0..512
    mov rsi, [ap]
    lea rdi, [k_thought]
    mov ecx, 9
    call find_val
    test rax, rax
    jz oc_noth
    mov rsi, rax
    lea rdi, [thbuf]
    mov ecx, 512
    call parse_str
    test rax, rax
    jz dc_params
    mov [cthlen], rdx
    lea rsi, [thbuf]
    mov rdx, [cthlen]
    call ascii_only
    test rax, rax
    jnz oc_ascii
    or qword [cmask], 1
oc_noth:
    ; conclusion? ascii 1..512
    mov rsi, [ap]
    lea rdi, [k_conc]
    mov ecx, 12
    call find_val
    test rax, rax
    jz oc_noconc
    mov rsi, rax
    lea rdi, [ccbuf]
    mov ecx, 512
    call parse_str
    test rax, rax
    jz dc_params
    test rdx, rdx
    jz dc_params
    mov [cclen], rdx
    lea rsi, [ccbuf]
    mov rdx, [cclen]
    call ascii_only
    test rax, rax
    jnz oc_ascii
    or qword [cmask], 2
oc_noconc:
    ; valid?
    mov rsi, [ap]
    lea rdi, [k_valid]
    mov ecx, 7
    call find_val
    test rax, rax
    jz oc_noval
    mov rsi, rax
    call parse_bool
    test rax, rax
    jnz dc_params
    mov al, [boolval]
    mov [cvalid], al
    or qword [cmask], 4
oc_noval:
    ; open (lazy create) for every conclusion op
    call db_open_ex
    test rax, rax
    jnz oc_db
    test qword [cmask], 2
    jnz oc_insert
    test qword [cmask], 4
    jnz oc_flag
    test qword [cmask], 1
    jnz oc_thoughtalone
    jmp oc_read
oc_thoughtalone:
    call db_close
    lea rdi, [c_params]
    lea rsi, [m_params]
    jmp err_id
oc_ascii:
    lea rdi, [c_params]
    lea rsi, [m_ascii]
    jmp err_id
oc_db:
    lea rdi, [c_internal]
    lea rsi, [m_nodb]
    jmp err_id
oc_insert:
    call scan_reason
    cmp rax, 1
    je oc_dup
    cmp rax, 2
    je oc_corrupt
    mov rax, [maxrowid]
    inc rax
    mov [newrowid], rax
    call insert_row
    test rax, rax
    jnz oc_insfail
    call hdr_touch
    call db_close
    ; inner {"rowid":N,"reason":"R","valid":true}
    lea rax, [jsontmp]
    mov [outptr], rax
    mov qword [outlen], 0
    lea rsi, [jc_rowid]
    call out_cstr
    mov rax, [newrowid]
    call out_uint
    lea rsi, [jc_reason]
    call out_cstr
    lea rsi, [rsnbuf]
    mov rdx, [rsnlen]
    call out_escaped
    mov al, '"'
    call out_byte
    lea rsi, [jc_valid]
    call out_cstr
    lea rsi, [b_true]
    call out_cstr
    mov al, '}'
    call out_byte
    jmp oc_envelope
oc_dup:
    call db_close
    lea rdi, [c_params]
    lea rsi, [m_exists]
    jmp err_id
oc_corrupt:
    call db_close
    lea rdi, [c_internal]
    lea rsi, [m_nodb]
    jmp err_id
oc_insfail:
    cmp rax, 2
    je oc_full
    call db_close
    lea rdi, [c_internal]
    lea rsi, [m_nodb]
    jmp err_id
oc_full:
    call db_close
    lea rdi, [c_internal]
    lea rsi, [m_dbfull]
    jmp err_id
oc_flag:
    call scan_reason
    cmp rax, 1
    jne oc_flagmiss
    call flip_valid
    test rax, rax
    jnz oc_flagio
    call hdr_touch
    mov al, [cvalid]
    mov [fvalid], al
    call db_close
    lea rax, [jsontmp]
    mov [outptr], rax
    mov qword [outlen], 0
    lea rsi, [jc_rowid]
    call out_cstr
    mov rax, [frowid]
    call out_uint
    lea rsi, [jc_reason]
    call out_cstr
    lea rsi, [rsnbuf]
    mov rdx, [rsnlen]
    call out_escaped
    mov al, '"'
    call out_byte
    lea rsi, [jc_valid]
    call out_cstr
    cmp byte [fvalid], 0
    je oc_fvfalse
    lea rsi, [b_true]
    call out_cstr
    jmp oc_inner_end
oc_fvfalse:
    lea rsi, [b_false]
    call out_cstr
    jmp oc_inner_end
oc_flagmiss:
    call db_close
    cmp rax, 2
    je oc_corrupt
    lea rdi, [c_params]
    lea rsi, [m_nofile]
    jmp err_id
oc_flagio:
    call db_close
    lea rdi, [c_internal]
    lea rsi, [m_nodb]
    jmp err_id
oc_read:
    call scan_reason
    cmp rax, 1
    jne oc_flagmiss
    call db_close
    lea rax, [jsontmp]
    mov [outptr], rax
    mov qword [outlen], 0
    lea rsi, [jc_rowid]
    call out_cstr
    mov rax, [frowid]
    call out_uint
    lea rsi, [jc_reason]
    call out_cstr
    mov rsi, [fo_r]
    mov rdx, [fl_r]
    call out_escaped
    mov al, '"'
    call out_byte
    lea rsi, [jc_thought]
    call out_cstr
    mov rsi, [fo_t]
    mov rdx, [fl_t]
    call out_escaped
    mov al, '"'
    call out_byte
    lea rsi, [jc_conc]
    call out_cstr
    mov rsi, [fo_c]
    mov rdx, [fl_c]
    call out_escaped
    mov al, '"'
    call out_byte
    lea rsi, [jc_valid]
    call out_cstr
    cmp byte [fvalid], 0
    je oc_rvfalse
    lea rsi, [b_true]
    call out_cstr
    jmp oc_inner_end
oc_rvfalse:
    lea rsi, [b_false]
    call out_cstr
    jmp oc_inner_end
oc_inner_end:
    mov al, '}'
    call out_byte
    mov rax, [outlen]
    mov [innerlen], rax
oc_envelope:
    mov rax, [outlen]
    mov [innerlen], rax
    lea rax, [outbuf]
    mov [outptr], rax
    call out_reset
    lea rsi, [j1]
    call out_cstr
    lea rsi, [idbuf]
    mov rdx, [idlen]
    call out_bytes
    lea rsi, [jrescontent]
    call out_cstr
    lea rsi, [jsontmp]
    mov rdx, [innerlen]
    call out_escaped
    lea rsi, [jcontent_end2]
    call out_cstr
    mov al, 10
    call out_byte
    jmp emit

; valid_name(rsi, rdx=len): rax=0 ok, 1 bad. 1..64 [A-Za-z0-9._-], not ./...
; valid_name(rsi, rdx=len): rax=0 ok / 1 bad.
; Machine identifiers: [A-Za-z0-9._@:+#~-]{1,128} (hyphen last).
; Rejects single "." and "..". No spaces, no slashes, no JSON syntax.
valid_name:
    cmp rdx, 1
    jb vn_bad
    cmp rdx, 128
    ja vn_bad
    cmp rdx, 1
    jne vn_n1
    cmp byte [rsi], '.'
    je vn_bad
vn_n1:
    cmp rdx, 2
    jne vn_loop
    cmp byte [rsi], '.'
    jne vn_loop
    cmp byte [rsi + 1], '.'
    je vn_bad
vn_loop:
    test rdx, rdx
    jz vn_ok
    mov al, [rsi]
    inc rsi
    dec rdx
    cmp al, 'A'
    jb vn_lo
    cmp al, 'Z'
    jbe vn_loop
    cmp al, '_'
    je vn_loop
    cmp al, 'a'
    jb vn_bad
    cmp al, 'z'
    jbe vn_loop
    cmp al, '~'
    je vn_loop
    jmp vn_bad
vn_lo:
    cmp al, '0'
    jb vn_sym
    cmp al, '9'
    jbe vn_loop
    cmp al, ':'
    je vn_loop
    cmp al, '@'
    je vn_loop
    jmp vn_bad
vn_sym:
    cmp al, '#'
    je vn_loop
    cmp al, '+'
    je vn_loop
    cmp al, '-'
    je vn_loop
    cmp al, '.'
    je vn_loop
    jmp vn_bad
vn_ok:
    xor eax, eax
    ret
vn_bad:
    mov eax, 1
    ret

; ascii_only(rsi, rdx=len): rax=0 ok, 1 bad. Allows 9,10,13,32..126.
; v3: 32B classify lanes (sign-bit reject, DEL reject, <=31 minus 9/10/13
; reject) + scalar tail. Scalar build: pure scalar loop.
ascii_only:
if defined USE_SCALAR
    test rdx, rdx
    jz ao_ok
ao_loop:
    mov al, [rsi]
    inc rsi
    dec rdx
    cmp al, 9
    je ao_next
    cmp al, 10
    je ao_next
    cmp al, 13
    je ao_next
    cmp al, 32
    jb ao_bad
    cmp al, 126
    ja ao_bad
ao_next:
    test rdx, rdx
    jnz ao_loop
ao_ok:
    xor eax, eax
    ret
ao_bad:
    mov eax, 1
    ret
else
    test rdx, rdx
    jz ao_okv
    vpxor ymm0, ymm0, ymm0
    vpbroadcastb ymm2, [c127]
    vpbroadcastb ymm4, [c31]
    vpbroadcastb ymm5, [c9]
    vpbroadcastb ymm6, [c10]
    vpbroadcastb ymm7, [c13]
ao_blk:
    cmp rdx, 32
    jb ao_tail
    vmovdqu ymm1, [rsi]
    vpmovmskb eax, ymm1          ; any byte >= 0x80?
    test eax, eax
    jnz ao_badv
    vpcmpeqb ymm3, ymm1, ymm2    ; == 127?
    vpmovmskb eax, ymm3
    test eax, eax
    jnz ao_badv
    vpcmpgtb ymm3, ymm1, ymm4    ; > 31? (32..127; negatives already out)
    vpmovmskb r8d, ymm3
    vpcmpeqb ymm3, ymm1, ymm5    ; == 9?
    vpmovmskb r9d, ymm3
    vpcmpeqb ymm3, ymm1, ymm6    ; == 10?
    vpmovmskb r10d, ymm3
    vpcmpeqb ymm3, ymm1, ymm7    ; == 13?
    vpmovmskb r11d, ymm3
    or r9d, r10d
    or r9d, r11d                ; allowed-low mask
    not r8d                     ; <= 31 mask (all 32 lanes meaningful)
    not r9d                     ; not-allowed mask
    and r8d, r9d                ; bad = low AND not allowed
    test r8d, r8d
    jnz ao_badv
    add rsi, 32
    sub rdx, 32
    jmp ao_blk
ao_tail:
    test rdx, rdx
    jz ao_okv
ao_sloop:
    mov al, [rsi]
    inc rsi
    dec rdx
    cmp al, 9
    je ao_snext
    cmp al, 10
    je ao_snext
    cmp al, 13
    je ao_snext
    cmp al, 32
    jb ao_badv
    cmp al, 126
    ja ao_badv
ao_snext:
    test rdx, rdx
    jnz ao_sloop
ao_okv:
    vzeroupper
    xor eax, eax
    ret
ao_badv:
    vzeroupper
    mov eax, 1
    ret
end if

; ---------------- sqlite engine (pure asm, genuine file format) ----------------
; Clobbers rax,rcx,rdx,rsi,rdi,r8-r11; preserves rbx,rbp,r12-r15.
; Page ops need db open (dbfd valid, LOCK_EX held). rax: 0 ok, 1 err,
; 2 db-full (insert/split only).

be16_ld:                          ; rsi -> rax
    movzx eax, byte [rsi]
    shl eax, 8
    movzx ecx, byte [rsi + 1]
    or eax, ecx
    ret

be32_ld:                          ; rsi -> rax
    movzx eax, byte [rsi]
    shl eax, 8
    movzx ecx, byte [rsi + 1]
    or eax, ecx
    shl eax, 8
    movzx ecx, byte [rsi + 2]
    or eax, ecx
    shl eax, 8
    movzx ecx, byte [rsi + 3]
    or eax, ecx
    ret

be16_st:                          ; rax -> [rdi]
    mov rcx, rax
    shr rcx, 8
    mov [rdi], cl
    mov [rdi + 1], al
    ret

be32_st:                          ; rax -> [rdi]
    push rax
    shr rax, 24
    mov [rdi], al
    pop rax
    push rax
    shr rax, 16
    mov [rdi + 1], al
    pop rax
    push rax
    shr rax, 8
    mov [rdi + 2], al
    pop rax
    mov [rdi + 3], al
    ret

; varint_get(rsi=ptr, rdx=end): rax=value, rcx=newptr (0=err)
varint_get:
    cmp rsi, rdx
    jae vg_err
    xor eax, eax
    mov r9d, 8
vg_loop:
    cmp rsi, rdx
    jae vg_err
    movzx r8d, byte [rsi]
    inc rsi
    test r9d, r9d
    jz vg_ninth
    shl rax, 7
    and r8d, 0x7F
    or rax, r8
    test byte [rsi - 1], 0x80
    jz vg_done
    dec r9d
    jmp vg_loop
vg_ninth:
    shl rax, 8
    or rax, r8
vg_done:
    mov rcx, rsi
    ret
vg_err:
    xor ecx, ecx
    ret

; varint_put(rax=value, rdi=dest): rcx=len. Values < 2^32 in our use.
varint_put:
    push rbx
    push r10
    mov rbx, rax
    mov r8d, 1
vp_cnt:
    shr rbx, 7
    test rbx, rbx
    jz vp_have
    inc r8d
    jmp vp_cnt
vp_have:
    mov r10, r8
    dec r10
vp_emit:
    mov rbx, rax
    mov rcx, r10
    imul rcx, rcx, 7
    shr rbx, cl
    and bl, 0x7F
    test r10, r10
    jz vp_last
    or bl, 0x80
vp_last:
    mov [rdi], bl
    inc rdi
    dec r10
    jns vp_emit
    mov rcx, r8
    pop r10
    pop rbx
    ret

; pg_read(rdi=pgno, rsi=buf): rax 0 ok / 1 err
; Page cache: 16 slots of (pgno, use-tick, 4096B). Write-through, flushed
; whenever the db identity (ino/size/mtime) differs at open. All helpers
; preserve rbx,rbp,r12-r15 and their rdi/rsi args; clobber rax,rcx,rdx,r8-r11.
cache_probe:
    mov edi, edi                ; canonical 32-bit pgno for matching
    test rdi, rdi                ; pgno 0 never cached
    jz cp_miss
    push rdi
    push rsi
    push rcx
    push r8
    xor ecx, ecx
cp_scan:
    cmp rcx, 16
    jae cp_miss_p
    mov rax, rcx
    shl rax, 3
    lea r8, [cpg]
    cmp [r8 + rax], rdi
    je cp_hit
    inc rcx
    jmp cp_scan
cp_hit:
    mov rax, rcx
    shl rax, 3                    ; slot qword index for cuse
    push rax
    shl rcx, 12                   ; slot byte offset
    lea rsi, [cdata]
    add rsi, rcx
    mov rdi, [rsp + 24]           ; saved dst buf (rsi)
    mov ecx, 512
    rep movsq
    inc qword [ctick]
    mov rcx, [ctick]
    pop rax                       ; slot*8
    lea rdx, [cuse]
    mov [rdx + rax], rcx
    pop r8
    pop rcx
    pop rsi
    pop rdi
    xor eax, eax
    ret
cp_miss_p:
    pop r8
    pop rcx
    pop rsi
    pop rdi
cp_miss:
    mov eax, 1
    ret

; cache_fill(rdi=pgno, rsi=src): store page (LRU victim). Preserves rdi,rsi.
cache_fill:
    mov edi, edi
    test rdi, rdi
    jz cf_ret
    push rdi
    push rsi
    push rcx
    push r8
    push r9
    xor ecx, ecx
    mov r8, -1                    ; best (min) use
    xor r9d, r9d                  ; best slot
cf_look:
    cmp rcx, 16
    jae cf_scan
    mov rax, rcx
    shl rax, 3
    lea rdx, [cpg]
    mov rdx, [rdx + rax]
    mov rax, [rsp + 32]           ; wanted pgno
    cmp rdx, rax
    je cf_update                  ; already cached: refresh in place
    inc rcx
    jmp cf_look
cf_update:
    mov r9, rcx
    jmp cf_have
cf_scan:
    cmp rcx, 16
    jae cf_have
    mov rax, rcx
    shl rax, 3
    lea rdx, [cuse]
    mov rdx, [rdx + rax]
    cmp rdx, r8
    jae cf_next
    mov r8, rdx
    mov r9, rcx
cf_next:
    inc rcx
    jmp cf_scan
cf_have:
    mov rax, r9
    shl rax, 3
    lea rdx, [cpg]
    mov rcx, [rsp + 32]           ; saved pgno
    mov [rdx + rax], rcx
    mov rax, r9
    shl rax, 12
    lea rdx, [cdata]
    add rdx, rax                  ; dst slot
    mov rsi, [rsp + 24]           ; saved src
    mov rdi, rdx
    mov ecx, 512
    rep movsq
    inc qword [ctick]
    mov rcx, [ctick]
    mov rax, r9
    shl rax, 3
    lea rdx, [cuse]
    mov [rdx + rax], rcx
    pop r9
    pop r8
    pop rcx
    pop rsi
    pop rdi
cf_ret:
    ret

; cache_flush: empty all slots. Preserves rbx,rbp,r12-r15.
cache_flush:
    push rax
    push rcx
    push rdi
    lea rdi, [cpg]
    xor eax, eax
    mov ecx, 16
    rep stosq
    pop rdi
    pop rcx
    pop rax
    ret

; ---- Learnable usage ranking: 262144 slots, 88-bit stable identity ----
; USLOT_BITS is the single growth point: to grow again, change it (and the
; utab reservation). Nothing else encodes capacity.
USLOT_BITS = 18
USLOTS = 262144
USLOT_MASK = 262143
USLOT_SZ = 32
UPROBE_N = 16
; Slot (32B): +0 key u64 (kind<<56 | id56) | +8 h2 u32 (second hash) |
; +12 access u32 sat | +16 pos u32 sat | +20 neg u32 sat | +24 last u32
; tick | +28 conf u16 | +30 dirty u8 | +31 zero u8.
; Identity: facts/entities/tasks hash a stable NAME (FNV-1a-64, low 56
; bits); observations (immutable rows) use their rowid. A hot hit needs
; key AND h2 (88 bits); the usage table keeps the original names and the
; loader string-distinguishes collisions instead of merging.
; Score u64 (overflow-impossible: clamped inputs, floored at zero):
;   net_ok ? min(access,ACAP)*WA : 0
;   + min(pos,PCAP)*WP + min(conf,CCAP)*WC
;   + max(0,RWIN-(now-last))*WR - min(neg*WN,NSUB)
; net_ok = (pos >= neg): a memory judged net-misleading gets NO credit
; for being read. Popularity never asserts truth: the score ranks
; retrieval only, and conf counts corroboration (repeat versions).
U_WA = 1
U_WP = 8
U_WN = 8
U_WR = 1
U_WC = 2
U_ACAP = 16777216
U_PCAP = 16777216
U_CCAP = 65535
U_RWIN = 1024
U_NSUB = 4294967296
UQ_N = 8192
UQ_MASK = 8191
UQ_ENT_SZ = 136
; Pending-name queue: hot slots hold hashes, but flush must persist NAMES.
; Entries (slot u32 | kind u8 | len u8 | pad | name[64]) record
; (slot,name) at slot-create; flush drains the ring. Overflow drops the oldest, clears
; its dirty bit, and counts udropped: bounded, documented loss only under
; adversarial read-only floods with no flush between.
;
; fnv1a64(rsi=ptr, rdx=len): rax = hash. Clobbers rax,rcx,rsi,rdx.
fnv1a64:
    mov rax, 14695981039346656037
    test rdx, rdx
    jz fh_done
fh_loop:
    movzx ecx, byte [rsi]
    xor rax, rcx
    mov rcx, 1099511628211
    imul rax, rcx
    inc rsi
    dec rdx
    jnz fh_loop
fh_done:
    ret
; fnv1a32s(rsi=ptr, rdx=len): eax = 32-bit hash via the FNV-1 (multiply
; first) variant: a genuinely different stream from fnv1a64, used as h2.
; Clobbers eax,ecx,rsi,rdx.
fnv1a32s:
    mov eax, 2166136261
    test rdx, rdx
    jz fh32_done
fh32_loop:
    movzx ecx, byte [rsi]
    imul eax, eax, 16777619
    xor eax, ecx
    inc rsi
    dec rdx
    jnz fh32_loop
fh32_done:
    ret
; ukey_name(rdi=kind, rsi=ptr, rdx=len): rbx=key, r8d=h2.
; Clobbers rax,rcx,rsi,rdx,r8. Preserves rdi.
ukey_name:
    push rsi
    push rdx
    call fnv1a64
    shl rax, 8
    shr rax, 8                  ; low 56 bits (imm56 has no AND encoding)
    mov rcx, rdi
    shl rcx, 56
    or rax, rcx
    mov rbx, rax
    pop rdx
    pop rsi
    call fnv1a32s
    mov r8d, eax
    ret
; ukey_rowid(rdi=kind, rsi=rowid): rbx=key, r8d=h2. The h2 mix keeps
; rowid identities in the same 88-bit regime as hashed ones.
; Clobbers rax,rcx,r8. Preserves rdi,rsi.
ukey_rowid:
    mov rbx, rsi
    shl rbx, 8
    shr rbx, 8
    mov rcx, rdi
    shl rcx, 56
    or rbx, rcx
    mov rax, rsi
    mov rcx, 2654435761
    imul rax, rcx
    inc rax
    mov r8d, eax
    ret
; ufind(rbx=key, r8d=h2): rdx = slot (hit, empty, or min-score victim);
; rax = 1 hit / 0 otherwise. Probes UPROBE_N. Preserves rbx,rdi,r12-r15;
; clobbers rax,rcx,rdx,rsi,r8-r11 (r9 = probe base).
ufind:
    push rbx
    push rdi
    push r12
    push r13
    mov r13d, r8d                ; h2 spill
    mov rax, rbx
    xor eax, r13d
    imul rax, rax, 1597334677
    and eax, USLOT_MASK
    mov r9d, eax                ; base idx
    xor r10d, r10d              ; step
    mov r11, -1                 ; best (min) score
    xor r12d, r12d              ; best slot (ptr)
ufd_probe:
    cmp r10, UPROBE_N
    jae ufd_evict
    mov eax, r9d
    add eax, r10d
    and eax, USLOT_MASK
    shl rax, 5
    lea rdx, [utab]
    add rdx, rax
    mov rax, [rdx]
    test rax, rax
    jz ufd_empty
    cmp rax, rbx
    jne ufd_occupied
    mov eax, [rdx + 8]
    cmp eax, r13d
    je ufd_hit
ufd_occupied:
    push rdx
    call uscore                 ; clobbers rax,rcx only; rdx spill for safety
    pop rdx
    cmp rax, r11
    jae ufd_next
    mov r11, rax
    mov r12, rdx
ufd_next:
    inc r10
    jmp ufd_probe
ufd_hit:
    mov eax, 1
    jmp ufd_done
ufd_empty:
    xor eax, eax
    jmp ufd_done
ufd_evict:
    mov rdx, r12
    xor eax, eax
ufd_done:
    pop r13
    pop r12
    pop rdi
    pop rbx
    ret
; uscore(rdx=slot): rax = u64 ranking score. Clobbers rax,rcx only
; (rbx/r12 spills preserve the caller's key and eviction state).
uscore:
    push rbx
    push r12
    mov eax, [rdx + 16]         ; pos
    mov ecx, U_PCAP
    cmp eax, ecx
    cmovae eax, ecx
    mov r12d, eax               ; pos (for the net-misleading gate below)
    xor ebx, ebx                ; score accumulator
    mov eax, [rdx + 20]         ; neg
    cmp eax, r12d
    ja us_noaccess              ; net-misleading: no credit for reads
    mov eax, [rdx + 12]         ; access
    mov ecx, U_ACAP
    cmp eax, ecx
    cmovae eax, ecx
    add rbx, rax                ; * U_WA(1): identity
us_noaccess:
    mov eax, [rdx + 16]         ; pos
    mov ecx, U_PCAP
    cmp eax, ecx
    cmovae eax, ecx
    imul rax, rax, U_WP
    add rbx, rax
    movzx eax, word [rdx + 28]  ; conf
    imul rax, rax, U_WC
    add rbx, rax
    mov eax, dword [utick]            ; now (low 32, wrap-safe)
    sub eax, [rdx + 24]         ; age = now - last mod 2^32
    cmp eax, U_RWIN
    jae us_norec
    mov ecx, U_RWIN
    sub ecx, eax
    mov eax, ecx
    imul rax, rax, U_WR
    add rbx, rax
us_norec:
    mov eax, [rdx + 20]         ; neg
    shl rax, 3                  ; * U_WN(8); neg u32 so no overflow
    mov rcx, U_NSUB
    cmp rax, rcx
    cmovae rax, rcx
    cmp rbx, rax
    jb us_zero
    sub rbx, rax
    mov rax, rbx
    pop r12
    pop rbx
    ret
us_zero:
    xor eax, eax
    pop r12
    pop rbx
    ret
; uenqueue(rdx=slot, rsi=name, ecx=namelen, edi=kind): record (slot,name)
; for flush. Preserves rbx,rbp,r12-r15; clobbers rax,rcx,rdx,rsi,rdi,r8-r11.
uenqueue:
    push rbx
    push r12
    mov r8d, ecx
    cmp r8d, 128
    jbe uq_lenok
    mov r8d, 128
uq_lenok:
    mov rax, rdx
    lea rbx, [utab]
    sub rax, rbx
    shr rax, 5                  ; slot idx
    mov r12d, eax
    mov rax, [uq_tail]
    inc rax
    and rax, UQ_MASK
    cmp rax, [uq_head]
    jne uq_space
    ; full: drop oldest, clear its dirty (bounded documented loss)
    mov rax, [uq_head]
    imul rax, rax, UQ_ENT_SZ
    lea rbx, [uqueue]
    add rbx, rax
    mov eax, [rbx]              ; victim slot idx
    shl rax, 5
    lea rcx, [utab]
    add rcx, rax
    mov byte [rcx + 30], 0
    inc qword [uq_head]
    and qword [uq_head], UQ_MASK
    inc qword [udropped]
    mov rax, [uq_tail]
    inc rax
    and rax, UQ_MASK
uq_space:
    mov rcx, [uq_tail]
    imul rcx, rcx, UQ_ENT_SZ
    lea rbx, [uqueue]
    add rbx, rcx
    mov [rbx], r12d
    mov [rbx + 4], dil
    mov [rbx + 5], r8b          ; namelen (<=64, for flush rehash)
    mov rdi, rbx
    add rdi, 8
    mov rcx, r8
    rep movsb
    inc qword [uq_tail]
    and qword [uq_tail], UQ_MASK
    pop r12
    pop rbx
    ret
; use_bump_name(rdi=kind, rsi=ptr, rdx=len): access++, tick, enqueue on
; 0->1 dirty. Preserves rbx,rcx,rdx,rsi,rdi,r12-r15.
use_bump_name:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    mov qword [udirty], 1
    push rsi
    push rdx
    call ukey_name              ; rbx=key r8d=h2 (rsi/rdx clobbered)
    pop rdx
    pop rsi
    call ufind                  ; rdx=slot rax=hit
    test rax, rax
    jnz ubn_hit
    mov [rdx], rbx
    mov [rdx + 8], r8d
    mov dword [rdx + 12], 1
    mov dword [rdx + 16], 0
    mov dword [rdx + 20], 0
    inc qword [utick]
    mov eax, dword [utick]
    mov [rdx + 24], eax
    mov word [rdx + 28], 0
    mov byte [rdx + 30], 1
    mov byte [rdx + 31], 0
    jmp ubn_enq
ubn_hit:
    cmp dword [rdx + 12], 0xFFFFFFFF
    jae ubn_ticked
    inc dword [rdx + 12]
ubn_ticked:
    inc qword [utick]
    mov eax, dword [utick]
    mov [rdx + 24], eax
    cmp byte [rdx + 30], 0
    jne ubn_done
    mov byte [rdx + 30], 1
ubn_enq:
    mov rsi, [rsp + 8]          ; name ptr (stack: rdi+0 rsi+8 rdx+16 rcx+24 rbx+32)
    mov rcx, [rsp + 16]         ; namelen
    mov rdi, [rsp]              ; kind
    call uenqueue                ; (rdx=slot, rsi=name, ecx=len, edi=kind)
ubn_done:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret
; use_bump_id(rdi=kind, rsi=rowid): same for rowid identities. Flush
; coverage via decimal-name queue entries (u64_dec of the rowid into uqnum;
; uenqueue copies): the loader re-derives the rowid the same way.
; Preserves rbx,rcx,rdx,rsi,rdi,r12-r15.
use_bump_id:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    mov qword [udirty], 1
    call ukey_rowid
    call ufind
    test rax, rax
    jnz ubi_hit
    mov [rdx], rbx
    mov [rdx + 8], r8d
    mov dword [rdx + 12], 1
    mov dword [rdx + 16], 0
    mov dword [rdx + 20], 0
    inc qword [utick]
    mov eax, dword [utick]
    mov [rdx + 24], eax
    mov word [rdx + 28], 0
    mov byte [rdx + 30], 1
    mov byte [rdx + 31], 0
    jmp ubi_enq
ubi_hit:
    cmp dword [rdx + 12], 0xFFFFFFFF
    jae ubi_ticked
    inc dword [rdx + 12]
ubi_ticked:
    inc qword [utick]
    mov eax, dword [utick]
    mov [rdx + 24], eax
    cmp byte [rdx + 30], 0
    jne ubi_done
    mov byte [rdx + 30], 1
ubi_enq:
    push rdx                    ; slot spill (u64_dec clobbers rdx)
    mov rax, [rsp + 16]         ; rowid (stack: slot+0 rdi+8 rsi+16 rdx+24 rcx+32 rbx+40)
    lea rdi, [uqnum]
    call u64_dec                ; rdx = declen
    mov rcx, rdx
    lea rsi, [uqnum]
    mov rdi, [rsp + 8]          ; kind
    pop rdx                     ; slot
    call uenqueue
ubi_done:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; use_score_name(rdi=kind, rsi=ptr, rdx=len): rax = u64 score (0 unknown).
; use_score_id(rdi=kind, rsi=rowid): same for rowid identities.
; use_slot_name/use_slot_id: rdx = slot, rax = 1 found / 0 not.
; All preserve rbx,rcx,rdx,rsi,rdi,r12-r15.
use_score_name:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    call ukey_name
    call ufind
    test rax, rax
    jz usc_miss
    call uscore
    jmp usc_done
usc_miss:
    xor eax, eax
usc_done:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret
use_score_id:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    call ukey_rowid
    call ufind
    test rax, rax
    jz usc_miss
    call uscore
    jmp usc_done
use_slot_name:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    call ukey_name
    call ufind                  ; rdx=slot rax=hit; r8/r9 are scratch here
    mov r8, rdx
    mov r9, rax
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    mov rdx, r8
    mov rax, r9
    ret
use_slot_id:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    call ukey_rowid
    call ufind
    mov r8, rdx
    mov r9, rax
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    mov rdx, r8
    mov rax, r9
    ret
; use_fb_name(rdi=kind, rsi=ptr, rdx=len, rcx=1 useful / 0 misleading):
; pos/neg++, tick, enqueue on 0->1 dirty. Durability is the caller's job
; (the feedback tool flushes inline). Same preserve contract.
use_fb_name:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r10                        ; preserved; signal travels on the stack
    mov qword [udirty], 1         ; (ufind clobbers r8-r11: no scratch reg
    push rsi                      ; survives it; pushed rcx at [rsp+32] does)
    push rdx
    call ukey_name
    pop rdx
    pop rsi
    call ufind
    test rax, rax
    jnz ufb_hit
    mov [rdx], rbx
    mov [rdx + 8], r8d
    mov dword [rdx + 12], 0
    cmp qword [rsp + 32], 1      ; signal (stack: r10+0 rdi+8 rsi+16 rdx+24 rcx+32 rbx+40)
    jne ufb_neg0
    mov dword [rdx + 16], 1
    mov dword [rdx + 20], 0
    jmp ufb_tick
ufb_neg0:
    mov dword [rdx + 16], 0
    mov dword [rdx + 20], 1
    jmp ufb_tick
ufb_hit:
    cmp qword [rsp + 32], 1      ; signal (stack layout as above)
    jne ufb_neg
    cmp dword [rdx + 16], 0xFFFFFFFF
    jae ufb_ticked
    inc dword [rdx + 16]
    jmp ufb_ticked
ufb_neg:
    cmp dword [rdx + 20], 0xFFFFFFFF
    jae ufb_ticked
    inc dword [rdx + 20]
ufb_ticked:
    inc qword [utick]
    mov eax, dword [utick]
    mov [rdx + 24], eax
    cmp byte [rdx + 30], 0
    jne ufb_done
    mov byte [rdx + 30], 1
    mov rsi, [rsp + 16]         ; name (stack: r10+0 rdi+8 rsi+16 rdx+24 rcx+32 rbx+40)
    mov rcx, [rsp + 24]         ; namelen
    mov rdi, [rsp + 8]          ; kind
    call uenqueue
    jmp ufb_done
ufb_tick:
    inc qword [utick]
    mov eax, dword [utick]
    mov [rdx + 24], eax
    mov word [rdx + 28], 0
    mov byte [rdx + 30], 1
    mov byte [rdx + 31], 0
    mov rsi, [rsp + 16]
    mov rcx, [rsp + 24]
    mov rdi, [rsp + 8]
    call uenqueue
ufb_done:
    pop r10
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret
; use_fb_id(rdi=kind, rsi=rowid, rdx=1 useful / 0 misleading): same for
; rowid identities (observations). Signal travels on the stack: ufind
; clobbers r8-r11, so no scratch register survives it. Same preserve
; contract as use_fb_name.
use_fb_id:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    mov qword [udirty], 1
    call ukey_rowid              ; preserves rdx (signal)
    call ufind                   ; rdx=slot rax=hit
    test rax, rax
    jnz ufi_hit
    mov [rdx], rbx
    mov [rdx + 8], r8d
    mov dword [rdx + 12], 0
    cmp qword [rsp + 16], 1      ; signal (stack: rdi+0 rsi+8 rdx+16 rcx+24 rbx+32)
    jne ufi_neg0
    mov dword [rdx + 16], 1
    mov dword [rdx + 20], 0
    jmp ufi_tick
ufi_neg0:
    mov dword [rdx + 16], 0
    mov dword [rdx + 20], 1
    jmp ufi_tick
ufi_hit:
    cmp qword [rsp + 16], 1
    jne ufi_neg
    cmp dword [rdx + 16], 0xFFFFFFFF
    jae ufi_ticked
    inc dword [rdx + 16]
    jmp ufi_ticked
ufi_neg:
    cmp dword [rdx + 20], 0xFFFFFFFF
    jae ufi_ticked
    inc dword [rdx + 20]
ufi_ticked:
    inc qword [utick]
    mov eax, dword [utick]
    mov [rdx + 24], eax
    cmp byte [rdx + 30], 0
    jne ufi_done
    mov byte [rdx + 30], 1
    push rdx                    ; slot spill (u64_dec clobbers rdx)
    mov rax, [rsp + 24]         ; rowid (stack: slot+0 rdi+8 rsi+16 rdx+24 rcx+32 rbx+40)
    lea rdi, [uqnum]
    call u64_dec
    mov rcx, rdx
    lea rsi, [uqnum]
    mov rdi, [rsp + 8]
    pop rdx
    call uenqueue
    jmp ufi_done
ufi_tick:
    inc qword [utick]
    mov eax, dword [utick]
    mov [rdx + 24], eax
    mov word [rdx + 28], 0
    mov byte [rdx + 30], 1
    mov byte [rdx + 31], 0
    push rdx                    ; slot spill (u64_dec clobbers rdx)
    mov rax, [rsp + 24]         ; rowid (stack: slot+0 rdi+8 rsi+16 rdx+24 rcx+32 rbx+40)
    lea rdi, [uqnum]
    call u64_dec
    mov rcx, rdx
    lea rsi, [uqnum]
    mov rdi, [rsp + 8]
    pop rdx
    call uenqueue
ufi_done:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret
; rsi=rowid): reinforcement (new version under a stable identity):
; conf++ sat, tick. Same preserve contract.
use_conf_name:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    mov qword [udirty], 1
    push rsi
    push rdx
    call ukey_name
    pop rdx
    pop rsi
    call ufind
    test rax, rax
    jnz ucn_hit
    mov [rdx], rbx
    mov [rdx + 8], r8d
    mov dword [rdx + 12], 0
    mov dword [rdx + 16], 0
    mov dword [rdx + 20], 0
    inc qword [utick]
    mov eax, dword [utick]
    mov [rdx + 24], eax
    mov word [rdx + 28], 1
    mov byte [rdx + 30], 1
    mov byte [rdx + 31], 0
    mov rsi, [rsp + 8]
    mov rcx, [rsp + 16]
    mov rdi, [rsp]
    call uenqueue
    jmp ucn_done
ucn_hit:
    cmp word [rdx + 28], 0xFFFF
    jae ucn_ticked
    inc word [rdx + 28]
ucn_ticked:
    inc qword [utick]
    mov eax, dword [utick]
    mov [rdx + 24], eax
    cmp byte [rdx + 30], 0
    jne ucn_done
    mov byte [rdx + 30], 1
    mov rsi, [rsp + 8]
    mov rcx, [rsp + 16]
    mov rdi, [rsp]
    call uenqueue
ucn_done:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret
use_conf_id:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    mov qword [udirty], 1
    call ukey_rowid
    call ufind
    test rax, rax
    jnz uci_hit
    mov [rdx], rbx
    mov [rdx + 8], r8d
    mov dword [rdx + 12], 0
    mov dword [rdx + 16], 0
    mov dword [rdx + 20], 0
    inc qword [utick]
    mov eax, dword [utick]
    mov [rdx + 24], eax
    mov word [rdx + 28], 1
    mov byte [rdx + 30], 1
    mov byte [rdx + 31], 0
    jmp uci_enq
uci_hit:
    cmp word [rdx + 28], 0xFFFF
    jae uci_ticked
    inc word [rdx + 28]
uci_ticked:
    inc qword [utick]
    mov eax, dword [utick]
    mov [rdx + 24], eax
    cmp byte [rdx + 30], 0
    jne uci_done
    mov byte [rdx + 30], 1
uci_enq:
    push rdx
    mov rax, [rsp + 16]         ; rowid (stack: slot+0 rdi+8 rsi+16 rdx+24 rcx+32 rbx+40)
    lea rdi, [uqnum]
    call u64_dec
    mov rcx, rdx
    lea rsi, [uqnum]
    mov rdi, [rsp + 8]
    pop rdx
    call uenqueue
uci_done:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; use_setmax_full(rbx=key, rdi=kind, rsi=nameptr, rdx=namelen): load-time
; merge from [ulh2],[ulacc],[ulpos],[ulneg],[ullast],[ulconf] (per-signal
; max). A slot goes dirty only when the merged vector is novel, i.e. some
; stored field exceeds the row just read (merged != row means no single
; table row holds the merge, so it must be persisted). Dirty 0->1 also
; enqueues (slot,name) for flush. Preserves rbx,rcx,rdx,rsi,rdi,r12-r15.
use_setmax_full:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r10
    push r11
    mov r8d, dword [ulh2]
    call ufind                   ; rdx=slot rax=hit
    test rax, rax
    jnz usm_hit
    mov [rdx], rbx
    mov eax, dword [ulh2]
    mov [rdx + 8], eax
    mov eax, dword [ulacc]
    mov [rdx + 12], eax
    mov eax, dword [ulpos]
    mov [rdx + 16], eax
    mov eax, dword [ulneg]
    mov [rdx + 20], eax
    mov eax, dword [ullast]
    mov [rdx + 24], eax
    mov ax, word [ulconf]
    mov [rdx + 28], ax
    mov byte [rdx + 30], 0      ; row exists in table: in sync
    mov byte [rdx + 31], 0
    mov rax, [ullast]
    cmp rax, [utick]
    jbe usm_done
    mov [utick], rax            ; resume tick past persisted recency
    jmp usm_done
usm_hit:
    xor r10d, r10d              ; novel flag
    mov eax, dword [ulacc]
    cmp eax, [rdx + 12]
    jae usm_a
    mov r10d, 1
    jmp usm_b
usm_a:
    mov [rdx + 12], eax
usm_b:
    mov eax, dword [ulpos]
    cmp eax, [rdx + 16]
    jae usm_c
    mov r10d, 1
    jmp usm_d
usm_c:
    mov [rdx + 16], eax
usm_d:
    mov eax, dword [ulneg]
    cmp eax, [rdx + 20]
    jae usm_e
    mov r10d, 1
    jmp usm_f
usm_e:
    mov [rdx + 20], eax
usm_f:
    mov eax, dword [ullast]
    cmp eax, [rdx + 24]
    jae usm_g
    mov r10d, 1
    jmp usm_h
usm_g:
    mov [rdx + 24], eax
usm_h:
    mov ax, word [ulconf]
    cmp ax, [rdx + 28]
    jae usm_i
    mov r10d, 1
    jmp usm_j
usm_i:
    mov [rdx + 28], ax
usm_j:
    mov rax, [ullast]
    cmp rax, [utick]
    jbe usm_k
    mov [utick], rax
usm_k:
    test r10d, r10d
    jz usm_done
    cmp byte [rdx + 30], 0
    jne usm_done
    mov byte [rdx + 30], 1
    mov rsi, [rsp + 24]         ; name (stack: r11+0 r10+8 rdi+16 rsi+24 rdx+32 rcx+40 rbx+48)
    mov rcx, [rsp + 32]         ; namelen
    mov rdi, [rsp + 16]         ; kind
    call uenqueue
usm_done:
    pop r11
    pop r10
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; use_load: one-time load of usage rows into utab (insert-or-max). Db must be
; open+locked with tables ensured. Best effort, always returns 0.
use_load:
    cmp qword [uloaded], 0
    jne ul_isdone
    push rbx
    push r12
    push r13
    push r14
    mov rdi, [f_root_use]
    call walk_leaves
    test rax, rax
    jnz ul_fin
    xor r14d, r14d
ul_page:
    cmp r14, [childn]
    jae ul_fin
    lea rsi, [childtab]
    mov rax, r14
    shl rax, 3
    add rsi, rax
    mov rdi, [rsi]
    lea rsi, [pagebuf]
    call pg_read_nc
    test rax, rax
    jnz ul_next
    cmp byte [pagebuf], 0x0D
    jne ul_next
    lea rsi, [pagebuf + 3]
    call be16_ld
    mov rbx, rax
    xor r13d, r13d
ul_cell:
    cmp r13, rbx
    jae ul_next
    lea rsi, [pagebuf + 8]
    mov rax, r13
    shl rax, 1
    add rsi, rax
    call be16_ld
    lea rsi, [pagebuf]
    add rsi, rax
    call parse_row
    test rax, rax
    jnz ul_incc
    mov rax, [gcols]
    cmp rax, 8
    je ul_v2
    cmp rax, 2
    je ul_legacy
    jmp ul_incc
ul_v2:
    ; (name, kind, access, pos, neg, last, conf, v): v ignored, shape is it.
    mov rsi, qword [gfo]
    mov rdx, qword [gfl]
    cmp rdx, 1
    jb ul_incc
    cmp rdx, 128
    ja ul_incc
    mov [ulname], rsi
    mov [ulnamelen], rdx
    mov rsi, qword [gfo + 8]
    mov rdx, qword [gfl + 8]
    call dec_parse
    test rax, rax
    jnz ul_incc
    cmp rdx, 3
    ja ul_incc
    mov [ulkind], rdx
    mov rsi, qword [gfo + 16]
    mov rdx, qword [gfl + 16]
    call dec_parse
    test rax, rax
    jnz ul_incc
    mov rax, rdx
    shr rax, 32
    jz ulv_a
    mov rdx, 0xFFFFFFFF
ulv_a:
    mov [ulacc], rdx
    mov rsi, qword [gfo + 24]
    mov rdx, qword [gfl + 24]
    call dec_parse
    test rax, rax
    jnz ul_incc
    mov rax, rdx
    shr rax, 32
    jz ulv_b
    mov rdx, 0xFFFFFFFF
ulv_b:
    mov [ulpos], rdx
    mov rsi, qword [gfo + 32]
    mov rdx, qword [gfl + 32]
    call dec_parse
    test rax, rax
    jnz ul_incc
    mov rax, rdx
    shr rax, 32
    jz ulv_c
    mov rdx, 0xFFFFFFFF
ulv_c:
    mov [ulneg], rdx
    mov rsi, qword [gfo + 40]
    mov rdx, qword [gfl + 40]
    call dec_parse
    test rax, rax
    jnz ul_incc
    mov rax, rdx
    shr rax, 32
    jz ulv_d
    mov rdx, 0xFFFFFFFF
ulv_d:
    mov [ullast], rdx
    mov rsi, qword [gfo + 48]
    mov rdx, qword [gfl + 48]
    call dec_parse
    test rax, rax
    jnz ul_incc
    cmp rdx, 0xFFFF
    jbe ulv_e
    mov rdx, 0xFFFF
ulv_e:
    mov [ulconf], rdx
    cmp qword [ulkind], 1
    je ulv_obs
    push rbx
    mov rdi, [ulkind]
    mov rsi, [ulname]
    mov rdx, [ulnamelen]
    call ukey_name
    mov dword [ulh2], r8d
    mov rdi, [ulkind]
    mov rsi, [ulname]
    mov rdx, [ulnamelen]
    call use_setmax_full         ; rbx=key preserved across call
    pop rbx
    jmp ul_incc
ulv_obs:
    mov rsi, [ulname]
    mov rdx, [ulnamelen]
    call dec_parse               ; decimal rowid identity
    test rax, rax
    jnz ul_incc
    test rdx, rdx
    jz ul_incc
    push rbx
    mov rsi, rdx
    mov rdi, 1
    call ukey_rowid
    mov dword [ulh2], r8d
    mov rdi, 1
    mov rsi, [ulname]
    mov rdx, [ulnamelen]
    call use_setmax_full
    pop rbx
    jmp ul_incc
ul_legacy:
    ; (ukey, hits): ukey = kind<<56 | rowid. Resolve names for string
    ; kinds via rowid->name scan; observations keep rowid identity.
    ; Unresolvable rows are skipped (documented): their learning died
    ; with the row, never merged into another memory.
    mov rsi, qword [gfo]
    mov rdx, qword [gfl]
    call dec_parse
    test rax, rax
    jnz ul_incc
    test rdx, rdx
    jz ul_incc
    mov [ulkey], rdx
    mov rsi, qword [gfo + 8]
    mov rdx, qword [gfl + 8]
    call dec_parse
    test rax, rax
    jnz ul_incc
    mov rax, rdx
    shr rax, 32
    jz ull_h
    mov rdx, 0xFFFFFFFF
ull_h:
    mov [ulhits], rdx
    mov rax, [ulkey]
    shr rax, 56
    cmp rax, 2
    ja ul_incc                   ; kinds 0..2 only (3 never existed)
    mov [ulkind], rax
    mov rax, [ulkey]
    shl rax, 8
    shr rax, 8
    test rax, rax
    jz ul_incc
    cmp qword [ulkind], 1
    je ull_obs
    push rbx
    mov rsi, rax                ; rowid for rname_of
    mov rdx, [childn]
    cmp rdx, 65536
    jbe ull_rn
    mov rdx, 65536
ull_rn:
    cmp qword [ulkind], 0
    je ull_ent
    mov rdi, [f_root_facts]
    jmp ull_do
ull_ent:
    mov rdi, [f_root_ent]
ull_do:
    call rname_of                ; rsnbuf/rsnlen or miss
    test rax, rax
    jz ull_miss
    jmp ull_named
ull_miss:
    pop rbx
    jmp ul_incc
ull_named:
    mov rax, [ulhits]
    mov [ulacc], rax
    mov qword [ulpos], 0
    mov qword [ulneg], 0
    mov qword [ullast], 0
    mov qword [ulconf], 0
    mov rdi, [ulkind]
    lea rsi, [rnbuf]
    mov rdx, [rnlen]
    call ukey_name
    mov dword [ulh2], r8d
    mov rdi, [ulkind]
    lea rsi, [rnbuf]
    mov rdx, [rnlen]
    call use_setmax_full
    pop rbx
    jmp ul_incc
ull_obs:
    mov rax, [ulhits]
    mov [ulacc], rax
    mov qword [ulpos], 0
    mov qword [ulneg], 0
    mov qword [ullast], 0
    mov qword [ulconf], 0
    push rbx
    mov rax, [ulkey]
    shl rax, 8
    shr rax, 8
    mov rsi, rax
    mov rdi, 1
    call ukey_rowid
    mov dword [ulh2], r8d
    lea rdi, [uqnum]
    call u64_dec                 ; decimal rowid name (loader-safe temp)
    mov [ulnamelen], rdx
    lea rax, [uqnum]
    mov [ulname], rax
    mov rdi, 1
    mov rsi, [ulname]
    mov rdx, [ulnamelen]
    call use_setmax_full
    pop rbx
    jmp ul_incc
ul_incc:
    inc r13
    jmp ul_cell
ul_next:
    inc r14
    jmp ul_page
ul_fin:
    mov qword [uloaded], 1
    pop r14
    pop r13
    pop r12
    pop rbx
ul_isdone:
    xor eax, eax
    ret
; rname_of(rdi=root, rsi=rowid, rdx=save_count): rax=1 + rnbuf/rnlen
; (col0, <=64B) or 0 miss. Saves/restores childtab[0..save_count) and
; childn across its own walk_leaves (callers may hold a live walk).
; Uses a PRIVATE name buffer: rsnbuf belongs to request handlers and
; must survive db_open (use_load runs resolvers during open).
; Preserves rbx,r12-r15.
rname_of:
    push rbx
    push r12
    push r13
    push r14
    push r15
    push rdi
    mov [rntarget], rsi         ; target rowid in memory (all regs reused below)
    mov r12, rdx                ; save count
    mov [rnsave], r12
    mov rax, [childn]
    mov [chsaven], rax
    lea rsi, [childtab]
    lea rdi, [chsave]
    mov rcx, r12
    rep movsq
    lea rsi, [pagebuf]          ; loader may hold a live page here
    lea rdi, [rnpsave]
    mov rcx, 512
    rep movsq
    pop rdi
    call walk_leaves
    test rax, rax
    jnz rn_miss
    xor r14d, r14d
rn_page:
    cmp r14, [childn]
    jae rn_miss
    lea rsi, [childtab]
    mov rax, r14
    shl rax, 3
    add rsi, rax
    mov rdi, [rsi]
    lea rsi, [pagebuf]
    call pg_read_nc
    test rax, rax
    jnz rn_next
    cmp byte [pagebuf], 0x0D
    jne rn_next
    lea rsi, [pagebuf + 3]
    call be16_ld
    mov [rnncell], rax
    xor r13d, r13d
rn_cell:
    mov rax, [rnncell]
    cmp r13, rax
    jae rn_next
    lea rsi, [pagebuf + 8]
    mov rax, r13
    shl rax, 1
    add rsi, rax
    call be16_ld
    lea rsi, [pagebuf]
    add rsi, rax
    call parse_row
    test rax, rax
    jnz rn_incc
    mov rax, [growid]
    cmp rax, [rntarget]
    jne rn_incc
    mov rsi, qword [gfo]
    mov rcx, qword [gfl]
    cmp rcx, 1
    jb rn_incc
    cmp rcx, 128
    ja rn_incc
    lea rdi, [rnbuf]
    mov rax, rcx
    rep movsb
    mov [rnlen], rax
    mov eax, 1
    jmp rn_restore
rn_incc:
    inc r13
    jmp rn_cell
rn_next:
    inc r14
    jmp rn_page
rn_miss:
    xor eax, eax
rn_restore:
    push rax
    lea rsi, [rnpsave]
    lea rdi, [pagebuf]
    mov rcx, 512
    rep movsq
    mov rcx, [rnsave]
    lea rsi, [chsave]
    lea rdi, [childtab]
    rep movsq
    mov rax, [chsaven]
    mov [childn], rax
    pop rax
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; use_flush: persist changed slots as new usage rows (rewrite-the-slot on next
; load via latest/max rule). Db must be open+locked. Saves/restores op state.
; rax 0 ok / 1 err. Best effort: callers ignore status.
use_flush:
    mov rax, [newrowid]
    mov qword [svstate], rax
    mov rax, [maxrowid]
    mov qword [svstate + 8], rax
    mov rax, [splitroot]
    mov qword [svstate + 16], rax
    mov rax, [ncols]
    mov qword [svstate + 24], rax
    lea rsi, [colp]
    lea rdi, [svstate + 32]
    mov ecx, 8
    rep movsq
    lea rsi, [coll]
    lea rdi, [svstate + 96]
    mov ecx, 8
    rep movsq
    lea rsi, [gfo]
    lea rdi, [svstate + 160]
    mov ecx, 8
    rep movsq
    lea rsi, [gfl]
    lea rdi, [svstate + 224]
    mov ecx, 8
    rep movsq
    ; Fresh usage high-water mark: the shared [maxrowid] may hold another
    ; table's max (every op refreshes it for its own table) or a pre-flush
    ; value, so bare ++[maxrowid] rowids can collide with existing usage
    ; rows (duplicates) or land below the true max (out-of-order cells).
    ; O(depth) rightmost descent; also primes dstack for the right-edge
    ; place_cell calls below. Failure here wrote nothing, so the normal
    ; abort path (which restores the untouched counter) stays correct.
    mov rdi, [f_root_use]
    call tail_max
    test rax, rax
    jnz uf_abort
uf_slot:
    mov rax, [uq_head]
    cmp rax, [uq_tail]
    je uf_done
    imul rax, rax, UQ_ENT_SZ
    lea rbx, [uqueue]
    add rbx, rax                ; rbx = entry
    mov eax, [rbx]              ; slot idx
    shl rax, 5
    lea rdx, [utab]
    add rdx, rax                ; rdx = slot
    cmp byte [rdx + 30], 0
    je uf_adv                   ; clean already: skip (defensive)
    push rbx
    push rdx
    movzx edi, byte [rbx + 4]   ; kind
    lea rsi, [rbx + 8]          ; name
    movzx edx, byte [rbx + 5]   ; len
    call ukey_name              ; rbx=key r8d=h2 (entry/slot spilled)
    mov r10, rbx
    mov r11d, r8d
    pop rdx
    pop rbx
    cmp r10, [rdx]
    jne uf_adv                   ; slot reused since enqueue: stale entry
    cmp r11d, [rdx + 8]
    jne uf_adv
    mov eax, [rdx + 12]
    mov [ulacc], rax
    mov eax, [rdx + 16]
    mov [ulpos], rax
    mov eax, [rdx + 20]
    mov [ulneg], rax
    mov eax, [rdx + 24]
    mov [ullast], rax
    movzx eax, word [rdx + 28]
    mov [ulconf], rax
    push rdx                    ; slot spill (u64_dec clobbers rdx)
    lea rax, [rbx + 8]
    mov qword [colp], rax
    movzx eax, byte [rbx + 5]
    mov qword [coll], rax
    movzx eax, byte [rbx + 4]
    lea rdi, [ukind1]
    call u64_dec
    lea rax, [ukind1]
    mov qword [colp + 8], rax
    mov qword [coll + 8], rdx
    mov eax, dword [ulacc]
    lea rdi, [unum0]
    call u64_dec
    lea rax, [unum0]
    mov qword [colp + 16], rax
    mov qword [coll + 16], rdx
    mov eax, dword [ulpos]
    lea rdi, [unum1]
    call u64_dec
    lea rax, [unum1]
    mov qword [colp + 24], rax
    mov qword [coll + 24], rdx
    mov eax, dword [ulneg]
    lea rdi, [unum2]
    call u64_dec
    lea rax, [unum2]
    mov qword [colp + 32], rax
    mov qword [coll + 32], rdx
    mov eax, dword [ullast]
    lea rdi, [unum3]
    call u64_dec
    lea rax, [unum3]
    mov qword [colp + 40], rax
    mov qword [coll + 40], rdx
    movzx eax, word [ulconf]
    lea rdi, [unum4]
    call u64_dec
    lea rax, [unum4]
    mov qword [colp + 48], rax
    mov qword [coll + 48], rdx
    lea rax, [uv2]
    mov qword [colp + 56], rax
    mov qword [coll + 56], 1
    mov qword [ncols], 8
    mov rax, [maxrowid]
    inc rax
    mov [newrowid], rax
    mov [maxrowid], rax
    call build_record_text
    mov rax, [f_root_use]
    mov [splitroot], rax
    call place_cell
    test rax, rax
    jnz uf_poabort
    pop rdx
    mov byte [rdx + 30], 0
uf_adv:
    inc qword [uq_head]
    and qword [uq_head], UQ_MASK
    jmp uf_slot
uf_poabort:
    pop rdx
    jmp uf_abort
uf_done:
    call hdr_touch
    test rax, rax
    jnz uf_abort
    mov qword [udirty], 0
    mov rax, [maxrowid]
    mov qword [svstate + 8], rax   ; keep the advanced high-water mark:
    push rax                       ; the shared restore below must not
    jmp uf_restore                 ; revert it to the pre-flush value
uf_abort:
    ; Placed rows persist (the piggyback commits with the outer txn, and
    ; the exit path commits too), so the pre-flush counter must not come
    ; back: re-sync to the true max. If the re-sync itself fails the tree
    ; is unreadable and the stale value is no worse.
    mov rdi, [f_root_use]
    call tail_max
    test rax, rax
    jnz uf_abortkeep
    mov rax, [maxrowid]
    mov qword [svstate + 8], rax
uf_abortkeep:
    push rax
    mov rax, 1
    mov [rsp], rax
uf_restore:
    lea rsi, [svstate + 224]
    lea rdi, [gfl]
    mov ecx, 8
    rep movsq
    lea rsi, [svstate + 160]
    lea rdi, [gfo]
    mov ecx, 8
    rep movsq
    lea rsi, [svstate + 96]
    lea rdi, [coll]
    mov ecx, 8
    rep movsq
    lea rsi, [svstate + 32]
    lea rdi, [colp]
    mov ecx, 8
    rep movsq
    mov rax, qword [svstate + 24]
    mov [ncols], rax
    mov rax, qword [svstate + 16]
    mov [splitroot], rax
    mov rax, qword [svstate + 8]
    mov [maxrowid], rax
    mov rax, qword [svstate]
    mov [newrowid], rax
    pop rax
    ret

; use_flush_exit: best-effort persist at clean process exit.
use_flush_exit:
    cmp qword [udirty], 0
    je ufe_ret
    call db_open_ex
    test rax, rax
    jnz ufe_ret
    call use_flush
    call db_close
ufe_ret:
    ret

; u64_dec(rax=value, rdi=dst): decimal, no sign. rdx=len. Clobbers rax,rcx,rdx.
u64_dec:
    push rbx
    push r8
    lea rbx, [udec + 24]
    mov r8, rdi
    mov rcx, 10
    test rax, rax
    jnz ud_loop
    mov byte [rdi], '0'
    mov edx, 1
    pop r8
    pop rbx
    ret
ud_loop:
    xor edx, edx
    div rcx
    add dl, '0'
    dec rbx
    mov [rbx], dl
    test rax, rax
    jnz ud_loop
    lea rax, [udec + 24]
    sub rax, rbx
    mov rdx, rax                ; len
    mov rsi, rbx
    mov rdi, r8
    mov rcx, rdx
    rep movsb
    pop r8
    pop rbx
    ret

; dec_parse(rsi=ptr, rdx=len): rdx=value, rax 0 ok / 1 bad. Nonneg, <=2^63-1.
dec_parse:
    test rdx, rdx
    jz dp_bad
    cmp rdx, 19
    ja dp_bad
    xor eax, eax                ; value in rax
dp_loop:
    test rdx, rdx
    jz dp_ok
    movzx ecx, byte [rsi]
    sub cl, '0'
    cmp cl, 9
    ja dp_bad
    movzx ecx, cl
    imul rax, rax, 10
    jb dp_bad
    add rax, rcx
    jb dp_bad
    inc rsi
    dec rdx
    jmp dp_loop
dp_ok:
    mov rdx, rax
    xor eax, eax
    ret
dp_bad:
    mov eax, 1
    ret

; pg_read_nc(rdi=pgno, rsi=buf): probe, else pread. No fill (scan paths).
pg_read_nc:
    push rdi
    push rsi
    call cache_probe
    test rax, rax
    pop rsi
    pop rdi
    jz pgr_ok
    mov r10, rdi
    dec r10
    shl r10, 12
    mov rdi, [dbfd]
    mov edx, 4096
    mov eax, 17
    syscall
    cmp rax, 4096
    je pgr_ok
    mov eax, 1
    ret
pgr_ok:
    xor eax, eax
    ret

; pg_read(rdi=pgno, rsi=buf): rax 0 ok / 1 err. Cache-served, fills on miss.
pg_read:
    push rbx
    mov rbx, rdi                ; pgno
    push rdi
    push rsi
    call cache_probe
    test rax, rax
    pop rsi
    pop rdi
    jz pgr_hit
    mov r10, rbx
    dec r10
    shl r10, 12
    mov rdi, [dbfd]
    mov edx, 4096
    mov eax, 17
    syscall
    cmp rax, 4096
    jne pgr_err
    mov rdi, rbx
    call cache_fill             ; rsi still buf
    pop rbx
    xor eax, eax
    ret
pgr_hit:
    pop rbx
    xor eax, eax
    ret
pgr_err:
    pop rbx
    mov eax, 1
    ret

; pg_write(rdi=pgno, rsi=buf): rax 0 ok / 1 err. Journals pre-image first,
; write-throughs the page cache on success.
pg_write:
    push rbx
    mov rbx, rdi                ; pgno
    push rdi
    push rsi
    call jwrite
    pop rsi
    pop rdi
    test rax, rax
    jnz pgw_err
    cmp byte [rsi], 0x05
    jne pg_wgo
    call chk_interior           ; never commit a corrupt interior
    test rax, rax
    jnz pgw_err
pg_wgo:
    mov r10, rbx
    dec r10
    shl r10, 12
    mov rdi, [dbfd]
    mov edx, 4096
    mov eax, 18
    syscall
    cmp rax, 4096
    jne pgw_err
    mov rdi, rbx
    call cache_fill             ; rsi still buf
    pop rbx
    xor eax, eax
    ret
pgw_ok:
    pop rbx
    xor eax, eax
    ret
pgw_err:
    pop rbx
    mov eax, 1
    ret

; chk_interior(rsi=page): rax 0 ok / 1 bad. Validates every divider child
; (1..dbpages+2) and key encoding. Guards every interior commit.
; Preserves rbx,rbp,r12-r15,rsi,rdi.
chk_interior:
    push rbx
    push r12
    push r13
    push r14
    push rsi
    mov rbx, rsi
    lea rsi, [rbx + 3]
    call be16_ld
    cmp rax, 1022
    ja ci_bad
    mov r12, rax
    xor r13d, r13d
    mov r14, [dbpages]
    add r14, 2
ci_cell:
    cmp r13, r12
    jae ci_right
    lea rsi, [rbx + 12]
    mov rax, r13
    shl rax, 1
    add rsi, rax
    call be16_ld
    cmp rax, 4092
    ja ci_bad
    lea rsi, [rbx]
    add rsi, rax
    mov eax, [rsi]                  ; child BE32 pre-check bytes present
    lea rdx, [rbx + 4096]
    sub rdx, rsi
    cmp rdx, 5
    jb ci_bad
    call be32_ld
    test rax, rax
    jz ci_bad
    cmp rax, r14
    ja ci_bad
    add rsi, 4
    lea rdx, [rbx + 4096]
    call varint_get
    test rcx, rcx
    jz ci_bad
    inc r13
    jmp ci_cell
ci_right:
    lea rsi, [rbx + 8]
    call be32_ld
    test rax, rax
    jz ci_bad
    cmp rax, r14
    ja ci_bad
    pop rsi
    pop r14
    pop r13
    pop r12
    pop rbx
    xor eax, eax
    ret
ci_bad:
    pop rsi
    pop r14
    pop r13
    pop r12
    pop rbx
    mov eax, 1
    ret

; jwrite(rdi=pgno): journal current on-disk image before overwrite.
; Appends [pgno u32][4096B] + fsyncs journal. rax 0 ok / 1 err.
; Preserves rbx,rbp,r12-r15,rsi.
jwrite:
    push rbx
    push r12
    push rsi
    mov rbx, rdi                ; pgno
    ; already journaled?
    xor ecx, ecx
jw_scan:
    cmp rcx, [jn]
    jae jw_new
    lea rax, [jpages]
    shl rcx, 3
    add rax, rcx
    shr rcx, 3
    cmp qword [rax], rbx
    je jw_ok
    inc rcx
    jmp jw_scan
jw_new:
    cmp qword [jn], 32
    jae jw_err                  ; txn too wide: fail closed
    cmp qword [jactive], 0
    jne jw_have
    ; first touch: open journal (0600) + header
    mov eax, 2
    lea rdi, [jpath]
    mov esi, 66                 ; O_RDWR|O_CREAT
    mov edx, 384
    syscall
    test rax, rax
    js jw_err
    mov [jfd], rax
    mov eax, 91                 ; fchmod 0600
    mov rdi, [jfd]
    mov esi, 384
    syscall
    test rax, rax
    js jw_err
    lea rdi, [jbuf]
    mov al, 'T'
    mov [rdi], al
    mov al, 'J'
    mov [rdi + 1], al
    mov al, 'R'
    mov [rdi + 2], al
    mov al, 'R'
    mov [rdi + 3], al
    mov rax, [dbpages]
    mov [jorig], rax
    mov rax, [jorig]
    lea rdi, [jbuf + 4]
    call be32_st
    mov eax, 1
    mov rdi, [jfd]
    lea rsi, [jbuf]
    mov edx, 8
    syscall
    cmp rax, 8
    jne jw_err
    mov qword [jactive], 1
jw_have:
    ; pre-image of pgno into jbuf (zeros if beyond EOF)
    mov eax, 0
    mov rdi, [dbfd]
    lea rsi, [jbuf]
    mov edx, 4096
    mov r10, rbx
    dec r10
    shl r10, 12
    mov eax, 17
    syscall
    test rax, rax
    js jw_err
    cmp rax, 4096
    je jw_full
    ; short read: zero the tail
    lea rdi, [jbuf]
    add rdi, rax
    mov rcx, 4096
    sub rcx, rax
    xor eax, eax
    rep stosb
jw_full:
    ; append [pgno u32][page]: sequential position (single writer under flock)
    mov rax, rbx
    lea rdi, [jbuf2]
    call be32_st
    mov eax, 1
    mov rdi, [jfd]
    lea rsi, [jbuf2]
    mov edx, 4
    syscall
    cmp rax, 4
    jne jw_err
    mov eax, 1
    mov rdi, [jfd]
    lea rsi, [jbuf]
    mov edx, 4096
    syscall
    cmp rax, 4096
    jne jw_err
    mov eax, 74                   ; fsync journal before the data write
    mov rdi, [jfd]
    syscall
    test rax, rax
    js jw_err
    lea rax, [jpages]
    mov rcx, [jn]
    shl rcx, 3
    add rax, rcx
    mov [rax], rbx
    inc qword [jn]
jw_ok:
    pop rsi
    pop r12
    pop rbx
    xor eax, eax
    ret
jw_err:
    pop rsi
    pop r12
    pop rbx
    mov eax, 1
    ret

; pg_write_fd(rdi=pgno, rsi=buf, rdx=fd): rax 0 ok / 1 err. No journal.
; Direct pwrite for tmp-create. Clobbers rax,rcx,rdi,rdx,r10,r11.
pg_write_fd:
    push r10
    mov r10, rdi
    dec r10
    shl r10, 12
    mov rdi, rdx
    mov edx, 4096
    mov eax, 18
    syscall
    pop r10
    cmp rax, 4096
    je pgfd_ok
    mov eax, 1
    ret
pgfd_ok:
    xor eax, eax
    ret

; jrecover: rollback torn txn if journal file exists. Called after flock.
; Reads [jpath], restores pre-images to [dbfd], truncates to orig pages,
; fsyncs, unlinks + dirsync. rax 0 ok / 1 err. Preserves rbx,rbp,r12-r15.
jrecover:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov eax, 2
    lea rdi, [jpath]
    xor esi, esi                ; O_RDONLY
    xor edx, edx
    syscall
    test rax, rax
    js jrc_none                  ; no journal: nothing to do
    mov r14, rax                ; journal fd
    mov rdi, r14
    lea rsi, [jbuf]
    mov edx, 8
    call read_all
    cmp rax, 8
    jne jrc_drop                 ; torn header: db untouched, drop journal
    cmp byte [jbuf], 'T'
    jne jrc_drop
    cmp byte [jbuf+1], 'J'
    jne jrc_drop
    cmp byte [jbuf+2], 'R'
    jne jrc_drop
    cmp byte [jbuf+3], 'R'
    jne jrc_drop
    lea rsi, [jbuf+4]
    call be32_ld
    mov r15, rax                ; orig pages
    cmp r15, 0x100000
    ja jrc_drop                  ; absurd: drop
jrc_next:
    mov rdi, r14
    lea rsi, [jbuf2]
    mov edx, 4
    call read_all
    test rax, rax
    jz jrc_commit                ; clean EOF
    cmp rax, 4
    jne jrc_commit               ; torn tail: rollback what we have
    lea rsi, [jbuf2]
    call be32_ld
    mov r12, rax                ; pgno
    test r12, r12
    jz jrc_commit                ; pgno 0: torn, stop
    cmp r12, 0x100000
    ja jrc_commit
    mov rdi, r14
    lea rsi, [jbuf]
    mov edx, 4096
    call read_all
    cmp rax, 4096
    jne jrc_commit               ; torn page tail: ignore, rollback prior
    mov rax, r12
    dec rax
    shl rax, 12
    mov r10, rax
    mov rdi, [dbfd]
    lea rsi, [jbuf]
    mov edx, 4096
    mov eax, 18
    syscall
    cmp rax, 4096
    jne jrc_err
    jmp jrc_next
jrc_commit:
    mov eax, 74                 ; fsync restored pages
    mov rdi, [dbfd]
    syscall
    mov rax, r15
    shl rax, 12
    mov rsi, rax                ; len = orig*4096
    mov eax, 77                 ; ftruncate back (drops grown tail)
    mov rdi, [dbfd]
    syscall
    mov eax, 74
    mov rdi, [dbfd]
    syscall
    mov eax, 3
    mov rdi, r14
    syscall
    mov eax, 87
    lea rdi, [jpath]
    syscall
    call dirsync
    mov qword [jn], 0
    mov qword [jactive], 0
    mov qword [jfd], 0
    mov qword [jorig], 0
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    xor eax, eax
    ret
jrc_drop:
    mov eax, 3
    mov rdi, r14
    syscall
    mov eax, 87
    lea rdi, [jpath]
    syscall
    call dirsync
jrc_none:
    mov qword [jn], 0
    mov qword [jactive], 0
    mov qword [jfd], 0
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    xor eax, eax
    ret
jrc_err:
    mov eax, 3
    mov rdi, r14
    syscall
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    mov eax, 1
    ret

; magic_ok(rsi=page): rax 0 ok / 1 bad
magic_ok:
    push rsi
    lea rdi, [dbmagic]
    mov ecx, 16
    rep cmpsb
    pop rsi
    jne mg_bad
    movzx eax, byte [rsi + 16]
    cmp al, 0x10
    jne mg_bad
    cmp byte [rsi + 17], 0
    jne mg_bad
    xor eax, eax
    ret
mg_bad:
    mov eax, 1
    ret

; db_open: path, open+lock, validate or create. rax 0 ok / 1 err.
; jhave: rax 1 if a journal file exists (crashed writer leftovers), else 0.
; Preserves rbx,rbp,r12-r15.
jhave:
    mov eax, 2
    lea rdi, [jpath]
    xor esi, esi
    xor edx, edx
    syscall
    test rax, rax
    js jh_no
    mov rdi, rax
    mov eax, 3
    syscall
    mov eax, 1
    ret
jh_no:
    xor eax, eax
    ret

; need_create: rax 1 if any memory table is missing (creation needs EX).
; Read-only walk; saves/restores maxrowid/mmaxrowid that find_table touches.
need_create:
    push qword [maxrowid]
    push qword [mmaxrowid]
    lea rsi, [m_conct]
    mov edx, 11
    call find_table
    test rax, rax
    js nc_yes
    jz nc_yes
    lea rsi, [t_facts_n]
    mov edx, 5
    call find_table
    test rax, rax
    js nc_yes
    jz nc_yes
    lea rsi, [t_ent_n]
    mov edx, 8
    call find_table
    test rax, rax
    js nc_yes
    jz nc_yes
    lea rsi, [t_obs_n]
    mov edx, 12
    call find_table
    test rax, rax
    js nc_yes
    jz nc_yes
    lea rsi, [t_rel_n]
    mov edx, 9
    call find_table
    test rax, rax
    js nc_yes
    jz nc_yes
    lea rsi, [t_task_n]
    mov edx, 5
    call find_table
    test rax, rax
    js nc_yes
    jz nc_yes
    lea rsi, [t_use_n]
    mov edx, 5
    call find_table
    test rax, rax
    js nc_yes
    jz nc_yes
    lea rsi, [t_tomb_n]
    mov edx, 10
    call find_table
    test rax, rax
    js nc_yes
    jz nc_yes
    pop qword [mmaxrowid]
    pop qword [maxrowid]
    xor eax, eax
    ret
nc_yes:
    pop qword [mmaxrowid]
    pop qword [maxrowid]
    mov eax, 1
    ret

; is_tombstoned(rsi=name, rdx=len): rax 1 tombstoned / 0 live / 2 corrupt.
; Db must be open (reads tombstones table). Preserves rbx,rbp,r12-r15.
is_tombstoned:
    mov [mkey], rsi
    mov [mkeylen], rdx
    mov rdi, [f_root_tomb]
    call scan_key_latest
    ret

; db_open: shared/read (LOCK_SH). db_open_ex: exclusive/write (LOCK_EX).
; Readers never block each other; any journal/creation/missing-table case
; escalates a reader to EX (UN then EX, never upgrade) before mutating.
db_open:
    xor edi, edi
    jmp do_open_body
db_open_ex:
    mov edi, 1
do_open_body:
    mov [dbwmode], rdi
    mov eax, 89                 ; readlink /proc/self/exe
    lea rdi, [dbexe]
    lea rsi, [exebuf]
    mov edx, 1024
    syscall
    cmp rax, 0
    jle do_cwd
    mov rcx, rax
    lea r10, [exebuf]             ; base in reg: PIE-safe (no label+index)
do_sl:
    dec rcx
    js do_cwd
    cmp byte [r10 + rcx], '/'
    jne do_sl
    inc rcx
    cmp rcx, 1024
    ja do_cwd
    mov [dblen], rcx
    lea rsi, [exebuf]
    lea rdi, [dbpath]
    rep movsb
    lea rsi, [dbfile]
    mov ecx, 12
    rep movsb
    mov byte [rdi], 0
    add qword [dblen], 12
    jmp do_paths
do_cwd:
    lea rsi, [dbfile]
    lea rdi, [dbpath]
    mov ecx, 12
    rep movsb
    mov byte [rdi], 0
    mov qword [dblen], 12
do_paths:
    ; jpath = dbpath + "-journal"; dbdirb = dirname (for dirsync)
    mov rax, [dblen]
    add rax, 8
    cmp rax, 1100
    ja do_err                   ; absurd path: fail closed, no fd yet
    lea rsi, [dbpath]
    lea rdi, [jpath]
    mov rcx, [dblen]
    rep movsb
    mov al, '-'
    stosb
    mov al, 'j'
    stosb
    mov al, 'o'
    stosb
    mov al, 'u'
    stosb
    mov al, 'r'
    stosb
    mov al, 'n'
    stosb
    mov al, 'a'
    stosb
    mov al, 'l'
    stosb
    xor al, al
    stosb
    mov rax, [dblen]
    cmp rax, 12
    je do_dotdir
    sub rax, 12                 ; strip "/tinythink.db"
    lea rsi, [dbpath]
    lea rdi, [dbdirb]
    mov rcx, rax
    rep movsb
    mov byte [rdi], 0
    jmp do_open
do_dotdir:
    lea rdi, [dbdirb]
    mov al, '.'
    stosb
    xor al, al
    stosb
    jmp do_open
do_open:
    mov qword [jn], 0
    mov qword [jactive], 0
    mov qword [jfd], 0
    mov eax, 2
    lea rdi, [dbpath]
    mov esi, 66                 ; O_RDWR|O_CREAT
    mov edx, 384                ; 0600: private store (TT-01)
    syscall
    test rax, rax
    js do_err
    mov [dbfd], rax
    mov eax, 91                 ; fchmod(fd, 0600): existing files too
    mov rdi, [dbfd]
    mov esi, 384
    syscall
    test rax, rax
    js do_closeerr
    cmp qword [dbwmode], 0
    je do_shlock
    mov eax, 73                 ; flock LOCK_EX (writers)
    mov rdi, [dbfd]
    mov esi, 2
    syscall
    test rax, rax
    js do_closeerr
    call jrecover               ; rollback torn txn if journal present
    test rax, rax
    jnz do_closeerr
    jmp do_fstat
do_shlock:
    mov eax, 73                 ; flock LOCK_SH (readers share)
    mov rdi, [dbfd]
    mov esi, 1
    syscall
    test rax, rax
    js do_closeerr
do_fstat:
    mov eax, 5                  ; fstat: st_size @ +48
    mov rdi, [dbfd]
    lea rsi, [dbstat]
    syscall
    test rax, rax
    js do_closeerr
    mov eax, dword [dbstat + 24]
    and eax, 0xFFF              ; permission bits must be exactly 0600
    cmp eax, 384
    jne do_closeerr
    mov eax, 102                ; getuid; file must be ours
    syscall
    mov ecx, eax
    mov eax, dword [dbstat + 28]
    cmp eax, ecx
    jne do_closeerr
    cmp qword [dbwmode], 0
    jne do_guards_done
    ; SH guards: creation / recovery / missing tables need EX
    mov rax, qword [dbstat + 48]
    test rax, rax
    jz do_escalate
    call jhave                  ; stale journal from a crashed writer?
    test rax, rax
    jnz do_escalate
    call need_create            ; any table missing?
    test rax, rax
    jnz do_escalate
do_guards_done:
    ; cache generation: same ino/size/mtime as our last close -> warm
    mov rax, qword [dbstat + 8]
    cmp rax, [cino]
    jne oc_new
    mov rax, qword [dbstat + 48]
    cmp rax, [csize]
    jne oc_new
    mov rax, qword [dbstat + 88]
    cmp rax, [cmtim]
    jne oc_new
    mov rax, qword [dbstat + 96]
    cmp rax, [cmtim + 8]
    jne oc_new
    mov qword [cskip], 1
    jmp oc_checked
oc_new:
    call cache_flush
    mov qword [cskip], 0
oc_checked:
    mov rax, qword [dbstat + 48]
    test rax, rax
    jz do_create
    test rax, 4095
    jnz do_closeerr
    shr rax, 12
    test rax, rax
    jz do_closeerr
    mov [dbpages], rax
    mov edi, 1
    lea rsi, [pagebuf]
    call pg_read
    test rax, rax
    jnz do_closeerr
    lea rsi, [pagebuf]
    call magic_ok
    test rax, rax
    jnz do_closeerr
    ; page count from the HEADER (never beyond the file): a crash between
    ; data writes and the header update leaves a consistent old view.
    lea rsi, [pagebuf + 28]
    call be32_ld
    cmp rax, 2
    jb do_closeerr
    mov r8, rax
    mov rax, qword [dbstat + 48]
    shr rax, 12                   ; file pages (multiple-of-4096 checked)
    cmp r8, rax
    ja do_closeerr                ; header beyond file: corrupt
    mov [dbpages], r8
    lea rsi, [pagebuf + 60]       ; taskseq lives in header user-version
    call be32_ld
    mov [taskseq], rax
    jmp do_ensure
do_create:
    call db_create
    test rax, rax
    jnz do_closeerr
do_ensure:
    cmp qword [cskip], 0        ; warm: roots/maxrowid/taskseq already live
    jne do_cached
    call ensure_tables           ; new tables for old DBs; fills f_root_*
    test rax, rax
    jnz do_closeerr
    mov rdi, 2
    call scan_max                ; conclusions max rowid
    test rax, rax
    jnz do_closeerr
    call use_load               ; learned prefs, once per process (self-guarded)
do_cached:
    xor eax, eax
    ret
; do_escalate: SH holder needs mutation. UN then EX (never upgrade: two
; simultaneous upgraders would deadlock), recover, redo from fstat as EX.
do_escalate:
    mov qword [dbwmode], 1
    mov eax, 73
    mov rdi, [dbfd]
    mov esi, 8
    syscall
    test rax, rax
    js do_closeerr
    mov eax, 73
    mov rdi, [dbfd]
    mov esi, 2
    syscall
    test rax, rax
    js do_closeerr
    call jrecover
    test rax, rax
    jnz do_closeerr
    jmp do_fstat
do_closeerr:
    push rax
    mov eax, 3
    mov rdi, [dbfd]
    syscall
    pop rax
    mov eax, 1
do_err:
    ret

; db_close: commit (fsync, drop journal, dirsync), unlock, close. preserves rax.
db_close:
    push rax
    cmp qword [jactive], 0
    je dc_nojourn               ; read-only: disk untouched, skip fsync
    cmp qword [udirty], 0
    je dc_noflush
    call use_flush              ; piggyback learned prefs into this txn; best effort
dc_noflush:
    mov eax, 74
    mov rdi, [dbfd]
    syscall
    mov eax, 87                 ; unlink journal: commit point
    lea rdi, [jpath]
    syscall
    test rax, rax
    jz dc_unlinked
    ; unlink failed: truncate journal to empty (recovery-safe) + fsync
    mov eax, 77
    mov rdi, [jfd]
    xor esi, esi
    syscall
    mov eax, 74
    mov rdi, [jfd]
    syscall
dc_unlinked:
    call dirsync
    mov eax, 3
    mov rdi, [jfd]
    syscall
    mov qword [jn], 0
    mov qword [jactive], 0
    mov qword [jfd], 0
    mov qword [jorig], 0
dc_nojourn:
    mov eax, 5                  ; re-stat: arm cache identity for next open
    mov rdi, [dbfd]
    lea rsi, [dbstat]
    syscall
    test rax, rax
    js dc_nostat
    mov rax, qword [dbstat + 8]
    mov [cino], rax
    mov rax, qword [dbstat + 48]
    mov [csize], rax
    mov rax, qword [dbstat + 88]
    mov [cmtim], rax
    mov rax, qword [dbstat + 96]
    mov [cmtim + 8], rax
dc_nostat:
    mov eax, 73
    mov rdi, [dbfd]
    mov esi, 8                  ; LOCK_UN
    syscall
    mov eax, 3
    mov rdi, [dbfd]
    syscall
    pop rax
    ret

; dirsync: fsync the db directory (rename/unlink durability). best effort.
; Preserves rbx,rbp,r12-r15.
dirsync:
    push rdi
    push rsi
    push rdx
    push rcx
    mov eax, 2
    lea rdi, [dbdirb]
    mov esi, 0x10000             ; O_RDONLY|O_DIRECTORY
    xor edx, edx
    syscall
    test rax, rax
    js ds_done
    mov rdi, rax
    mov eax, 74
    syscall
    mov eax, 3
    syscall                     ; rdi still dirfd
ds_done:
    pop rcx
    pop rdx
    pop rsi
    pop rdi
    ret

; read_all(rdi=fd, rsi=buf, rdx=len): rax = total bytes read (short ok).
; Preserves rbx,rbp,r12-r15.
read_all:
    push rbx
    push r12
    push r13
    push r14
    mov r14, rdi                ; fd
    mov r12, rsi                ; cursor
    mov rbx, rdx                ; remaining
    mov r13, rdx                ; original len
ra_loop:
    test rbx, rbx
    jz ra_done
    mov rdi, r14
    mov rsi, r12
    mov rdx, rbx
    mov eax, 0
    syscall
    test rax, rax
    jle ra_done                 ; EOF/error: return short
    add r12, rax
    sub rbx, rax
    jmp ra_loop
ra_done:
    mov rax, r13
    sub rax, rbx                ; total = len - remaining
    pop r14
    pop r13
    pop r12
    pop rbx
    ret
memzero:
if defined USE_SCALAR
    xor eax, eax
    rep stosb
    ret
else
    vpxor ymm0, ymm0, ymm0
mz_loop:
    cmp rcx, 128
    jb mz_tail
    VEC_ZERO128 rdi
    add rdi, 128
    sub rcx, 128
    jmp mz_loop
mz_tail:
    xor eax, eax
    rep stosb
    vzeroupper
    ret
end if

; db_create: fresh header + master + empty leaf. rax 0/1.
db_create:
    lea rdi, [pagebuf]
    mov ecx, 4096
    call memzero
    lea rsi, [dbmagic]
    lea rdi, [pagebuf]
    mov ecx, 16
    rep movsb
    mov rax, 4096
    lea rdi, [pagebuf + 16]
    call be16_st
    mov byte [pagebuf + 18], 1
    mov byte [pagebuf + 19], 1
    mov byte [pagebuf + 20], 0
    mov byte [pagebuf + 21], 64
    mov byte [pagebuf + 22], 32
    mov byte [pagebuf + 23], 32
    mov rax, 1
    lea rdi, [pagebuf + 24]
    call be32_st
    mov rax, 2
    lea rdi, [pagebuf + 28]
    call be32_st
    mov rax, 1
    lea rdi, [pagebuf + 40]
    call be32_st
    mov rax, 4
    lea rdi, [pagebuf + 44]
    call be32_st
    mov rax, 0xFFFFF830
    lea rdi, [pagebuf + 48]
    call be32_st
    mov rax, 1
    lea rdi, [pagebuf + 56]
    call be32_st
    mov rax, 1
    lea rdi, [pagebuf + 92]
    call be32_st
    mov rax, 3054000
    lea rdi, [pagebuf + 96]
    call be32_st
    lea rax, [m_conct]
    mov [m_name], rax
    mov qword [m_namelen], 11
    mov qword [m_rootpg], 2
    lea rax, [dbsql]
    mov [m_sql], rax
    mov rax, dbsql_len
    mov [m_sqllen], rax
    mov qword [m_rowid], 1
    call build_master_cell
    test rax, rax
    jnz dbc_err
    ; place cell at top (base 100 for page 1)
    mov rcx, [clen]
    mov rax, 4096
    sub rax, rcx
    mov [wcontent], rax
    lea rsi, [celltmp]
    lea rdi, [pagebuf]
    add rdi, rax
    rep movsb
    mov byte [pagebuf + 100], 0x0D
    xor eax, eax
    lea rdi, [pagebuf + 101]
    call be16_st
    mov rax, 1
    lea rdi, [pagebuf + 103]
    call be16_st
    mov rax, [wcontent]
    lea rdi, [pagebuf + 105]
    call be16_st
    mov byte [pagebuf + 107], 0
    mov rax, [wcontent]
    lea rdi, [pagebuf + 108]
    call be16_st
    mov edi, 1
    lea rsi, [pagebuf]
    call pg_write
    test rax, rax
    jnz dbc_err
    ; page 2: empty leaf
    lea rdi, [pagebuf]
    mov ecx, 4096
    call memzero
    mov byte [pagebuf], 0x0D
    mov rax, 4096
    lea rdi, [pagebuf + 5]
    call be16_st
    mov edi, 2
    lea rsi, [pagebuf]
    call pg_write
    test rax, rax
    jnz dbc_err
    mov qword [dbpages], 2
    mov qword [maxrowid], 0
    mov qword [taskseq], 0
    xor eax, eax
    ret
dbc_err:
    mov eax, 1
    ret

; build_master_cell: master row for name [m_name]/[m_namelen], root [m_rootpg],
; sql [m_sql]/[m_sqllen], rowid [m_rowid] -> celltmp, [clen]. rax 0/1.
build_master_cell:
    push rbx
    mov rax, [m_rootpg]
    test rax, rax
    jz bmc_err
    cmp rax, 32767              ; int16 cap (128MB db); wider needs serial 4
    ja bmc_err
    lea rdi, [recscratch]
    mov rax, 23                  ; 'table'
    call varint_put
    mov [slen], rcx
    mov rax, [m_namelen]
    lea rax, [rax + rax + 13]    ; name serial
    lea rdi, [recscratch]
    add rdi, [slen]
    call varint_put
    add [slen], rcx
    mov rax, [m_namelen]         ; tbl_name = name
    lea rax, [rax + rax + 13]
    lea rdi, [recscratch]
    add rdi, [slen]
    call varint_put
    add [slen], rcx
    mov rax, [m_rootpg]
    cmp rax, 127
    ja bmc_r16
    mov rax, 1                   ; rootpage int8
    lea rdi, [recscratch]
    add rdi, [slen]
    call varint_put
    add [slen], rcx
    jmp bmc_rdone
bmc_r16:
    mov rax, 2                   ; rootpage int16
    lea rdi, [recscratch]
    add rdi, [slen]
    call varint_put
    add [slen], rcx
bmc_rdone:
    mov rax, [m_sqllen]
    lea rax, [rax + rax + 13]    ; sql serial
    lea rdi, [recscratch]
    add rdi, [slen]
    call varint_put
    add [slen], rcx
    ; record into recbuf: [hdrsize][serials][body]
    mov rax, [slen]
    inc rax
    mov [reclen], rax
    lea rdi, [recbuf]
    call varint_put
    lea rsi, [recscratch]
    mov rcx, [slen]
    rep movsb
    lea rsi, [m_table]          ; 'table'
    mov ecx, 5
    add [reclen], rcx
    rep movsb
    mov rsi, [m_name]
    mov rcx, [m_namelen]
    add [reclen], rcx
    rep movsb
    mov rsi, [m_name]
    mov rcx, [m_namelen]
    add [reclen], rcx
    rep movsb
    mov rax, [m_rootpg]         ; rootpage value, minimal width
    cmp rax, 127
    ja bmc_w16
    stosb
    inc qword [reclen]
    jmp bmc_wdone
bmc_w16:
    call be16_st
    add rdi, 2                  ; be16_st does not advance rdi (stosb does)
    add qword [reclen], 2
bmc_wdone:
    mov rsi, [m_sql]
    mov rcx, [m_sqllen]
    add [reclen], rcx
    rep movsb
    ; cell: [payload=reclen][rowid][record]
    lea rdi, [celltmp]
    mov rax, [reclen]
    call varint_put
    mov [clen], rcx
    lea rdi, [celltmp]
    add rdi, rcx
    mov rax, [m_rowid]
    call varint_put
    add [clen], rcx
    lea rsi, [recbuf]
    lea rdi, [celltmp]
    add rdi, [clen]
    mov rcx, [reclen]
    add [clen], rcx
    rep movsb
    pop rbx
    xor eax, eax
    ret
bmc_err:
    pop rbx
    mov eax, 1
    ret

; hdr_touch: changecounter++, size=dbpages on page 1. rax 0/1.
hdr_touch:
    mov edi, 1
    lea rsi, [pagebuf]
    call pg_read
    test rax, rax
    jnz ht_err
    lea rsi, [pagebuf + 24]
    call be32_ld
    inc rax
    lea rdi, [pagebuf + 24]
    call be32_st
    mov rax, [dbpages]
    lea rdi, [pagebuf + 28]
    call be32_st
    mov rax, [taskseq]
    lea rdi, [pagebuf + 60]
    call be32_st
    mov edi, 1
    lea rsi, [pagebuf]
    call pg_write
    test rax, rax
    jnz ht_err
    xor eax, eax
    ret
ht_err:
    mov eax, 1
    ret

; walk_leaves(rdi=rootpg): childtab[] = table leaf pages (asc), [childn].
; Interior children are leaves in our design (interior never splits).
; rax 0 ok / 1 err.
walk_leaves:
    push rbx
    push r12
    push r13
    mov [wroot], rdi
    mov qword [childn], 0
    xor ecx, ecx                  ; depth 0
    call wl_descend
    test rax, rax
    jnz wl_toperr
    pop r13
    pop r12
    pop rbx
    xor eax, eax
    ret
wl_toperr:
    pop r13
    pop r12
    pop rbx
    mov eax, 1
    ret
; wl_descend(rdi=pgno, rcx=depth): append subtree leaves to childtab.
; Level buffers: 0 pagebuf, 1 leafbuf, 2 ipage (depth 3 covers ~1e9 leaves).
wl_descend:
    cmp rcx, 3
    jae wl_derr2
    push rbx
    push r12
    push r13
    push r14
    mov r14, rdi                ; pg
    mov r13, rcx                ; depth
    lea rsi, [pagebuf]
    cmp rcx, 0
    je wl_dbuf
    lea rsi, [leafbuf]
    cmp rcx, 1
    je wl_dbuf
    lea rsi, [ipage]
wl_dbuf:
    mov rdi, r14
    call pg_read_nc             ; probe ok; walks must not evict hot set
    test rax, rax
    jnz wl_derr
    cmp byte [rsi], 0x0D
    je wl_dleaf
    cmp byte [rsi], 0x05
    jne wl_derr
    mov rbx, rsi                ; level buffer base
    lea rsi, [rbx + 3]
    call be16_ld
    cmp rax, 1022
    ja wl_derr
    mov r12, rax                ; ndiv
    xor r14d, r14d              ; i
wl_dcell:
    cmp r14, r12
    jae wl_dright
    lea rsi, [rbx + 12]
    mov rax, r14
    shl rax, 1
    add rsi, rax
    call be16_ld                ; celloff
    lea rsi, [rbx]
    add rsi, rax
    call be32_ld                ; left child
    cmp rax, 1
    jb wl_derr
    cmp rax, [dbpages]
    ja wl_derr
    mov rdi, rax
    mov rcx, r13
    inc rcx
    call wl_descend              ; recurse (own level buffer)
    test rax, rax
    jnz wl_derr
    inc r14
    jmp wl_dcell
wl_dright:
    lea rsi, [rbx + 8]
    call be32_ld                ; rightmost
    cmp rax, 1
    jb wl_derr
    cmp rax, [dbpages]
    ja wl_derr
    mov rdi, rax
    mov rcx, r13
    inc rcx
    call wl_descend
    test rax, rax
    jnz wl_derr
    pop r14
    pop r13
    pop r12
    pop rbx
    xor eax, eax
    ret
wl_dleaf:
    lea rdx, [childtab]
    mov rax, [childn]
    cmp rax, 65536
    jae wl_derr
    shl rax, 3
    add rdx, rax
    mov [rdx], r14
    inc qword [childn]
    pop r14
    pop r13
    pop r12
    pop rbx
    xor eax, eax
    ret
wl_derr:
    pop r14
    pop r13
    pop r12
    pop rbx
    mov eax, 1
    ret
wl_derr2:
    mov eax, 1
    ret

; scan_max(rdi=rootpg): max cell rowid over table leaves -> [maxrowid].
scan_max:
    push rbx
    push r12
    push r13
    push r14
    call walk_leaves
    test rax, rax
    jnz sm_err
    mov qword [maxrowid], 0
    xor r14d, r14d              ; ci
sm_page:
    cmp r14, [childn]
    jae sm_done
    lea rsi, [childtab]
    mov rax, r14
    shl rax, 3
    add rsi, rax
    mov rdi, [rsi]
    lea rsi, [pagebuf]
    call pg_read_nc               ; full scan: probe ok, no fill (keep hot set)
    test rax, rax
    jnz sm_next
    cmp byte [pagebuf], 0x0D
    jne sm_next
    lea rsi, [pagebuf + 3]
    call be16_ld
    mov rbx, rax                ; n
    xor r13d, r13d              ; i
sm_cell:
    cmp r13, rbx
    jae sm_next
    lea rsi, [pagebuf + 8]
    mov rax, r13
    shl rax, 1
    add rsi, rax
    call be16_ld                ; coff
    lea rsi, [pagebuf]
    add rsi, rax
    lea rdx, [pagebuf + 4096]
    call varint_get             ; plen
    test rcx, rcx
    jz sm_inci
    mov rsi, rcx
    call varint_get             ; rowid
    test rcx, rcx
    jz sm_inci
    cmp rax, [maxrowid]
    jbe sm_inci
    mov [maxrowid], rax
sm_inci:
    inc r13
    jmp sm_cell
sm_next:
    inc r14
    jmp sm_page
sm_done:
    pop r14
    pop r13
    pop r12
    pop rbx
    xor eax, eax
    ret
sm_err:
    pop r14
    pop r13
    pop r12
    pop rbx
    mov eax, 1
    ret
; tail_max(rdi=root): [maxrowid] = last rowid of the rightmost leaf
; (0 when empty). O(depth): rowids are append-ordered and rows are never
; physically deleted, so the global max is always last-rightmost. Same
; contract as scan_max for the per-op newrowid chain; replaces its O(n)
; full walk at write-time call sites (the cold-open scan stays).
; Preserves rbx,rbp,r12-r15; clobbers rax,rcx,rdx,rsi,rdi,r8-r11.
tail_max:
    push rbx
    push r12
    push r13
    push r14
    push r15
    call rightmost_leaf
    test rax, rax
    jnz tm_err
    mov rdi, [curpg]
    lea rsi, [pagebuf]
    call pg_read
    test rax, rax
    jnz tm_err
    cmp byte [pagebuf], 0x0D
    jne tm_err
    lea rsi, [pagebuf + 3]
    call be16_ld
    test rax, rax
    jz tm_empty
    dec rax
    shl rax, 1
    lea rsi, [pagebuf + 8]
    add rsi, rax
    call be16_ld
    lea rsi, [pagebuf]
    add rsi, rax
    lea rdx, [pagebuf + 4096]
    call varint_get
    test rcx, rcx
    jz tm_err
    mov rsi, rcx
    call varint_get
    test rcx, rcx
    jz tm_err
    mov [maxrowid], rax
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    xor eax, eax
    ret
tm_empty:
    mov qword [maxrowid], 0
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    xor eax, eax
    ret
tm_err:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    mov eax, 1
    ret

; rightmost_leaf(rdi=root): descend to rightmost leaf. [curpg]=pgno. rax 0/1.
rightmost_leaf:
    ; rdi = root, records descent pages in dstack[0..ddepth) for split
    ; propagation. No pushes needed (no preserved regs used).
    mov qword [ddepth], 0
rl_loop:
    mov [curpg], rdi
    mov rax, [ddepth]
    cmp rax, 16
    jae rl_err
    lea rdx, [dstack]
    shl rax, 3
    add rdx, rax
    mov [rdx], rdi
    inc qword [ddepth]
    push rdi
    lea rsi, [pagebuf]
    call pg_read
    pop rdi
    test rax, rax
    jnz rl_err
    mov al, [pagebuf]
    cmp qword [curpg], 1
    jne rl_typed
    mov al, [pagebuf + 100]   ; page-1 b-tree type (file header shift)
rl_typed:
    cmp al, 0x0D
    je rl_found
    cmp al, 0x05
    jne rl_err
    lea rsi, [pagebuf + 8]
    call be32_ld
    mov rdi, rax
    jmp rl_loop
rl_found:
    xor eax, eax
    ret
rl_err:
    mov eax, 1
    ret

; cell_key(rsi=cell abs ptr, rdx=page end): rax=rowid (0=corrupt).
cell_key:
    push rsi
    push rdx
    call varint_get
    test rcx, rcx
    jz ck_bad
    mov rsi, rcx
    call varint_get
    test rcx, rcx
    jz ck_bad
    pop rdx
    pop rsi
    ret
ck_bad:
    pop rdx
    pop rsi
    xor eax, eax
    ret

; build_data_cell: [newrowid], rsnbuf/rsnlen, thbuf/thlen2?, ccbuf/cclen
;   -> celltmp, [clen]. rax 0.
build_data_cell:
    lea rdi, [recscratch]
    mov rax, [rsnlen]
    lea rax, [rax + rax + 13]
    call varint_put
    mov [slen], rcx
    mov rax, [cthlen]
    test rax, rax
    jz bd_t0
    lea rax, [rax + rax + 13]
    jmp bd_t1
bd_t0:
    xor eax, eax
bd_t1:
    push rax
    lea rdi, [recscratch]
    add rdi, [slen]
    mov rax, [rsp]
    call varint_put
    add [slen], rcx
    pop rax
    mov rax, [cclen]
    lea rax, [rax + rax + 13]
    lea rdi, [recscratch]
    add rdi, [slen]
    call varint_put
    add [slen], rcx
    lea rdi, [recscratch]
    add rdi, [slen]
    mov rax, 9                  ; valid=1 on insert
    call varint_put
    add [slen], rcx
    mov rax, [slen]
    inc rax
    mov [reclen], rax
    lea rdi, [recbuf]
    call varint_put               ; emit H
    lea rsi, [recscratch]
    mov rcx, [slen]
    rep movsb                     ; serials (already counted in H)
    lea rsi, [rsnbuf]
    mov rcx, [rsnlen]
    add [reclen], rcx
    rep movsb
    mov rcx, [cthlen]
    test rcx, rcx
    jz bd_noth
    lea rsi, [thbuf]
    add [reclen], rcx
    rep movsb
bd_noth:
    lea rsi, [ccbuf]
    mov rcx, [cclen]
    add [reclen], rcx
    rep movsb
    lea rdi, [celltmp]
    mov rax, [reclen]
    call varint_put
    mov [clen], rcx
    lea rdi, [celltmp]
    add rdi, rcx
    mov rax, [newrowid]
    call varint_put
    add [clen], rcx
    lea rsi, [recbuf]
    lea rdi, [celltmp]
    add rdi, [clen]
    mov rcx, [reclen]
    add [clen], rcx
    rep movsb
    xor eax, eax
    ret

; insert_row: builds conclusions cell, inserts at right edge of root 2.
; (uses [newrowid] + field bufs). rax 0 ok / 1 io / 2 full.
insert_row:
    push rbx
    push r12
    call build_data_cell
    mov qword [splitroot], 2
    mov qword [pagebase], 0
    call place_cell
    test rax, rax
    jnz ir_err
    mov rax, [newrowid]
    mov [maxrowid], rax
    pop r12
    pop rbx
    xor eax, eax
    ret
ir_err:
    pop r12
    pop rbx
    mov eax, 1
    ret
ir_split:
    call split_leaf
    pop r12
    pop rbx
    ret                           ; rax from split_leaf (0/1/2)

; place_cell: insert celltmp/[clen] at right edge of [splitroot] table.
; Data pages only (base 0). Cell rowid must exceed table max (append order).
; Oversize cells (clen+2 > 4000, near page usable) are refused, never split.
; rax 0 ok / 1 io / 2 full / 3 oversize.
place_cell:
    push rbx
    push r12
    mov rax, [clen]
    add rax, 2
    cmp rax, 4000
    ja pc_over
    mov rdi, [splitroot]
    call rightmost_leaf
    test rax, rax
    jnz pc_err
    ; free in pagebuf leaf
    lea rsi, [pagebuf + 3]
    call be16_ld
    mov r12, rax                ; n
    lea rsi, [pagebuf + 5]
    call be16_ld                ; content
    mov rbx, rax
    sub rbx, 8
    mov rcx, r12
    shl rcx, 1
    sub rbx, rcx                ; free
    mov rcx, [clen]
    add rcx, 2
    cmp rbx, rcx
    jb pc_split
    ; place at content-clen
    lea rsi, [pagebuf + 5]
    call be16_ld
    sub rax, [clen]
    mov [wcontent], rax
    lea rsi, [celltmp]
    lea rdi, [pagebuf]
    add rdi, rax
    mov rcx, [clen]
    rep movsb
    lea rsi, [pagebuf + 8]
    mov rax, r12
    shl rax, 1
    add rsi, rax
    mov rax, [wcontent]
    mov rdi, rsi
    call be16_st
    lea rsi, [pagebuf + 3]
    mov rax, r12
    inc rax
    mov rdi, rsi
    call be16_st
    lea rsi, [pagebuf + 5]
    mov rax, [wcontent]
    mov rdi, rsi
    call be16_st
    mov rdi, [curpg]
    lea rsi, [pagebuf]
    call pg_write
    test rax, rax
    jnz pc_err
    pop r12
    pop rbx
    xor eax, eax
    ret
pc_err:
    pop r12
    pop rbx
    mov eax, 1
    ret
pc_over:
    pop r12
    pop rbx
    mov eax, 3
    ret
pc_split:
    call split_leaf
    pop r12
    pop rbx
    ret                           ; rax from split_leaf (0/1/2)

; master_place: append celltmp/[clen] to page-1 master leaf (explicit
; +100 offsets). Master never splits (6 tiny rows). rax 0/1.
master_place:
    push rbx
    mov edi, 1
    lea rsi, [pagebuf]
    call pg_read
    test rax, rax
    jnz mp_err
    cmp byte [pagebuf + 100], 0x0D
    jne mp_err
    lea rsi, [pagebuf + 103]
    call be16_ld
    mov rbx, rax                ; n
    lea rsi, [pagebuf + 105]
    call be16_ld                ; content
    mov rcx, rbx
    shl rcx, 1
    sub rax, rcx
    sub rax, 108                ; free = content-(100+8+2n)
    mov rcx, [clen]
    add rcx, 2
    cmp rax, rcx
    jb mp_err
    lea rsi, [pagebuf + 105]
    call be16_ld
    sub rax, [clen]
    mov [wcontent], rax
    lea rsi, [celltmp]
    lea rdi, [pagebuf]
    add rdi, rax
    mov rcx, [clen]
    rep movsb
    lea rsi, [pagebuf + 108]
    mov rax, rbx
    shl rax, 1
    add rsi, rax
    mov rax, [wcontent]
    mov rdi, rsi
    call be16_st
    lea rdi, [pagebuf + 103]
    mov rax, rbx
    inc rax
    call be16_st
    lea rdi, [pagebuf + 105]
    mov rax, [wcontent]
    call be16_st
    mov edi, 1
    lea rsi, [pagebuf]
    call pg_write
    test rax, rax
    jnz mp_err
    pop rbx
    xor eax, eax
    ret
mp_err:
    pop rbx
    mov eax, 1
    ret

; master_drop(rsi=name, rdx=len): remove a master cell by name (repair path
; for corrupt rows, e.g. pre-width-fix usage entries). rax 0 ok (found and
; removed, or not present), 1 io. Preserves rbx,rbp,r12-r15.
master_drop:
    push rbx
    push r12
    push r13
    push r14
    mov [ftname], rsi
    mov [ftlen], rdx
    mov edi, 1
    lea rsi, [pagebuf]
    call pg_read
    test rax, rax
    jnz md_err
    cmp byte [pagebuf + 100], 0x0D
    jne md_err
    lea rsi, [pagebuf + 103]
    call be16_ld
    mov rbx, rax                ; n
    xor r12d, r12d              ; i
md_cell:
    cmp r12, rbx
    jae md_ok                   ; not present: nothing to do
    lea rsi, [pagebuf + 108]
    mov rax, r12
    shl rax, 1
    add rsi, rax
    call be16_ld                ; coff
    mov r14, rax
    lea rsi, [pagebuf]
    add rsi, rax
    lea rdx, [pagebuf + 4096]
    call varint_get             ; plen
    test rcx, rcx
    jz md_err
    mov [ts1], rax              ; stash plen
    mov rsi, rcx
    call varint_get             ; rowid
    test rcx, rcx
    jz md_err
    mov [ts2], rcx              ; stash after-rowid ptr for L
    mov rsi, rcx
    call varint_get             ; hdrsize
    test rcx, rcx
    jz md_err
    mov rsi, rcx
    call varint_get             ; s0
    test rcx, rcx
    jz md_err
    cmp rax, 13                 ; s0 must be odd TEXT here
    jb md_next
    test al, 1
    jz md_next
    sub rax, 13
    shr rax, 1
    mov r13, rax                ; len0
    mov rsi, rcx
    call varint_get             ; s1 (name serial)
    test rcx, rcx
    jz md_err
    mov r10, rcx                ; after-s1 ptr
    cmp rax, 13
    jb md_next
    test al, 1
    jz md_next
    sub rax, 13
    shr rax, 1                  ; len1
    cmp rax, [ftlen]
    jne md_next
    mov rsi, rcx
    call varint_get             ; s2
    test rcx, rcx
    jz md_err
    mov rsi, rcx
    call varint_get             ; s3
    test rcx, rcx
    jz md_err
    mov rsi, rcx
    call varint_get             ; s4
    test rcx, rcx
    jz md_err
    mov r11, rcx                ; body
    add r11, r13                ; col1 = body + len0
    mov rsi, r11
    mov rdi, [ftname]
    mov rcx, [ftlen]
    rep cmpsb
    jne md_next
md_found:
    ; L = (after-rowid - cellstart) + plen
    lea rax, [pagebuf]
    add rax, r14                ; cell start abs
    mov rcx, [ts2]              ; after-rowid abs
    sub rcx, rax
    add rcx, [ts1]              ; + plen
    mov [ts3], rcx              ; L
    ; content pointer
    lea rsi, [pagebuf + 105]
    call be16_ld
    mov r13, rax                ; content
    ; memmove [content, coff) -> [content+L, coff+L), backward
    mov rcx, r14
    sub rcx, r13                ; len (0 ok: rep nop)
    lea rsi, [pagebuf]
    add rsi, r14
    dec rsi
    lea rdi, [pagebuf]
    add rdi, r14
    add rdi, [ts3]
    dec rdi
    std
    rep movsb
    cld
    ; fix ptrs below coff (skip i)
    mov r10, r12                ; i
    xor r11d, r11d              ; j
md_fix:
    cmp r11, rbx
    jae md_fixdone
    cmp r11, r10
    je md_fixnext
    lea rsi, [pagebuf + 108]
    mov rax, r11
    shl rax, 1
    add rsi, rax
    call be16_ld
    cmp rax, r14
    jae md_fixnext
    add rax, [ts3]
    mov rdi, rsi
    call be16_st
md_fixnext:
    inc r11
    jmp md_fix
md_fixdone:
    ; drop ptr[i]: shift tail down 2
    lea rsi, [pagebuf + 108]
    mov rax, r10
    shl rax, 1
    add rsi, rax
    add rsi, 2                  ; src = &ptr[i+1]
    mov rdi, rsi
    sub rdi, 2                  ; dst = &ptr[i]
    mov rcx, rbx
    sub rcx, r10
    dec rcx
    shl rcx, 1
    jz md_noarr
    rep movsb
md_noarr:
    lea rsi, [pagebuf + 103]
    call be16_ld
    dec rax
    lea rdi, [pagebuf + 103]
    call be16_st
    lea rsi, [pagebuf + 105]
    call be16_ld
    add rax, [ts3]
    lea rdi, [pagebuf + 105]
    call be16_st
    mov edi, 1
    lea rsi, [pagebuf]
    call pg_write
    test rax, rax
    jnz md_err
    jmp md_ok
md_next:
    inc r12
    jmp md_cell
md_err:
    pop r14
    pop r13
    pop r12
    pop rbx
    mov eax, 1
    ret
md_ok:
    pop r14
    pop r13
    pop r12
    pop rbx
    xor eax, eax
    ret
    ; match: remove cell [coff, coff+L), L = (after-rowid - coff) + plen.
    ; r14 = coff. recompute end: after-rowid ptr = (s1-after ptr) - (s1 varint len)...
    jmp md_found
; Size-ordered division; new cell (max rowid) always lands in the right page.
; rax 0 ok / 1 io / 2 full.
split_leaf:
    push rbx
    push r12
    push r13
    push r14
    push r15
    ; table cell offsets+lens of P
    lea rsi, [pagebuf + 3]
    call be16_ld
    mov r12, rax                ; n
    cmp r12, 511
    ja sp_full
    mov [splitn], r12
    mov rax, [clen]
    mov r13, rax                ; total = new cell first
    xor ebx, ebx                ; i
sp_size:
    cmp rbx, r12
    jae sp_sized
    lea rsi, [pagebuf + 8]
    mov rax, rbx
    shl rax, 1
    add rsi, rax
    call be16_ld                ; coff
    lea rsi, [offstab]
    mov rcx, rbx
    shl rcx, 3
    add rsi, rcx
    mov [rsi], rax              ; offstab[i] = coff
    lea r15, [pagebuf]
    add r15, rax                ; r15 = cell start
    mov rsi, r15
    lea rdx, [pagebuf + 4096]
    call varint_get             ; plen -> rax
    test rcx, rcx
    jz sp_err
    mov r14, rax                ; plen
    mov rsi, rcx
    call varint_get             ; rowid -> rax
    test rcx, rcx
    jz sp_err
    sub rcx, r15
    add rcx, r14                ; celllen = (p2-start)+plen
    lea rsi, [sizetab]
    mov rax, rbx
    shl rax, 3
    add rsi, rax
    mov [rsi], rcx
    add r13, rcx                ; total += celllen
    inc rbx
    jmp sp_size
sp_sized:
    ; divide: left takes cells while left+size <= total/2
    mov rax, r13
    shr rax, 1                  ; half
    mov [halfsz], rax
    xor ebx, ebx                ; k
    xor r13d, r13d              ; left size
sp_div:
    cmp rbx, r12
    jae sp_divdone
    lea rsi, [sizetab]
    mov rax, rbx
    shl rax, 3
    add rsi, rax
    mov rcx, [rsi]
    mov rax, r13
    add rax, rcx
    cmp rax, [halfsz]
    ja sp_divdone
    add r13, rcx
    inc rbx
    jmp sp_div
sp_divdone:
    test rbx, rbx               ; k>=1 guaranteed; force it anyway
    jnz sp_havek
    mov ebx, 1
sp_havek:
    mov [splitk], rbx
    ; divkey = rowid of cell k-1
    lea rsi, [offstab]
    mov rax, rbx
    dec rax
    shl rax, 3
    add rsi, rax
    lea r15, [pagebuf]
    add r15, [rsi]              ; cell start
    mov rsi, r15
    lea rdx, [pagebuf + 4096]
    call varint_get
    test rcx, rcx
    jz sp_err
    mov rsi, rcx
    call varint_get
    test rcx, rcx
    jz sp_err
    mov [divkey], rax
    mov rax, [curpg]
    cmp rax, [splitroot]
    je sp_rootcase
    ; ---- general: split leaf P, propagate divider up the right edge ----
    mov rax, [dbpages]
    inc rax
    mov [qpg], rax                ; Q number (adopt after first write)
    ; trim P to k cells (image still intact for build_right below)
    mov rax, [splitk]
    lea rdi, [pagebuf + 3]
    call be16_st
    ; build Q (upper + new) from intact image, then carve freeblock
    call build_right
    call reg_free
    mov rdi, [curpg]
    lea rsi, [pagebuf]
    call pg_write
    test rax, rax
    jnz sp_err
    mov rax, [qpg]
    mov [dbpages], rax            ; adopt (jorig kept original size)
    mov rdi, [qpg]
    lea rsi, [leafbuf]
    call pg_write
    test rax, rax
    jnz sp_err
    ; propagate divider (C=P, K=divkey, Q=qpg) from parent level
    mov rdi, [curpg]
    mov rsi, [divkey]
    mov rdx, [qpg]
    mov rax, [ddepth]
    sub rax, 2
    js sp_err                     ; P==root handled above; never here
    mov rcx, rax
    call propagate
    test rax, rax
    jnz sp_properr
    jmp sp_ok
sp_properr:
    cmp rax, 2
    je sp_full
    jmp sp_err
sp_rootcase:
    ; ---- case A: P==root leaf -> reorg (root keeps its page number) ----
    mov rax, [dbpages]
    inc rax
    mov [lpg], rax
    inc rax
    mov [qpg], rax
    ; L = P trimmed to k (image intact for build_right below)
    mov rax, [splitk]
    lea rdi, [pagebuf + 3]
    call be16_st
    ; Q = upper + new from intact image, then carve freeblock in L
    call build_right
    call reg_free
    mov rdi, [lpg]
    lea rsi, [pagebuf]
    call pg_write
    test rax, rax
    jnz sp_err
    mov rax, [qpg]
    mov [dbpages], rax          ; adopt (jorig kept original size)
    mov rdi, [qpg]
    lea rsi, [leafbuf]
    call pg_write
    test rax, rax
    jnz sp_err
    ; root -> interior: divider cell at content top, ptr0 at +12, rightmost=Q
    mov byte [pagebuf], 0x05
    xor eax, eax
    lea rdi, [pagebuf + 1]
    call be16_st              ; freeblock
    mov rax, 1
    lea rdi, [pagebuf + 3]
    call be16_st              ; ncells
    mov byte [pagebuf + 7], 0 ; frag
    mov rax, [qpg]
    lea rdi, [pagebuf + 8]
    call be32_st              ; rightmost
    mov rax, [divkey]
    lea rdi, [recscratch]
    call varint_put           ; rcx = vlen
    mov [vlen], rcx
    mov rax, 4096
    sub rax, 4
    sub rax, rcx
    mov [wcontent], rax       ; celloff
    lea rdi, [pagebuf]
    add rdi, rax
    mov rax, [lpg]
    call be32_st              ; divider left child
    lea rdi, [pagebuf]
    add rdi, [wcontent]
    add rdi, 4
    mov rax, [divkey]
    call varint_put           ; divider key
    mov rax, [wcontent]
    lea rdi, [pagebuf + 12]
    call be16_st              ; ptr0 (interior ptrs start at +12)
    mov rax, [wcontent]
    lea rdi, [pagebuf + 5]
    call be16_st              ; content
    mov rdi, [splitroot]
    lea rsi, [pagebuf]
    call pg_write
    test rax, rax
    jnz sp_err
sp_ok:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    xor eax, eax
    ret
sp_err:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    mov eax, 1
    ret
sp_full:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    mov eax, 2
    ret

; div_ok: rax 0 if divider sane (1 <= C=rbx <= dbpages+1, 1 <= K=r12 < 2^62).
; Silent corruption becomes an explicit full. Preserves rbx,r12.
div_ok:
    mov rax, rbx
    test rax, rax
    jz div_bad
    mov rcx, [dbpages]
    inc rcx
    cmp rax, rcx
    ja div_bad
    mov rax, r12
    test rax, rax
    jz div_bad
    mov rcx, rax
    shr rcx, 62
    jnz div_bad
    xor eax, eax
    ret
div_bad:
    mov eax, 1
    ret

; enc_div(rdi=dst, eax=child, r8=key): append encoded divider cell.
; rcx = total len. Clobbers rax,rcx,rdx,rdi.
enc_div:
    call be32_st
    add rdi, 4
    mov rax, r8
    call varint_put
    add rcx, 4
    ret

; ib_put(rsi=src, rdx=len): append divider cell to leafbuf image (ptr +12).
ib_put:
    mov rax, [wcontent]
    sub rax, rdx
    mov [wcontent], rax
    lea rdi, [leafbuf]
    add rdi, rax
    mov rcx, rdx
    rep movsb
    lea rsi, [leafbuf + 12]
    mov rax, [wn]
    shl rax, 1
    add rsi, rax
    mov rax, [wcontent]
    mov rdi, rsi
    call be16_st
    inc qword [wn]
    ret

; propagate(rdi=C, rsi=K, rdx=Q, rcx=level idx): insert divider into
; dstack[idx], splitting upward as needed. Root splits reorganize in place
; (root keeps its number: no master rewrite, f_root_* never move).
; rax 0 ok / 1 io / 2 full. Preserves rbx,rbp,r12-r15.
propagate:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov rbx, rdi                ; C: left page of incoming divider
    mov r12, rsi                ; K: incoming key
    mov r13, rdx                ; Q: right page
    mov r14, rcx                ; idx
pr_loop:
    lea rax, [dstack]
    mov rdx, r14
    shl rdx, 3
    add rax, rdx
    mov rdi, [rax]
    mov [ppg], rdi
    lea rsi, [ipage]
    call pg_read
    test rax, rax
    jnz pr_err
    cmp byte [ipage], 0x05
    jne pr_err
    mov rax, r12
    lea rdi, [recscratch]
    call varint_put
    mov [vlen], rcx
    lea rsi, [ipage + 3]
    call be16_ld
    cmp rax, 1022
    ja pr_err
    mov r15, rax                ; n
    lea rsi, [ipage + 5]
    call be16_ld
    sub rax, 12
    mov rcx, r15
    shl rcx, 1
    sub rax, rcx                ; free
    mov rcx, [vlen]
    add rcx, 6
    cmp rax, rcx
    jae pr_append
    ; ---- split this interior (n>=2 required) ----
    cmp r15, 2
    jb pr_full
    xor r10d, r10d              ; i
    xor r11, r11                ; total
pr_sz:
    cmp r10, r15
    jae pr_sized
    lea rsi, [ipage + 12]
    mov rax, r10
    shl rax, 1
    add rsi, rax
    call be16_ld                ; coff
    mov r8, rax
    lea rax, [offstab]
    mov rdx, r10
    shl rdx, 3
    add rax, rdx
    mov [rax], r8
    lea rsi, [ipage]
    add rsi, r8
    add rsi, 4
    push rsi                  ; key pos (varint_get clobbers r8/r9)
    lea rdx, [ipage + 4096]
    call varint_get
    pop rdx                   ; key pos (balance before branch)
    test rcx, rcx
    jz pr_err
    mov rax, rcx
    sub rax, rdx
    add rax, 4                  ; celllen = keylen + 4
    lea rdx, [sizetab]
    mov rcx, r10
    shl rcx, 3
    add rdx, rcx
    mov [rdx], rax
    add r11, rax
    inc r10
    jmp pr_sz
pr_sized:
    mov rax, r11
    shr rax, 1
    mov [halfsz], rax
    xor r10d, r10d
    xor r11d, r11d
pr_div:
    cmp r10, r15
    jae pr_divdone
    lea rsi, [sizetab]
    mov rax, r10
    shl rax, 3
    add rsi, rax
    mov rcx, [rsi]
    mov rax, r11
    add rax, rcx
    cmp rax, [halfsz]
    ja pr_divdone
    add r11, rcx
    inc r10
    jmp pr_div
pr_divdone:
    cmp r10, 0
    jne pr_klo
    mov r10d, 1
pr_klo:
    cmp r10, r15
    jb pr_khi
    mov r10, r15
    dec r10
pr_khi:
    mov [splitk], r10
    ; promoted key = key of cell[k]
    lea rsi, [offstab]
    mov rax, r10
    shl rax, 3
    add rsi, rax
    lea rax, [ipage]
    add rax, [rsi]
    add rax, 4
    mov rsi, rax
    lea rdx, [ipage + 4096]
    call varint_get
    test rcx, rcx
    jz pr_err
    mov [divkey], rax
    cmp r14, 0
    je pr_rootreorg
    ; ---- non-root: G keeps number w/ left k, G2 new w/ right + incoming ----
    mov rax, [dbpages]
    inc rax
    mov [qpg], rax                ; G2 number (adopt after first write)
    ; build G2 FIRST from pristine ipage (below). The G trim carves a
    ; freeblock into the content area where right-part cells still live,
    ; so trimming before the copy destroys bytes G2 must copy (the last
    ; cell sits exactly at content-start). G2 build touches only leafbuf,
    ; [wcontent]/[wn] and r8: r10(k), r15(n), rbx/r12/r13 survive it.
    ; build G2 in leafbuf: header + cells[k+1..n) + incoming + rightmost=Q
    mov byte [leafbuf], 0x05
    xor eax, eax
    lea rdi, [leafbuf + 1]
    call be16_st
    lea rdi, [leafbuf + 3]
    call be16_st
    mov rax, 4096
    lea rdi, [leafbuf + 5]
    call be16_st
    mov byte [leafbuf + 7], 0
    mov qword [wcontent], 4096
    mov qword [wn], 0
    mov r8, r10
    inc r8
pr_g2:
    cmp r8, r15
    jae pr_g2in
    lea rsi, [offstab]
    mov rax, r8
    shl rax, 3
    add rsi, rax
    lea rax, [ipage]
    add rax, [rsi]
    mov rsi, rax
    lea rax, [sizetab]
    mov rdx, r8
    shl rdx, 3
    add rax, rdx
    mov rdx, [rax]
    call ib_put
    inc r8
    jmp pr_g2
pr_g2in:
    ; fit check for incoming divider in R2 half
    mov rax, [wcontent]
    sub rax, 12
    mov rdx, [wn]
    shl rdx, 1
    sub rax, rdx
    mov rdx, [vlen]
    add rdx, 6
    cmp rax, rdx
    jb pr_full
    mov rcx, [vlen]
    add rcx, 4
    sub [wcontent], rcx
    call div_ok                   ; never commit a wild divider
    test rax, rax
    jnz pr_full
    lea rdi, [leafbuf]
    add rdi, [wcontent]
    mov eax, ebx
    mov r8, r12
    call enc_div
    lea rsi, [leafbuf + 12]
    mov rax, [wn]
    shl rax, 1
    add rsi, rax
    mov rax, [wcontent]
    mov rdi, rsi
    call be16_st
    inc qword [wn]
    mov rax, [wcontent]
    lea rdi, [leafbuf + 5]
    call be16_st
    mov rax, [wn]
    lea rdi, [leafbuf + 3]
    call be16_st
    mov rax, r13
    lea rdi, [leafbuf + 8]
    call be32_st
    ; trim G (after G2 build above): reset freehead/frag (interiors stay
    ; dense: SQLite rejects interior freeblocks), then header.
    call reg_free_ip
    mov rax, r10
    lea rdi, [ipage + 3]
    call be16_st
    mov r11, 4096
    xor r8d, r8d
pr_min:
    cmp r8, r10
    jae pr_mindone
    lea rsi, [offstab]
    mov rax, r8
    shl rax, 3
    add rsi, rax
    mov rax, [rsi]
    cmp rax, r11
    jae pr_minnext
    mov r11, rax
pr_minnext:
    inc r8
    jmp pr_min
pr_mindone:
    mov rax, r11
    lea rdi, [ipage + 5]
    call be16_st
    lea rsi, [offstab]
    mov rax, r10
    shl rax, 3
    add rsi, rax
    lea rax, [ipage]
    add rax, [rsi]
    mov rsi, rax
    call be32_ld
    lea rdi, [ipage + 8]
    call be32_st
    mov rdi, [ppg]
    lea rsi, [ipage]
    call pg_write
    test rax, rax
    jnz pr_err
    mov rdi, [qpg]
    lea rsi, [leafbuf]
    call pg_write
    test rax, rax
    jnz pr_err
    mov rax, [qpg]
    mov [dbpages], rax
    mov rbx, [ppg]                ; C = G (kept number)
    mov r12, [divkey]             ; K = promoted
    mov r13, [qpg]                ; Q = G2
    dec r14
    jmp pr_loop
pr_rootreorg:
    ; root keeps its number: L new (left), G slim (1 divider), R2 new (right)
    mov rax, [dbpages]
    inc rax
    mov [lpg], rax                ; L number
    inc rax
    mov [qpg], rax                ; R2 number (adopt after first write)
    ; L build in leafbuf: header + cells[0..k) + rightmost=leftchild(d_k)
    mov byte [leafbuf], 0x05
    xor eax, eax
    lea rdi, [leafbuf + 1]
    call be16_st
    lea rdi, [leafbuf + 3]
    call be16_st
    mov rax, 4096
    lea rdi, [leafbuf + 5]
    call be16_st
    mov byte [leafbuf + 7], 0
    mov qword [wcontent], 4096
    mov qword [wn], 0
    xor r8d, r8d
pr_rl:
    cmp r8, r10
    jae pr_rldone
    lea rsi, [offstab]
    mov rax, r8
    shl rax, 3
    add rsi, rax
    lea rax, [ipage]
    add rax, [rsi]
    mov rsi, rax
    lea rax, [sizetab]
    mov rdx, r8
    shl rdx, 3
    add rax, rdx
    mov rdx, [rax]
    call ib_put
    inc r8
    jmp pr_rl
pr_rldone:
    lea rsi, [offstab]
    mov rax, r10
    shl rax, 3
    add rsi, rax
    lea rax, [ipage]
    add rax, [rsi]
    mov rsi, rax
    call be32_ld                  ; leftchild(d_k)
    lea rdi, [leafbuf + 8]
    call be32_st
    mov rax, [wn]
    lea rdi, [leafbuf + 3]
    call be16_st
    mov rax, [wcontent]
    lea rdi, [leafbuf + 5]
    call be16_st
    mov rdi, [lpg]
    lea rsi, [leafbuf]
    call pg_write
    test rax, rax
    jnz pr_err
    mov rax, [qpg]
    mov [dbpages], rax            ; adopt (jorig kept original)
    ; R2 build in leafbuf: header + cells[k+1..n) + incoming + rightmost=Q
    mov byte [leafbuf], 0x05
    xor eax, eax
    lea rdi, [leafbuf + 1]
    call be16_st
    lea rdi, [leafbuf + 3]
    call be16_st
    mov rax, 4096
    lea rdi, [leafbuf + 5]
    call be16_st
    mov byte [leafbuf + 7], 0
    mov qword [wcontent], 4096
    mov qword [wn], 0
    mov r8, [splitk]              ; k reload: pg_write above clobbered r10
    inc r8
pr_rr:
    cmp r8, r15
    jae pr_rrin
    lea rsi, [offstab]
    mov rax, r8
    shl rax, 3
    add rsi, rax
    lea rax, [ipage]
    add rax, [rsi]
    mov rsi, rax
    lea rax, [sizetab]
    mov rdx, r8
    shl rdx, 3
    add rax, rdx
    mov rdx, [rax]
    call ib_put
    inc r8
    jmp pr_rr
pr_rrin:
    mov rax, [wcontent]
    sub rax, 12
    mov rdx, [wn]
    shl rdx, 1
    sub rax, rdx
    mov rdx, [vlen]
    add rdx, 6
    cmp rax, rdx
    jb pr_full
    mov rcx, [vlen]
    add rcx, 4
    sub [wcontent], rcx
    call div_ok                   ; never commit a wild divider
    test rax, rax
    jnz pr_full
    lea rdi, [leafbuf]
    add rdi, [wcontent]
    mov eax, ebx
    mov r8, r12
    call enc_div
    lea rsi, [leafbuf + 12]
    mov rax, [wn]
    shl rax, 1
    add rsi, rax
    mov rax, [wcontent]
    mov rdi, rsi
    call be16_st
    inc qword [wn]
    mov rax, [wcontent]
    lea rdi, [leafbuf + 5]
    call be16_st
    mov rax, [wn]
    lea rdi, [leafbuf + 3]
    call be16_st
    mov rax, r13
    lea rdi, [leafbuf + 8]
    call be32_st
    mov rdi, [qpg]
    lea rsi, [leafbuf]
    call pg_write                 ; R2 (missing this drowned the file by one)
    test rax, rax
    jnz pr_err
    ; G slim in ipage: single divider (L, divkey) + rightmost=R2
    mov byte [ipage], 0x05
    xor eax, eax
    lea rdi, [ipage + 1]
    call be16_st
    mov rax, 1
    lea rdi, [ipage + 3]
    call be16_st
    mov byte [ipage + 7], 0
    mov rax, [divkey]
    lea rdi, [recscratch]
    call varint_put
    mov [vlen], rcx
    mov rax, 4096
    sub rax, 4
    sub rax, rcx
    mov [wcontent], rax           ; slim celloff (also content: single cell)
    lea rdi, [ipage]
    add rdi, rax
    mov rbx, [lpg]
    mov r12, [divkey]
    call div_ok                   ; never commit a wild divider
    test rax, rax
    jnz pr_full
    mov eax, dword [lpg]
    call be32_st
    lea rdi, [ipage]
    add rdi, [wcontent]
    add rdi, 4
    mov rax, [divkey]
    call varint_put
    lea rsi, [ipage + 12]
    mov rax, [wcontent]
    mov rdi, rsi
    call be16_st
    mov rax, [wcontent]
    lea rdi, [ipage + 5]
    call be16_st
    mov rax, [qpg]
    lea rdi, [ipage + 8]
    call be32_st
    mov rdi, [ppg]
    lea rsi, [ipage]
    call pg_write
    test rax, rax
    jnz pr_err
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    xor eax, eax
    ret
pr_append:
    lea rsi, [ipage + 5]
    call be16_ld
    mov rcx, [vlen]
    add rcx, 4
    sub rax, rcx
    mov [wcontent], rax
    lea rdi, [ipage]
    add rdi, rax
    call div_ok                   ; never commit a wild divider
    test rax, rax
    jnz pr_full
    mov eax, ebx
    call be32_st
    lea rdi, [ipage]
    add rdi, [wcontent]
    add rdi, 4
    mov rax, r12
    call varint_put
    lea rsi, [ipage + 12]
    mov rax, r15
    shl rax, 1
    add rsi, rax
    mov rax, [wcontent]
    mov rdi, rsi
    call be16_st
    lea rsi, [ipage + 3]
    mov rax, r15
    inc rax
    mov rdi, rsi
    call be16_st
    lea rsi, [ipage + 5]
    mov rax, [wcontent]
    mov rdi, rsi
    call be16_st
    mov rax, r13
    lea rdi, [ipage + 8]
    call be32_st
    mov rdi, [ppg]
    lea rsi, [ipage]
    call pg_write
    test rax, rax
    jnz pr_err
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    xor eax, eax
    ret
pr_err:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    mov eax, 1
    ret
pr_full:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    mov eax, 2
    ret

; build_right: fresh leaf in leafbuf from pagebuf-image cells [splitk..n)
; plus new cell from celltmp. Uses offstab/sizetab/[splitk]/[clen].
build_right:
    push rbx
    push r12
    push r13
    mov byte [leafbuf], 0x0D
    xor eax, eax
    lea rdi, [leafbuf + 1]
    call be16_st
    lea rdi, [leafbuf + 3]
    call be16_st
    mov rax, 4096
    lea rdi, [leafbuf + 5]
    call be16_st
    mov byte [leafbuf + 7], 0
    mov qword [wcontent], 4096
    mov qword [wn], 0
    mov r12, [splitn]           ; original n (pagebuf may already be trimmed)
    mov rbx, [splitk]           ; i
br_loop:
    cmp rbx, r12
    jae br_new
    lea rsi, [offstab]
    mov rax, rbx
    shl rax, 3
    add rsi, rax
    lea r13, [pagebuf]
    add r13, [rsi]              ; src
    lea rsi, [sizetab]
    mov rax, rbx
    shl rax, 3
    add rsi, rax
    mov rdx, [rsi]              ; len
    mov rsi, r13
    call br_put
    inc rbx
    jmp br_loop
br_new:
    lea rsi, [celltmp]
    mov rdx, [clen]
    call br_put
    mov rax, [wn]
    lea rdi, [leafbuf + 3]
    call be16_st
    mov rax, [wcontent]
    lea rdi, [leafbuf + 5]
    call be16_st
    pop r13
    pop r12
    pop rbx
    ret
; br_put(rsi=src, rdx=len): append cell to leafbuf image.
br_put:
    mov rax, [wcontent]
    sub rax, rdx
    mov [wcontent], rax
    lea rdi, [leafbuf]
    add rdi, rax
    mov rcx, rdx
    rep movsb
    lea rsi, [leafbuf + 8]
    mov rax, [wn]
    shl rax, 1
    add rsi, rax
    mov rax, [wcontent]
    mov rdi, rsi
    call be16_st
    inc qword [wn]
    ret

; reg_free: register dead upper cells of the trimmed pagebuf image
; ([splitk] cells kept) as one freeblock. No-op if dead < 4 bytes.
reg_free:
    push rbx
    push r12
    lea rsi, [pagebuf + 5]
    call be16_ld                ; content_old
    mov r12, rax
    xor ebx, ebx                ; kept bytes
    xor ecx, ecx                ; i
rf_sum:
    cmp rcx, [splitk]
    jae rf_haved
    lea rsi, [sizetab]
    mov rax, rcx
    shl rax, 3
    add rsi, rax
    add rbx, [rsi]
    inc rcx
    jmp rf_sum
rf_haved:
    mov rax, 4096
    sub rax, rbx                ; dead_end
    sub rax, r12                ; dead_size
    cmp rax, 4
    jb rf_done
    mov [rfsize], rax
    lea rdi, [pagebuf]
    add rdi, r12                ; dead_start
    xor eax, eax
    call be16_st                ; next = 0
    mov rax, [rfsize]
    lea rdi, [pagebuf]
    add rdi, r12
    add rdi, 2
    call be16_st                ; size (big-endian)
    mov rax, r12
    lea rdi, [pagebuf + 1]
    call be16_st                ; freeblock head
rf_done:
    pop r12
    pop rbx
    ret

; reg_free_ip: interior trims stay DENSE. Proven by transplant test on a
; real SQLite DB (3.54.0): any freeblock on an interior page, however
; well-formed, fails `pragma integrity_check` with "free space corruption"
; (real SQLite never emits interior freeblocks; its balancer rebuilds
; dense). So unlike the leaf carve (reg_free), we register NO block here:
; just reset freehead=0, fragments=0. The freed gap stays unlisted, which
; SQLite accepts (V1 probe). Must run BEFORE the header trim writes ndiv.
; Preserves everything except rax/rcx/rdi.
reg_free_ip:
    xor eax, eax
    lea rdi, [ipage + 1]
    call be16_st                ; freehead = 0
    lea rdi, [ipage + 7]
    mov [rdi], al               ; fragments = 0
    ret

; dec_int(serial in rax, value ptr in rsi): rax=value.
; serials 0/8->0 (no bytes), 9->1 (no bytes), 1->u8, 2->u16be. else -1.
dec_int:
    test rax, rax
    jz di_zero
    cmp rax, 8
    je di_zero
    cmp rax, 9
    je di_one
    cmp rax, 1
    je di_u8
    cmp rax, 2
    je di_u16
    mov rax, -1
    ret
di_zero:
    xor eax, eax
    ret
di_one:
    mov eax, 1
    ret
di_u8:
    movzx eax, byte [rsi]
    ret
di_u16:
    jmp be16_ld

; slen_of(serial in rax): rdx=TEXT byte length (0 for empty serial 0).
; rax=0 ok / 1 bad (non-TEXT).
slen_of:
    test rax, rax
    jz sl_zero
    cmp rax, 13
    jb sl_bad
    test al, 1
    jz sl_bad
    sub rax, 13
    shr rax, 1
    mov rdx, rax
    xor eax, eax
    ret
sl_zero:
    xor edx, edx
    xor eax, eax
    ret
sl_bad:
    mov eax, 1
    ret

; find_table(rsi=name, rdx=namelen): rax=rootpg (0 missing, -1 corrupt),
; rdx=master rowid. Updates [mmaxrowid]. Single pass.
find_table:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov [ftname], rsi
    mov [ftlen], rdx
    mov edi, 1
    lea rsi, [pagebuf]
    call pg_read
    test rax, rax
    jnz ft_err
    cmp byte [pagebuf + 100], 0x0D   ; page-1 b-tree type (file header shift)
    jne ft_err
    lea rsi, [pagebuf + 103]    ; page-1 ncells (100-byte file header shift)
    call be16_ld
    mov rbx, rax
    xor r12d, r12d
ft_cell:
    cmp r12, rbx
    jae ft_missing
    lea rsi, [pagebuf + 108]    ; page-1 ptr array (100-byte file header shift)
    mov rax, r12
    shl rax, 1
    add rsi, rax
    call be16_ld                ; coff
    lea r15, [pagebuf]
    add r15, rax
    lea rdx, [pagebuf + 4096]
    mov rsi, r15
    call varint_get             ; plen
    test rcx, rcx
    jz ft_err
    mov rsi, rcx
    call varint_get             ; rowid
    test rcx, rcx
    jz ft_err
    cmp rax, [mmaxrowid]
    jbe ft_r1
    mov [mmaxrowid], rax
ft_r1:
    mov [tmprow], rax
    mov rsi, rcx
    call varint_get             ; hdrsize
    test rcx, rcx
    jz ft_err
    mov rsi, rcx
    call varint_get             ; s0 type
    test rcx, rcx
    jz ft_err
    mov r14, rax                ; s0
    mov rsi, rcx
    call varint_get             ; s1 name
    test rcx, rcx
    jz ft_err
    mov [ts1], rax
    mov rsi, rcx
    call varint_get             ; s2 tbl
    test rcx, rcx
    jz ft_err
    mov [ts2], rax
    mov rsi, rcx
    mov [ts3p], rsi             ; (reused: s3 value resolve below needs body math)
    call varint_get             ; s3 rootpage
    test rcx, rcx
    jz ft_err
    mov [ts3], rax
    mov rsi, rcx
    call varint_get             ; s4 sql
    test rcx, rcx
    jz ft_err
    mov r11, rcx                ; body
    ; col1 = body + len(s0)
    mov rax, r14
    cmp rax, 0
    je ft_l0z
    cmp rax, 13
    jb ft_err
    test al, 1
    jz ft_err
    sub rax, 13
    shr rax, 1
    jmp ft_l0x
ft_l0z:
    xor eax, eax
ft_l0x:
    add r11, rax                 ; r11 = col1 (name) value
    ; col1 must be TEXT len==ftlen and match
    mov rcx, [ts1]
    cmp rcx, 13
    jb ft_next
    test cl, 1
    jz ft_next
    sub rcx, 13
    shr rcx, 1
    cmp rcx, [ftlen]
    jne ft_next
    mov rsi, r11
    mov rdi, [ftname]
    rep cmpsb
    jne ft_next
    ; match: col3 (rootpage) value = col1 + len(s1) + len(s2)
    mov rax, [ts1]
    call slen_of
    test rax, rax
    jnz ft_err
    add r11, rdx
    mov rax, [ts2]
    call slen_of
    test rax, rax
    jnz ft_err
    add r11, rdx                ; r11 = col3 value
    mov rax, [ts3]
    mov rsi, r11
    call dec_int
    cmp rax, -1
    je ft_err
    test rax, rax
    jz ft_err
    mov rdx, [tmprow]
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret
ft_next:
    inc r12
    jmp ft_cell
ft_missing:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    xor eax, eax
    xor edx, edx
    ret
ft_err:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    mov eax, -1
    ret
; et_mk: m_* preset (name/sql); allocates root leaf, inserts master row.
; rax=new root, 0=fail.
et_mk:
    mov rax, [dbpages]
    inc rax
    mov [et_root], rax
    lea rdi, [leafbuf]
    mov ecx, 4096
    call memzero
    mov byte [leafbuf], 0x0D
    mov rax, 4096
    lea rdi, [leafbuf + 5]
    call be16_st
    mov rdi, [et_root]
    lea rsi, [leafbuf]
    call pg_write
    test rax, rax
    jnz etm_err
    mov rax, [et_root]        ; adopt now: leaf exists; jorig kept original
    mov [dbpages], rax
    mov rax, [mmaxrowid]
    inc rax
    mov [mmaxrowid], rax
    mov [m_rowid], rax
    mov rax, [et_root]
    mov [m_rootpg], rax
    call build_master_cell
    test rax, rax
    jnz etm_err
    call master_place
    test rax, rax
    jnz etm_err
    call hdr_touch
    test rax, rax
    jnz etm_err
    mov rax, [et_root]
    ret
etm_err:
    xor eax, eax
    ret

; ensure_tables: create missing memory tables; fills f_root_*.
; conclusions with root 2 must exist (else foreign db -> err). rax 0/1.
ensure_tables:
    lea rsi, [m_conct]
    mov edx, 11
    call find_table
    cmp rax, 2
    jne et_err
    ; facts
    lea rsi, [t_facts_n]
    mov edx, 5
    call find_table
    test rax, rax
    js et_err
    jnz et_ff
    lea rax, [t_facts_n]
    mov [m_name], rax
    mov qword [m_namelen], 5
    lea rax, [t_facts_sql]
    mov [m_sql], rax
    mov rax, t_facts_sqllen
    mov [m_sqllen], rax
    call et_mk
    test rax, rax
    jz et_err
    mov [f_root_facts], rax
    jmp et_en
et_ff:
    mov [f_root_facts], rax
et_en:
    ; entities
    lea rsi, [t_ent_n]
    mov edx, 8
    call find_table
    test rax, rax
    js et_err
    jnz et_ef
    lea rax, [t_ent_n]
    mov [m_name], rax
    mov qword [m_namelen], 8
    lea rax, [t_ent_sql]
    mov [m_sql], rax
    mov rax, t_ent_sqllen
    mov [m_sqllen], rax
    call et_mk
    test rax, rax
    jz et_err
    mov [f_root_ent], rax
    jmp et_ob
et_ef:
    mov [f_root_ent], rax
et_ob:
    ; observations
    lea rsi, [t_obs_n]
    mov edx, 12
    call find_table
    test rax, rax
    js et_err
    jnz et_of
    lea rax, [t_obs_n]
    mov [m_name], rax
    mov qword [m_namelen], 12
    lea rax, [t_obs_sql]
    mov [m_sql], rax
    mov rax, t_obs_sqllen
    mov [m_sqllen], rax
    call et_mk
    test rax, rax
    jz et_err
    mov [f_root_obs], rax
    jmp et_re
et_of:
    mov [f_root_obs], rax
et_re:
    ; relations
    lea rsi, [t_rel_n]
    mov edx, 9
    call find_table
    test rax, rax
    js et_err
    jnz et_rf
    lea rax, [t_rel_n]
    mov [m_name], rax
    mov qword [m_namelen], 9
    lea rax, [t_rel_sql]
    mov [m_sql], rax
    mov rax, t_rel_sqllen
    mov [m_sqllen], rax
    call et_mk
    test rax, rax
    jz et_err
    mov [f_root_rel], rax
    jmp et_ta
et_rf:
    mov [f_root_rel], rax
et_ta:
    ; tasks
    lea rsi, [t_task_n]
    mov edx, 5
    call find_table
    test rax, rax
    js et_err
    jnz et_tf
    lea rax, [t_task_n]
    mov [m_name], rax
    mov qword [m_namelen], 5
    lea rax, [t_task_sql]
    mov [m_sql], rax
    mov rax, t_task_sqllen
    mov [m_sqllen], rax
    call et_mk
    test rax, rax
    jz et_err
    mov [f_root_tasks], rax
    jmp et_ok
et_tf:
    mov [f_root_tasks], rax
et_ok:
    ; usage (learned preferences; latest rowid wins per key)
    lea rsi, [t_use_n]
    mov edx, 5
    call find_table
    test rax, rax
    js et_err
    jz et_mk_use
    cmp rax, 1                  ; found: root must be sane, else repair
    jb et_repair                ; (pre-width-fix rows decode wild)
    cmp rax, [dbpages]
    ja et_repair
    mov [f_root_use], rax
    jmp et_uok
et_repair:
    lea rsi, [t_use_n]
    mov edx, 5
    call master_drop            ; drop the corrupt row; recreate below
    test rax, rax
    jnz et_err
et_mk_use:
    lea rax, [t_use_n]
    mov [m_name], rax
    mov qword [m_namelen], 5
    lea rax, [t_use_sql]
    mov [m_sql], rax
    mov rax, t_use_sqllen
    mov [m_sqllen], rax
    call et_mk
    test rax, rax
    jz et_err
    mov [f_root_use], rax
    jmp et_uok
et_uok:
    ; tombstones (retention; hidden from reads, bytes remain)
    lea rsi, [t_tomb_n]
    mov edx, 10
    call find_table
    test rax, rax
    js et_err
    jnz et_tf2
    lea rax, [t_tomb_n]
    mov [m_name], rax
    mov qword [m_namelen], 10
    lea rax, [t_tomb_sql]
    mov [m_sql], rax
    mov rax, t_tomb_sqllen
    mov [m_sqllen], rax
    call et_mk
    test rax, rax
    jz et_err
    mov [f_root_tomb], rax
    jmp et_tok
et_tf2:
    mov [f_root_tomb], rax
et_tok:
    xor eax, eax
    ret
et_err:
    mov eax, 1
    ret

; build_record_text: record from colp[0..ncols) + coll[] (all TEXT) with
; rowid [newrowid] -> recbuf/[reclen], celltmp/[clen]. rax 0.
build_record_text:
    push rbx
    lea rdi, [recscratch]
    mov qword [slen], 0
    xor ebx, ebx
brt_col:
    cmp rbx, [ncols]
    jae brt_have
    lea rsi, [coll]
    mov rax, rbx
    shl rax, 3
    add rsi, rax
    mov rax, [rsi]              ; len
    test rax, rax
    jz brt_s0
    lea rax, [rax + rax + 13]
    jmp brt_se
brt_s0:
    xor eax, eax
brt_se:
    lea rdi, [recscratch]
    add rdi, [slen]
    call varint_put
    add [slen], rcx
    inc rbx
    jmp brt_col
brt_have:
    mov rax, [slen]
    inc rax
    mov [reclen], rax
    lea rdi, [recbuf]
    call varint_put
    lea rsi, [recscratch]
    mov rcx, [slen]
    rep movsb
    xor ebx, ebx
brt_body:
    cmp rbx, [ncols]
    jae brt_cell
    lea rsi, [colp]
    mov rax, rbx
    shl rax, 3
    add rsi, rax
    mov rsi, [rsi]
    lea rax, [coll]
    mov rcx, rbx
    shl rcx, 3
    add rax, rcx
    mov rcx, [rax]
    add [reclen], rcx
    rep movsb
    inc rbx
    jmp brt_body
brt_cell:
    lea rdi, [celltmp]
    mov rax, [reclen]
    call varint_put
    mov [clen], rcx
    lea rdi, [celltmp]
    add rdi, rcx
    mov rax, [newrowid]
    call varint_put
    add [clen], rcx
    lea rsi, [recbuf]
    lea rdi, [celltmp]
    add rdi, [clen]
    mov rcx, [reclen]
    add [clen], rcx
    rep movsb
    pop rbx
    xor eax, eax
    ret

; sub_find(field ptr rsi, len rdx, key ptr rdi, keylen rcx): rax=1 hit / 0 miss.
; v3: 32B first-byte candidate lanes (broadcast + movmsk + tzcnt) with
; scalar memcmp confirm; scalar tail (also covers lane-boundary starts).
sub_find:
    test rcx, rcx
    jz sf_no
    cmp rdx, rcx
    jb sf_no
    push rbx
    push r12
    push r13
    mov r12, rsi
    mov r13, rdx
    sub r13, rcx                ; last start offset
    xor ebx, ebx
if defined USE_SCALAR
    jmp sf_loop
else
    push r14
    push r15
    mov r14, rdi                ; needle
    mov r15, rcx                ; needlen
    vpbroadcastb ymm4, [r14]    ; needle[0] x32
av_lane:
    mov rax, rbx
    add rax, 32
    mov rdx, r13
    add rdx, r15                ; fieldlen
    cmp rax, rdx
    ja av_tail                  ; lane would overread: scalar tail
    vmovdqu ymm1, [r12 + rbx]
    vpcmpeqb ymm2, ymm1, ymm4
    vpmovmskb eax, ymm2
    test eax, eax
    jz av_nextlane
av_cand:
    test eax, eax
    jz av_nextlane
    tzcnt ecx, eax              ; candidate bit index
    shr eax, cl
    mov r10, rbx
    add r10, rcx                ; candpos
    cmp r10, r13
    ja av_consume               ; needle cannot fit here
    mov rsi, r12
    add rsi, r10
    mov rdi, r14
    mov rcx, r15
    rep cmpsb
    je av_hit
av_consume:
    shr eax, 1
    jmp av_cand
av_nextlane:
    add rbx, 32
    jmp av_lane
av_tail:
    mov rcx, r15
    mov rdi, r14
    pop r15
    pop r14
    jmp sf_loop
av_hit:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    vzeroupper
    mov eax, 1
    ret
end if
sf_loop:
    cmp rbx, r13
    ja sf_nom
    push rcx
    push rdi
    mov rsi, r12
    add rsi, rbx
sf_cmp:
    test rcx, rcx
    jz sf_hitp
    mov al, [rsi]
    cmp al, [rdi]
    jne sf_nextp
    inc rsi
    inc rdi
    dec rcx
    jmp sf_cmp
sf_hitp:
    pop rdi
    pop rcx
    pop r13
    pop r12
    pop rbx
if defined USE_SCALAR
else
    vzeroupper
end if
    mov eax, 1
    ret
sf_nextp:
    pop rdi
    pop rcx
    inc rbx
    jmp sf_loop
sf_nom:
    pop r13
    pop r12
    pop rbx
sf_no:
if defined USE_SCALAR
    xor eax, eax
    ret
else
    vzeroupper
    xor eax, eax
    ret
end if

; match_status(rsi, rdx=len): rax=0 ok / 1 bad.
match_status:
    push rsi
    push rdx
    lea rdi, [st_ns]
    call cmp_name
    test rax, rax
    jnz ms_ok
    mov rsi, [rsp + 8]
    mov rdx, [rsp]
    lea rdi, [st_ip]
    call cmp_name
    test rax, rax
    jnz ms_ok
    mov rsi, [rsp + 8]
    mov rdx, [rsp]
    lea rdi, [st_dn]
    call cmp_name
    test rax, rax
    jnz ms_ok
    mov rsi, [rsp + 8]
    mov rdx, [rsp]
    lea rdi, [st_ar]
    call cmp_name
    test rax, rax
    jnz ms_ok
    mov rsi, [rsp + 8]
    mov rdx, [rsp]
    lea rdi, [st_ca]
    call cmp_name
    test rax, rax
    jnz ms_ok
    pop rdx
    pop rsi
    mov eax, 1
    ret
ms_ok:
    pop rdx
    pop rsi
    xor eax, eax
    ret

; match_priority(rsi, rdx=len): rax=0 ok / 1 bad.
match_priority:
    push rsi
    push rdx
    lea rdi, [pr_lo]
    call cmp_name
    test rax, rax
    jnz ms_ok2
    mov rsi, [rsp + 8]
    mov rdx, [rsp]
    lea rdi, [pr_me]
    call cmp_name
    test rax, rax
    jnz ms_ok2
    mov rsi, [rsp + 8]
    mov rdx, [rsp]
    lea rdi, [pr_hi]
    call cmp_name
    test rax, rax
    jnz ms_ok2
    mov rsi, [rsp + 8]
    mov rdx, [rsp]
    lea rdi, [pr_cr]
    call cmp_name
    test rax, rax
    jnz ms_ok2
    pop rdx
    pop rsi
    mov eax, 1
    ret
ms_ok2:
    pop rdx
    pop rsi
    xor eax, eax
    ret

; parse_row(rsi=cell abs ptr): growid, gcols, gfo/gfl[0..5] (TEXT cols).
; Non-TEXT or >6-col rows are skipped, not fatal. rax 0 ok / 1 skip / 2 corrupt.
parse_row:
    push rbx
    push r12
    lea rdx, [pagebuf + 4096]
    call varint_get             ; plen
    test rcx, rcx
    jz pr_corrupt
    mov rsi, rcx
    call varint_get             ; rowid
    test rcx, rcx
    jz pr_corrupt
    mov [growid], rax
    mov rsi, rcx
    call varint_get             ; hdrsize
    test rcx, rcx
    jz pr_corrupt
    mov r12, rax
    cmp r12, 128
    jae pr_corrupt
    mov rsi, rcx                ; sptr
    lea rbx, [rsi]
    add rbx, r12
    dec rbx                     ; body = sptr + hval - 1
    xor ecx, ecx                ; k
pr_ser:
    cmp rcx, 8
    jae pr_serdone
    cmp rsi, rbx
    ja pr_serdone2
    cmp rsi, rbx
    je pr_serdone
    lea rdx, [pagebuf + 4096]
    push rcx
    push rsi
    call varint_get
    mov r10, rax
    mov r11, rcx
    pop rsi
    pop rcx
    test r11, r11
    jz pr_corrupt
    lea rax, [stab]
    mov rdx, rcx
    shl rdx, 3
    add rax, rdx
    mov qword [rax], r10
    mov rsi, r11
    inc rcx
    jmp pr_ser
pr_serdone2:
pr_serdone:
    cmp rsi, rbx
    jne pr_corrupt               ; serials must exactly fill header
    mov [gcols], rcx
    mov r12, rbx                ; body
    xor ecx, ecx                ; j
pr_fld:
    cmp rcx, [gcols]
    jae pr_ok
    lea rax, [stab]
    mov rdx, rcx
    shl rdx, 3
    add rax, rdx
    mov rax, qword [rax]
    test rax, rax
    jz pr_f0
    cmp rax, 13
    jb pr_skip
    test al, 1
    jz pr_skip
    sub rax, 13
    shr rax, 1
    jmp pr_f1
pr_f0:
    xor eax, eax
pr_f1:
    lea rdx, [gfo]
    mov rdi, rcx
    shl rdi, 3
    add rdx, rdi
    mov qword [rdx], r12
    lea rdx, [gfl]
    add rdx, rdi
    mov qword [rdx], rax
    add r12, rax
    inc rcx
    jmp pr_fld
pr_ok:
    pop r12
    pop rbx
    xor eax, eax
    ret
pr_skip:
    pop r12
    pop rbx
    mov eax, 1
    ret
pr_corrupt:
    pop r12
    pop rbx
    mov eax, 2
    ret

; ultoa(rax=value>=0, rdi=dest): rcx=len.
ultoa:
    push rbx
    lea rbx, [numtmp + 32]
    mov rcx, 10
ul_loop:
    xor edx, edx
    div rcx
    add dl, '0'
    dec rbx
    mov [rbx], dl
    test rax, rax
    jnz ul_loop
    lea rax, [numtmp + 32]
    sub rax, rbx              ; len
    mov rcx, rax
    mov rsi, rbx
    rep movsb
    mov rcx, rax
    pop rbx
    ret

; dec_atoi(rsi=ptr, rdx=len): rax=value. Digits only, len 1..10, else rax=-1.
dec_atoi:
    test rdx, rdx
    jz da_bad
    cmp rdx, 10
    ja da_bad
    xor eax, eax
da_loop:
    test rdx, rdx
    jz da_done
    movzx ecx, byte [rsi]
    inc rsi
    dec rdx
    cmp cl, '0'
    jb da_bad
    cmp cl, '9'
    ja da_bad
    sub cl, '0'
    imul rax, rax, 10
    movzx ecx, cl
    add rax, rcx
    jmp da_loop
da_done:
    ret
da_bad:
    mov rax, -1
    ret

; scan_key_latest: latest row (max rowid) in table walk with col0 ==
; [mkey]/[mkeylen]. Fills growid, gcols, gfo/gfl[0..4] (TEXT cols).
; rax 1 found / 0 missing / 2 hard-corrupt.
scan_key_latest:
    push rbx
    push r12
    push r13
    push r14
    push r15
    call walk_leaves              ; rdi=rootpg already set by caller
    test rax, rax
    jnz sk_err
    mov r14, [childn]
    test r14, r14
    jz sk_none
sk_page:
    dec r14
    js sk_none
    lea rsi, [childtab]
    mov rax, r14
    shl rax, 3
    add rsi, rax
    mov rdi, [rsi]
    lea rsi, [pagebuf]
    call pg_read
    test rax, rax
    jnz sk_nextpg
    cmp byte [pagebuf], 0x0D
    jne sk_nextpg
    lea rsi, [pagebuf + 3]
    call be16_ld
    mov rbx, rax
    test rbx, rbx
    jz sk_nextpg
    dec rbx                       ; last cell index
sk_cell:
    lea rsi, [pagebuf + 8]
    mov rax, rbx
    shl rax, 1
    add rsi, rax
    call be16_ld                  ; coff
    lea r15, [pagebuf]
    add r15, rax
    lea rdx, [pagebuf + 4096]
    mov rsi, r15
    call varint_get               ; plen
    test rcx, rcx
    jz sk_corrupt
    mov rsi, rcx
    call varint_get               ; rowid
    test rcx, rcx
    jz sk_corrupt
    mov [tmprow], rax
    mov rsi, rcx
    call varint_get               ; hdrsize
    test rcx, rcx
    jz sk_corrupt
    mov r12, rax                  ; hval
    cmp r12, 128
    jae sk_corrupt
    mov rsi, rcx                  ; sptr
    lea r13, [rsi]
    add r13, r12
    dec r13                       ; body = sptr + hval - 1
    xor ecx, ecx                  ; k
sk_ser:
    cmp rcx, 5
    jae sk_serdone
    cmp rsi, r13
    jae sk_serdone
    lea rdx, [pagebuf + 4096]
    push rcx
    push rsi
    call varint_get
    mov r10, rax                  ; serial
    mov r11, rcx                  ; next ptr (0=err)
    pop rsi
    pop rcx
    test r11, r11
    jz sk_corrupt
    lea rax, [stab]
    mov rdx, rcx
    shl rdx, 3
    add rax, rdx
    mov [rax], r10
    mov rsi, r11
    inc rcx
    jmp sk_ser
sk_serdone:
    cmp rsi, r13
    jne sk_corrupt                ; serials must exactly fill header
    mov [gcols], rcx
    ; field offsets from body (TEXT-only tables)
    mov r15, r13                  ; p = body
    xor ecx, ecx                  ; j
sk_fld:
    cmp rcx, [gcols]
    jae sk_fldend
    lea rax, [stab]
    mov rdx, rcx
    shl rdx, 3
    add rax, rdx
    mov rax, [rax]                ; serial
    test rax, rax
    jz sk_f0
    cmp rax, 13
    jb sk_nextcell                ; non-TEXT: row unusable here
    test al, 1
    jz sk_nextcell
    sub rax, 13
    shr rax, 1
    jmp sk_f1
sk_f0:
    xor eax, eax
sk_f1:
    lea rdx, [gfo]
    mov rdi, rcx
    shl rdi, 3
    add rdx, rdi
    mov [rdx], r15                ; gfo[j]
    lea rdx, [gfl]
    add rdx, rdi
    mov [rdx], rax                ; gfl[j]
    add r15, rax
    inc rcx
    jmp sk_fld
sk_fldend:
    ; bound col0 within page, then compare with key
    mov rax, qword [gfo]
    add rax, qword [gfl]
    lea rdx, [pagebuf + 4096]
    cmp rax, rdx
    ja sk_nextcell
    mov rax, qword [gfl]
    cmp rax, [mkeylen]
    jne sk_nextcell
    mov rsi, qword [gfo]
    mov rdi, [mkey]
    mov rcx, rax
    rep cmpsb
    jne sk_nextcell
    ; match: latest wins (descending walk) -> done
    mov rax, [tmprow]
    mov [growid], rax
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    mov eax, 1
    ret
sk_nextcell:
    test rbx, rbx
    jz sk_nextpg
    dec rbx
    jmp sk_cell
sk_nextpg:
    jmp sk_page
sk_none:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    xor eax, eax
    ret
sk_corrupt:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    mov eax, 2
    ret
sk_err:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    mov eax, 2
    ret

; rax 0 notfound / 1 found / 2 corrupt. Found fills fpage/frowid/fo_*/fl_*/fvalid/fvoff.
scan_reason:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov rdi, 2
    call walk_leaves
    test rax, rax
    jnz sr_corrupt
    xor r12d, r12d              ; ci
sr_page:
    cmp r12, [childn]
    jae sr_none
    lea rsi, [childtab]
    mov rax, r12
    shl rax, 3
    add rsi, rax
    mov rdi, [rsi]
    lea rsi, [pagebuf]
    call pg_read
    test rax, rax
    jnz sr_next
    cmp byte [pagebuf], 0x0D
    jne sr_next
    lea rsi, [pagebuf + 3]
    call be16_ld
    mov rbx, rax
    xor r13d, r13d
sr_cell:
    cmp r13, rbx
    jae sr_next
    lea rsi, [pagebuf + 8]
    mov rax, r13
    shl rax, 1
    add rsi, rax
    call be16_ld                ; coff
    lea r15, [pagebuf]
    add r15, rax                ; cell
    lea rdx, [pagebuf + 4096]
    mov rsi, r15
    call varint_get             ; plen
    test rcx, rcx
    jz sr_corrupt
    mov rsi, rcx
    call varint_get             ; rowid
    test rcx, rcx
    jz sr_corrupt
    mov [tmprow], rax
    cmp rax, [maxrowid]
    jbe sr_hadmax
    mov [maxrowid], rax         ; track table max during the walk, so the
sr_hadmax:                      ; oc_insert ++[maxrowid] below is post-lock
    mov rsi, rcx                ; fresh under concurrency (zero extra I/O:
    call varint_get             ; hdrsize every visited cell is read anyway)
    test rcx, rcx
    jz sr_corrupt
    mov rsi, rcx
    call varint_get             ; s0 reason
    test rcx, rcx
    jz sr_corrupt
    mov r14, rax
    mov rsi, rcx
    call varint_get             ; s1 thought
    test rcx, rcx
    jz sr_corrupt
    push rax
    mov rsi, rcx
    call varint_get             ; s2 conclusion
    test rcx, rcx
    jz sr_corrupt2
    push rax
    mov rsi, rcx
    mov [tmpvoff], rsi          ; start of s3 varint
    call varint_get             ; s3 valid
    test rcx, rcx
    jz sr_corrupt3
    mov r10, rax                ; s3
    mov r11, rcx                ; body start
    ; decode s0 (reason must be TEXT non-empty)
    mov rax, r14
    cmp rax, 13
    jb sr_pop3
    test al, 1
    jz sr_pop3
    sub rax, 13
    shr rax, 1                  ; len0
    cmp rax, [rsnlen]
    jne sr_pop3
    ; bounds: body+len0 within page?
    lea rdx, [r11 + rax]
    lea rcx, [pagebuf + 4096]
    cmp rdx, rcx
    ja sr_pop3corrupt
    ; memcmp body vs rsnbuf
    mov rsi, r11
    lea rdi, [rsnbuf]
    mov rcx, rax
    rep cmpsb
    jne sr_pop3
    ; MATCH: decode rest
    pop rax                     ; s2
    pop rdx                     ; s1 (discard, recompute below)
    jmp sr_found
sr_pop3:
    add rsp, 16                 ; drop pushed s2,s1
    inc r13
    jmp sr_cell
sr_pop3corrupt:
    add rsp, 16
    jmp sr_corrupt
sr_corrupt3:
    add rsp, 8
sr_corrupt2:
    add rsp, 8
    jmp sr_corrupt
sr_found:
    ; r11 = body start; s1/s2 need re-decode for offsets. Redecode walk:
    mov rsi, r11
    ; reason already matched: fo_r=r11 abs, fl_r=rsnlen
    lea rax, [pagebuf]
    ; store absolute pointers
    mov [fo_r], r11
    mov rax, [rsnlen]
    mov [fl_r], rax
    add r11, rax                 ; -> thought start
    mov [fo_t], r11
    ; s1 length: re-derive: walk serials again from record
    ; (simplest: rescan serials)
    mov rsi, r15
    lea rdx, [pagebuf + 4096]
    call varint_get
    mov rsi, rcx
    call varint_get
    mov rsi, rcx
    call varint_get             ; hdrsize
    mov rsi, rcx
    call varint_get             ; s0
    mov rsi, rcx
    call varint_get             ; s1 -> rax
    push rax
    mov rsi, rcx
    call varint_get             ; s2 -> rax
    mov r10, rax
    ; s1 len
    pop rax
    cmp rax, 0
    je sr_t0
    sub rax, 13
    shr rax, 1
    jmp sr_t1
sr_t0:
    xor eax, eax
sr_t1:
    mov [fl_t], rax
    mov rcx, [fo_t]
    add rcx, rax
    mov [fo_c], rcx
    mov rax, r10
    sub rax, 13
    shr rax, 1
    mov [fl_c], rax
    ; valid: s3 value in [tmpvoff] byte (8/9 single byte: our writes only)
    mov rsi, [tmpvoff]
    mov al, [rsi]
    cmp al, 8
    je sr_v0
    cmp al, 9
    jne sr_corrupt
    mov byte [fvalid], 1
    jmp sr_vok
sr_v0:
    mov byte [fvalid], 0
sr_vok:
    mov rsi, [tmpvoff]
    lea rax, [pagebuf]
    sub rsi, rax
    mov [fvoff], rsi
    lea rsi, [childtab]
    mov rax, r12
    shl rax, 3
    add rsi, rax
    mov rax, [rsi]
    mov [fpage], rax
    mov rax, [tmprow]
    mov [frowid], rax
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    mov eax, 1
    ret
sr_lengths_bad:
sr_corrupt:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    mov eax, 2
    ret
sr_none:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    xor eax, eax
    ret
sr_next:
    inc r12
    jmp sr_page

; flip_valid: set valid serial at pagebuf+fvoff to [cvalid]?9:8, write fpage.
; rax 0 ok / 1 io.
flip_valid:
    cmp byte [cvalid], 0
    je fv_zero
    mov al, 9
    jmp fv_do
fv_zero:
    mov al, 8
fv_do:
    lea rdi, [pagebuf]
    add rdi, [fvoff]
    mov [rdi], al
    mov rdi, [fpage]
    lea rsi, [pagebuf]
    call pg_write
    ret                           ; rax from pg_write (0/1)

; op_history: {limit? default 10, max 64} -> last N thoughts, oldest first.
op_history:
    mov qword [hlimit], 10
    mov rsi, [pp]
    lea rdi, [k_args]
    mov ecx, 11
    call find_val
    test rax, rax
    jz oh_go
    mov [ap], rax
    mov rsi, [ap]
    lea rdi, [k_limit]
    mov ecx, 7
    call find_val
    test rax, rax
    jz oh_go
    mov rsi, rax
    call parse_int
    test rax, rax
    jnz dc_params
    mov rax, [numval]
    cmp rax, 1
    jb dc_params
    cmp rax, 64
    ja dc_params
    mov [hlimit], rax
oh_go:
    mov rax, [hlimit]
    cmp rax, [hcount]
    jbe oh_nok
    mov rax, [hcount]
oh_nok:
    cmp rax, 64
    jbe oh_nok2
    mov rax, 64
oh_nok2:
    mov [hlimit], rax
    lea rax, [jsontmp]
    mov [outptr], rax
    call out_reset
    lea rsi, [jhisthead]
    call out_cstr
    mov rax, [hcount]
    sub rax, [hlimit]
    mov [hcur], rax
    mov byte [hfirst], 1
oh_entry:
    mov rax, [hcur]
    cmp rax, [hcount]
    jae oh_tail
    cmp qword [outlen], 60000
    ja oh_tail
    cmp byte [hfirst], 1
    je oh_nocomma
    mov al, ','
    call out_byte
    jmp oh_entry2
oh_nocomma:
    mov byte [hfirst], 0
oh_entry2:
    ; slot for thought #(hcur+1): idx = hcur & 63
    mov rax, [hcur]
    and rax, 63
    mov rbx, rax
    shl rbx, 11
    mov rcx, rax
    shl rcx, 6
    add rbx, rcx
    mov rcx, rax
    shl rcx, 5
    add rbx, rcx
    lea rdi, [thslots]
    add rdi, rbx
    mov [hslot], rdi
    lea rsi, [jr_num]
    call out_cstr
    mov rax, [hcur]
    inc rax
    call out_uint
    lea rsi, [jr_total]
    call out_cstr
    mov rdi, [hslot]
    mov rax, [rdi + 2064]
    call out_uint
    lea rsi, [jr_next]
    call out_cstr
    mov rdi, [hslot]
    mov rax, [rdi + 2072]
    test al, 1
    jz oh_hfalse
    lea rsi, [b_true]
    call out_cstr
    jmp oh_hthought
oh_hfalse:
    lea rsi, [b_false]
    call out_cstr
oh_hthought:
    lea rsi, [jr_thought]
    call out_cstr
    mov rdi, [hslot]
    lea rsi, [rdi]
    mov rdx, [rdi + 2048]
    call out_escaped
    mov al, '"'
    call out_byte
    mov rdi, [hslot]
    mov rax, [rdi + 2072]
    test al, 2
    jz oh_hnorev
    lea rsi, [jr_isrev]
    call out_cstr
    mov rdi, [hslot]
    test byte [rdi + 2072], 2
    jz oh_hrevf
    lea rsi, [b_true]
    call out_cstr
    jmp oh_hnorev2
oh_hrevf:
    lea rsi, [b_false]
    call out_cstr
oh_hnorev2:
oh_hnorev:
    mov rdi, [hslot]
    mov rax, [rdi + 2080]
    cmp rax, -1
    je oh_hnorevt
    mov [tmprow], rax
    lea rsi, [jr_rev]
    call out_cstr
    mov rax, [tmprow]
    call out_uint
oh_hnorevt:
    mov rdi, [hslot]
    mov rax, [rdi + 2088]
    cmp rax, -1
    je oh_hnobr
    mov [tmprow], rax
    lea rsi, [jr_brfrom]
    call out_cstr
    mov rax, [tmprow]
    call out_uint
oh_hnobr:
    mov rdi, [hslot]
    cmp qword [rdi + 2096], 0
    je oh_hnobid
    lea rsi, [jr_bid]
    call out_cstr
    mov rdi, [hslot]
    mov rdx, [rdi + 2096]
    lea rsi, [rdi + 2104]
    call out_escaped
    mov al, '"'
    call out_byte
oh_hnobid:
    mov rdi, [hslot]
    mov rax, [rdi + 2072]
    test al, 4
    jz oh_hnomore
    lea rsi, [jr_more]
    call out_cstr
    mov rdi, [hslot]
    test byte [rdi + 2072], 8
    jz oh_hmoref
    lea rsi, [b_true]
    call out_cstr
    jmp oh_hnomore2
oh_hmoref:
    lea rsi, [b_false]
    call out_cstr
oh_hnomore2:
oh_hnomore:
    mov al, '}'
    call out_byte
    inc qword [hcur]
    jmp oh_entry
oh_tail:
    lea rsi, [jhisttail]
    call out_cstr
    mov rax, [hcount]
    call out_uint
    mov al, '}'
    call out_byte
    jmp oc_envelope

; op_reset: {confirm:true} -> clear history.
op_reset:
    mov rsi, [pp]
    lea rdi, [k_args]
    mov ecx, 11
    call find_val
    test rax, rax
    jz dc_params
    mov [ap], rax
    mov rsi, [ap]
    lea rdi, [k_confirm]
    mov ecx, 9
    call find_val
    test rax, rax
    jz dc_params
    mov rsi, rax
    call parse_bool
    test rax, rax
    jnz dc_params
    cmp byte [boolval], 1
    jne dc_params
    mov qword [hcount], 0
    lea rax, [jsontmp]
    mov [outptr], rax
    call out_reset
    lea rsi, [r_resetok]
    call out_cstr
    mov rax, [outlen]
    mov [innerlen], rax
    jmp oc_envelope

; ---- memory: facts (append-only versions, latest rowid wins) ----
; op_fread {name}
op_fread:
    mov rsi, [pp]
    lea rdi, [k_args]
    mov ecx, 11
    call find_val
    test rax, rax
    jz dc_params
    mov [ap], rax
    mov rsi, [ap]
    lea rdi, [k_name]
    mov ecx, 6
    call find_val
    test rax, rax
    jz dc_params
    mov rsi, rax
    lea rdi, [rsnbuf]
    mov ecx, 128
    call parse_str
    test rax, rax
    jz dc_params
    test rdx, rdx
    jz dc_params
    mov [rsnlen], rdx
    lea rsi, [rsnbuf]
    mov rdx, [rsnlen]
    call valid_name
    test rax, rax
    jnz oc_badname
    call db_open
    test rax, rax
    jnz oc_db
    lea rsi, [rsnbuf]
    mov rdx, [rsnlen]
    call is_tombstoned             ; hidden names read as missing
    cmp rax, 1
    je of_miss
    cmp rax, 2
    je oc_corrupt
    lea rsi, [rsnbuf]
    mov rdx, [rsnlen]
    mov [mkey], rsi
    mov [mkeylen], rdx
    mov rdi, [f_root_facts]
    call scan_key_latest
    cmp rax, 1
    jne of_miss
    call db_close
    mov edi, 2                    ; fact use -> learn (stable name identity)
    lea rsi, [rsnbuf]
    mov rdx, [rsnlen]
    call use_bump_name
    ; inner {"rowid":N,"name":"R","body":"B"}
    lea rax, [jsontmp]
    mov [outptr], rax
    mov qword [outlen], 0
    lea rsi, [jc_rowid]
    call out_cstr
    mov rax, [growid]
    call out_uint
    lea rsi, [jn_name]
    call out_cstr
    lea rsi, [rsnbuf]
    mov rdx, [rsnlen]
    call out_escaped
    mov al, '"'
    call out_byte
    lea rsi, [jn_body]
    call out_cstr
    mov rsi, qword [gfo + 8]
    mov rdx, qword [gfl + 8]
    call out_escaped
    mov al, '"'
    call out_byte
    mov al, '}'
    call out_byte
    jmp oc_envelope
of_miss:
    call db_close
    cmp rax, 2
    je oc_corrupt
    lea rdi, [c_params]
    lea rsi, [m_nofile]
    jmp err_id
oc_badname:
    lea rdi, [c_params]
    lea rsi, [m_badname]
    jmp err_id

; op_fwrite {name, text}
op_fwrite:
    mov rsi, [pp]
    lea rdi, [k_args]
    mov ecx, 11
    call find_val
    test rax, rax
    jz dc_params
    mov [ap], rax
    mov rsi, [ap]
    lea rdi, [k_name]
    mov ecx, 6
    call find_val
    test rax, rax
    jz dc_params
    mov rsi, rax
    lea rdi, [rsnbuf]
    mov ecx, 128
    call parse_str
    test rax, rax
    jz dc_params
    test rdx, rdx
    jz dc_params
    mov [rsnlen], rdx
    lea rsi, [rsnbuf]
    mov rdx, [rsnlen]
    call valid_name
    test rax, rax
    jnz oc_badname
    mov rsi, [ap]
    lea rdi, [k_text]
    mov ecx, 6
    call find_val
    test rax, rax
    jz dc_params
    mov rsi, rax
    lea rdi, [mbody]
    mov ecx, 1024
    call parse_str
    test rax, rax
    jz dc_params
    mov [mbodylen], rdx
    lea rsi, [mbody]
    mov rdx, [mbodylen]
    call ascii_only
    test rax, rax
    jnz oc_ascii
    call db_open_ex
    test rax, rax
    jnz oc_db
    lea rsi, [rsnbuf]
    mov rdx, [rsnlen]
    call is_tombstoned             ; tombstoned names stay buried
    cmp rax, 1
    je ow_tomb
    cmp rax, 2
    je ow_dbclose
    mov rdi, [f_root_facts]
    call tail_max
    test rax, rax
    jnz ow_dbclose
    mov rax, [maxrowid]
    inc rax
    mov [newrowid], rax
    lea rax, [rsnbuf]
    mov qword [colp], rax
    mov rax, [rsnlen]
    mov qword [coll], rax
    lea rax, [mbody]
    mov qword [colp + 8], rax
    mov rax, [mbodylen]
    mov qword [coll + 8], rax
    mov qword [ncols], 2
    call build_record_text
    mov rax, [f_root_facts]
    mov [splitroot], rax
    call place_cell
    test rax, rax
    jnz ow_insfail
    mov rax, [newrowid]
    mov [maxrowid], rax
    call hdr_touch
    mov edi, 2                    ; each version re-asserts the name
    lea rsi, [rsnbuf]
    mov rdx, [rsnlen]
    call use_conf_name
    call db_close
    lea rax, [jsontmp]
    mov [outptr], rax
    mov qword [outlen], 0
    lea rsi, [jc_rowid]
    call out_cstr
    mov rax, [newrowid]
    call out_uint
    lea rsi, [jn_name]
    call out_cstr
    lea rsi, [rsnbuf]
    mov rdx, [rsnlen]
    call out_escaped
    mov al, '"'
    call out_byte
    mov al, '}'
    call out_byte
    jmp oc_envelope
ow_dbclose:
    call db_close
    lea rdi, [c_internal]
    lea rsi, [m_nodb]
    jmp err_id
ow_tomb:
    call db_close
    lea rdi, [c_params]
    lea rsi, [m_tomb]
    jmp err_id
ow_insfail:
    cmp rax, 3
    je ow_big
    cmp rax, 2
    je ow_full
    call db_close
    lea rdi, [c_internal]
    lea rsi, [m_nodb]
    jmp err_id
ow_big:
    call db_close
    lea rdi, [c_params]
    lea rsi, [m_big]
    jmp err_id
ow_full:
    call db_close
    lea rdi, [c_internal]
    lea rsi, [m_dbfull]
    jmp err_id

; op_flist {} -> newline-joined names, newest first, distinct (cap 128).
op_flist:
    call db_open
    test rax, rax
    jnz oc_db
    mov rdi, [f_root_facts]
    call walk_leaves
    test rax, rax
    jnz ow_dbclose
    lea rax, [jsontmp]
    mov [outptr], rax
    mov qword [outlen], 0
    mov qword [fseenn], 0
    mov byte [hfirst], 1
    mov rax, [childn]
    test rax, rax
    jz olf_tail
    dec rax
    mov [wn], rax                ; start at last page index
ofl_page:
    lea rsi, [childtab]
    mov rax, [wn]
    shl rax, 3
    add rsi, rax
    mov rdi, [rsi]
    mov [scurpg], rdi               ; tomb walk reuses pagebuf: restore point
    lea rsi, [pagebuf]
    call pg_read
    test rax, rax
    jnz olf_nextpg
    cmp byte [pagebuf], 0x0D
    jne olf_nextpg
    lea rsi, [pagebuf + 3]
    call be16_ld
    test rax, rax
    jz olf_nextpg
    mov rbx, rax
    dec rbx                       ; last cell index
ofl_cell:
    lea rsi, [pagebuf + 8]
    mov rax, rbx
    shl rax, 1
    add rsi, rax
    call be16_ld                  ; coff
    lea r15, [pagebuf]
    add r15, rax
    lea rdx, [pagebuf + 4096]
    mov rsi, r15
    call varint_get               ; plen
    test rcx, rcx
    jz olf_nextcell
    mov rsi, rcx
    call varint_get               ; rowid (skip value)
    test rcx, rcx
    jz olf_nextcell
    mov rsi, rcx
    call varint_get               ; hdrsize
    test rcx, rcx
    jz olf_nextcell
    mov rsi, rcx
    call varint_get               ; s0 = name serial
    test rcx, rcx
    jz olf_nextcell
    mov r10, rax
    cmp r10, 13
    jb olf_nextcell
    test r10b, 1
    jz olf_nextcell
    sub r10, 13
    shr r10, 1                    ; namelen
    cmp r10, 128
    ja olf_nextcell
    mov rsi, rcx
    call varint_get               ; s1 = body serial (skip to body)
    test rcx, rcx
    jz olf_nextcell
    mov r11, rcx                  ; body = col0 (name) value
    ; bound check
    mov rax, r11
    add rax, r10
    lea rdx, [pagebuf + 4096]
    cmp rax, rdx
    ja olf_nextcell
    ; seen?
    xor r12d, r12d
ofl_seen:
    cmp r12, [fseenn]
    jae olf_add
    lea rsi, [fseen]
    mov rax, r12
    imul rax, rax, 129
    add rsi, rax
    movzx eax, byte [rsi]
    cmp rax, r10
    jne olf_nextseen
    lea rdi, [rsi + 1]
    mov rsi, r11
    mov rcx, r10
    rep cmpsb
    je olf_nextcell               ; dup: skip (newest already emitted)
olf_nextseen:
    inc r12
    jmp ofl_seen
olf_add:
    cmp qword [fseenn], 128
    jae olf_tail                  ; seen-set full: stop
    cmp qword [outlen], 60000
    ja olf_tail
    mov rsi, r11                  ; copy name aside: tomb walk reuses pagebuf
    lea rdi, [rsnbuf]
    mov rcx, r10
    rep movsb
    mov [rsnlen], r10
    lea rsi, [rsnbuf]
    mov rdx, [rsnlen]
    call is_tombstoned
    cmp rax, 1
    je olf_skip                   ; hidden: restore page, skip all output
    cmp rax, 2
    je ow_dbclose
    mov rdi, [scurpg]             ; restore facts page clobbered above
    lea rsi, [pagebuf]
    call pg_read
    test rax, rax
    jnz olf_nextcell
    cmp byte [hfirst], 1
    je olf_first
    mov al, '\'
    call out_byte
    mov al, 'n'
    call out_byte
    jmp olf_emit
olf_first:
    mov byte [hfirst], 0
olf_emit:
    lea rsi, [rsnbuf]
    mov rdx, [rsnlen]
    call out_escaped
    ; store in seen
    lea rdi, [fseen]
    mov rax, [fseenn]
    imul rax, rax, 129
    add rdi, rax
    mov rax, [rsnlen]
    mov [rdi], al                 ; len byte
    lea rsi, [rsnbuf]
    lea rdi, [rdi + 1]
    mov rcx, [rsnlen]
    rep movsb
    inc qword [fseenn]
    jmp olf_nextcell
olf_skip:
    mov rdi, [scurpg]               ; same restore on the skip path
    lea rsi, [pagebuf]
    call pg_read
    test rax, rax
    jnz olf_nextpg
    jmp olf_nextcell
olf_nextcell:
    test rbx, rbx
    jz olf_nextpg
    dec rbx
    jmp ofl_cell
olf_nextpg:
    cmp qword [wn], 0
    je olf_tail
    dec qword [wn]
    jmp ofl_page
olf_tail:
    call db_close
    mov rax, [outlen]
    mov [innerlen], rax
    jmp oc_envelope

; ---- memory: entities / observations / relations ----
; insert_obs: obsbuf/oblen -> observations row for rsnbuf entity. rax 0/1/2.
; Call with db open; updates [newrowid] chain via [obsseq].
insert_obs:
    mov rdi, [f_root_obs]
    call tail_max
    test rax, rax
    jnz iob_err
    mov rax, [maxrowid]
    inc rax
    mov [newrowid], rax
    lea rax, [rsnbuf]
    mov qword [colp], rax
    mov rax, [rsnlen]
    mov qword [coll], rax
    lea rax, [obsbuf]
    mov qword [colp + 8], rax
    mov rax, [oblen]
    mov qword [coll + 8], rax
    mov qword [ncols], 2
    call build_record_text
    mov rax, [f_root_obs]
    mov [splitroot], rax
    call place_cell
    test rax, rax
    jnz iob_err
    mov rax, [newrowid]
    mov [maxrowid], rax
    xor eax, eax
    ret
iob_err:
    mov eax, 1
    ret

; op_mkentity {name, type?, project?, observations?[]}
op_mkentity:
    mov rsi, [pp]
    lea rdi, [k_args]
    mov ecx, 11
    call find_val
    test rax, rax
    jz dc_params
    mov [ap], rax
    mov rsi, [ap]
    lea rdi, [k_name]
    mov ecx, 6
    call find_val
    test rax, rax
    jz dc_params
    mov rsi, rax
    lea rdi, [rsnbuf]
    mov ecx, 128
    call parse_str
    test rax, rax
    jz dc_params
    test rdx, rdx
    jz dc_params
    mov [rsnlen], rdx
    lea rsi, [rsnbuf]
    mov rdx, [rsnlen]
    call valid_name
    test rax, rax
    jnz oc_badname
    ; type? default ""
    mov qword [typelen], 0
    mov rsi, [ap]
    lea rdi, [k_type]
    mov ecx, 6
    call find_val
    test rax, rax
    jz om_notype
    mov rsi, rax
    lea rdi, [typebuf]
    mov ecx, 32
    call parse_str
    test rax, rax
    jz dc_params
    mov [typelen], rdx
    lea rsi, [typebuf]
    mov rdx, [typelen]
    call ascii_only
    test rax, rax
    jnz oc_ascii
om_notype:
    ; project? default ""
    mov qword [projlen], 0
    mov rsi, [ap]
    lea rdi, [k_project]
    mov ecx, 9
    call find_val
    test rax, rax
    jz om_noproj
    mov rsi, rax
    lea rdi, [projbuf]
    mov ecx, 32
    call parse_str
    test rax, rax
    jz dc_params
    mov [projlen], rdx
    lea rsi, [projbuf]
    mov rdx, [projlen]
    call ascii_only
    test rax, rax
    jnz oc_ascii
om_noproj:
    call db_open_ex
    test rax, rax
    jnz oc_db
    lea rsi, [rsnbuf]
    mov rdx, [rsnlen]
    call is_tombstoned
    cmp rax, 1
    je ow_tomb
    cmp rax, 2
    je om_dbclose
    ; dup? -> return existing, created:false
    lea rsi, [rsnbuf]
    mov rdx, [rsnlen]
    mov [mkey], rsi
    mov [mkeylen], rdx
    mov rdi, [f_root_ent]
    call scan_key_latest
    cmp rax, 1
    je om_dup
    cmp rax, 2
    je om_corrupt
    mov rdi, [f_root_ent]
    call tail_max
    test rax, rax
    jnz om_dbclose
    mov rax, [maxrowid]
    inc rax
    mov [newrowid], rax
    lea rax, [rsnbuf]
    mov qword [colp], rax
    mov rax, [rsnlen]
    mov qword [coll], rax
    lea rax, [typebuf]
    mov qword [colp + 8], rax
    mov rax, [typelen]
    mov qword [coll + 8], rax
    lea rax, [projbuf]
    mov qword [colp + 16], rax
    mov rax, [projlen]
    mov qword [coll + 16], rax
    mov qword [ncols], 3
    call build_record_text
    mov rax, [f_root_ent]
    mov [splitroot], rax
    call place_cell
    test rax, rax
    jnz om_insfail
    mov rax, [newrowid]
    mov [maxrowid], rax
    call hdr_touch
    mov byte [mcreated], 1
    jmp om_obs
om_dup:
    mov rax, [growid]
    mov [newrowid], rax
    mov byte [mcreated], 0
    jmp om_obs
om_obs:
    ; observations[]? each ascii<=1024, cap 16
    mov rsi, [ap]
    lea rdi, [k_obs]
    mov ecx, 14
    call find_val
    test rax, rax
    jz om_done
    cmp rax, [le]
    jae dc_params_close
    cmp byte [rax], '['
    jne dc_params_close
    inc rax
    mov [obsarr], rax
    xor ebx, ebx                ; count
om_oloop:
    cmp ebx, 16
    jae om_done
    mov rsi, [obsarr]
    call skip_ws_comma
    test rax, rax
    jnz om_arrend
    mov rsi, [obsarr]
    cmp rsi, [le]
    jae dc_params_close
    cmp byte [rsi], ']'
    je om_arrend
    cmp byte [rsi], '"'
    jne dc_params_close
    lea rdi, [obsbuf]
    mov ecx, 1024
    call parse_str
    test rax, rax
    jz dc_params_close
    mov [obsarr], rax
    mov [oblen], rdx
    lea rsi, [obsbuf]
    mov rdx, [oblen]
    call ascii_only
    test rax, rax
    jnz oc_ascii_close
    call insert_obs
    test rax, rax
    jnz om_insfail
    inc rbx
    jmp om_oloop
om_arrend:
    test rbx, rbx               ; empty array ok (no-op)
    jmp om_done2
om_done:
om_done2:
    call hdr_touch
    call db_close
    lea rax, [jsontmp]
    mov [outptr], rax
    mov qword [outlen], 0
    lea rsi, [jc_rowid]
    call out_cstr
    mov rax, [newrowid]
    call out_uint
    lea rsi, [jn_name]
    call out_cstr
    lea rsi, [rsnbuf]
    mov rdx, [rsnlen]
    call out_escaped
    mov al, '"'
    call out_byte
    lea rsi, [jn_created]
    call out_cstr
    cmp byte [mcreated], 0
    je om_cfalse
    lea rsi, [b_true]
    call out_cstr
    jmp oc_inner_end
om_cfalse:
    lea rsi, [b_false]
    call out_cstr
    jmp oc_inner_end
om_dbclose:
    call db_close
    lea rdi, [c_internal]
    lea rsi, [m_nodb]
    jmp err_id
om_insfail:
    cmp rax, 3
    je om_big
    cmp rax, 2
    je om_full
    call db_close
    lea rdi, [c_internal]
    lea rsi, [m_nodb]
    jmp err_id
om_big:
    call db_close
    lea rdi, [c_params]
    lea rsi, [m_big]
    jmp err_id
om_full:
    call db_close
    lea rdi, [c_internal]
    lea rsi, [m_dbfull]
    jmp err_id
om_corrupt:
    call db_close
    lea rdi, [c_internal]
    lea rsi, [m_nodb]
    jmp err_id
dc_params_close:
    call db_close
    lea rdi, [c_params]
    lea rsi, [m_params]
    jmp err_id
oc_ascii_close:
    call db_close
    lea rdi, [c_params]
    lea rsi, [m_ascii]
    jmp err_id

; skip_ws_comma: rsi=ptr -> rax=0 ok (at value or ']'), rsi advanced; uses [le].
skip_ws_comma:
skw_loop:
    cmp rsi, [le]
    jae skw_end
    mov al, [rsi]
    cmp al, ' '
    je skw_adv
    cmp al, 9
    je skw_adv
    cmp al, 13
    je skw_adv
    cmp al, 10
    je skw_adv
    cmp al, ','
    je skw_adv
    mov [obsarr], rsi
    xor eax, eax
    ret
skw_adv:
    inc rsi
    jmp skw_loop
skw_end:
    mov [obsarr], rsi
    xor eax, eax
    ret

; op_addobs {name, observations[1..16]}
op_addobs:
    mov rsi, [pp]
    lea rdi, [k_args]
    mov ecx, 11
    call find_val
    test rax, rax
    jz dc_params
    mov [ap], rax
    mov rsi, [ap]
    lea rdi, [k_name]
    mov ecx, 6
    call find_val
    test rax, rax
    jz dc_params
    mov rsi, rax
    lea rdi, [rsnbuf]
    mov ecx, 128
    call parse_str
    test rax, rax
    jz dc_params
    test rdx, rdx
    jz dc_params
    mov [rsnlen], rdx
    lea rsi, [rsnbuf]
    mov rdx, [rsnlen]
    call valid_name
    test rax, rax
    jnz oc_badname
    mov rsi, [ap]
    lea rdi, [k_obs]
    mov ecx, 14
    call find_val
    test rax, rax
    jz dc_params
    cmp rax, [le]
    jae dc_params
    cmp byte [rax], '['
    jne dc_params
    inc rax
    mov [obsarr], rax
    call db_open_ex
    test rax, rax
    jnz oc_db
    lea rsi, [rsnbuf]
    mov rdx, [rsnlen]
    call is_tombstoned
    cmp rax, 1
    je ow_tomb
    cmp rax, 2
    je om_dbclose
    ; ensure entity (auto-create stub)
    lea rsi, [rsnbuf]
    mov rdx, [rsnlen]
    mov [mkey], rsi
    mov [mkeylen], rdx
    mov rdi, [f_root_ent]
    call scan_key_latest
    cmp rax, 2
    je om_corrupt
    cmp rax, 1
    je oa_have
    ; stub entity
    mov rdi, [f_root_ent]
    call tail_max
    test rax, rax
    jnz om_dbclose
    mov rax, [maxrowid]
    inc rax
    mov [newrowid], rax
    lea rax, [rsnbuf]
    mov qword [colp], rax
    mov rax, [rsnlen]
    mov qword [coll], rax
    lea rax, [typebuf]
    mov qword [colp + 8], rax
    mov qword [coll + 8], 0
    lea rax, [projbuf]
    mov qword [colp + 16], rax
    mov qword [coll + 16], 0
    mov qword [ncols], 3
    call build_record_text
    mov rax, [f_root_ent]
    mov [splitroot], rax
    call place_cell
    test rax, rax
    jnz om_insfail
    mov rax, [newrowid]
    mov [maxrowid], rax
oa_have:
    xor ebx, ebx
oa_loop:
    cmp ebx, 16
    jae oa_done
    mov rsi, [obsarr]
    call skip_ws_comma
    mov rsi, [obsarr]
    cmp rsi, [le]
    jae oa_bad
    cmp byte [rsi], ']'
    je oa_end
    cmp byte [rsi], '"'
    jne oa_bad
    lea rdi, [obsbuf]
    mov ecx, 1024
    call parse_str
    test rax, rax
    jz oa_bad
    mov [obsarr], rax
    mov [oblen], rdx
    lea rsi, [obsbuf]
    mov rdx, [oblen]
    call ascii_only
    test rax, rax
    jnz oc_ascii_close
    call insert_obs
    test rax, rax
    jnz om_insfail
    inc rbx
    jmp oa_loop
oa_end:
    test rbx, rbx
    jz oa_bad                   ; observations required non-empty here
    jmp oa_done2
oa_bad:
    call db_close
    lea rdi, [c_params]
    lea rsi, [m_params]
    jmp err_id
oa_done:
oa_done2:
    mov [obadded], rbx
    call hdr_touch
    call db_close
    lea rax, [jsontmp]
    mov [outptr], rax
    mov qword [outlen], 0
    lea rsi, [jc_rowid]
    call out_cstr
    mov rax, [newrowid]
    call out_uint
    lea rsi, [jn_name]
    call out_cstr
    lea rsi, [rsnbuf]
    mov rdx, [rsnlen]
    call out_escaped
    mov al, '"'
    call out_byte
    lea rsi, [jn_added]
    call out_cstr
    mov rax, [obadded]
    call out_uint
    mov al, '}'
    call out_byte
    jmp oc_envelope

; op_mkrel {from, to, type}
op_mkrel:
    mov rsi, [pp]
    lea rdi, [k_args]
    mov ecx, 11
    call find_val
    test rax, rax
    jz dc_params
    mov [ap], rax
    mov rsi, [ap]
    lea rdi, [k_from]
    mov ecx, 6
    call find_val
    test rax, rax
    jz dc_params
    mov rsi, rax
    lea rdi, [rsnbuf]
    mov ecx, 128
    call parse_str
    test rax, rax
    jz dc_params
    test rdx, rdx
    jz dc_params
    mov [rsnlen], rdx
    lea rsi, [rsnbuf]
    mov rdx, [rsnlen]
    call valid_name
    test rax, rax
    jnz oc_badname
    mov rsi, [ap]
    lea rdi, [k_to]
    mov ecx, 4
    call find_val
    test rax, rax
    jz dc_params
    mov rsi, rax
    lea rdi, [relbuf]
    mov ecx, 128
    call parse_str
    test rax, rax
    jz dc_params
    test rdx, rdx
    jz dc_params
    mov [rllen], rdx
    lea rsi, [relbuf]
    mov rdx, [rllen]
    call valid_name
    test rax, rax
    jnz oc_badname
    mov rsi, [ap]
    lea rdi, [k_type]
    mov ecx, 6
    call find_val
    test rax, rax
    jz dc_params
    mov rsi, rax
    lea rdi, [typebuf]
    mov ecx, 32
    call parse_str
    test rax, rax
    jz dc_params
    test rdx, rdx
    jz dc_params
    mov [typelen], rdx
    lea rsi, [typebuf]
    mov rdx, [typelen]
    call ascii_only
    test rax, rax
    jnz oc_ascii
    call db_open_ex
    test rax, rax
    jnz oc_db
    lea rsi, [rsnbuf]
    mov rdx, [rsnlen]
    call is_tombstoned             ; endpoints must be live
    cmp rax, 1
    je ow_tomb
    cmp rax, 2
    je om_dbclose
    lea rsi, [relbuf]
    mov rdx, [rllen]
    call is_tombstoned
    cmp rax, 1
    je ow_tomb
    cmp rax, 2
    je om_dbclose
    ; dup triple? scan all rel rows for exact match
    mov rdi, [f_root_rel]
    call walk_leaves
    test rax, rax
    jnz om_dbclose
    xor ebx, ebx                ; dup flag
    mov r12, [childn]
    xor r13d, r13d
or_page:
    cmp r13, r12
    jae or_nodup
    lea rsi, [childtab]
    mov rax, r13
    shl rax, 3
    add rsi, rax
    mov rdi, [rsi]
    lea rsi, [pagebuf]
    call pg_read
    test rax, rax
    jnz or_nextpg
    cmp byte [pagebuf], 0x0D
    jne or_nextpg
    lea rsi, [pagebuf + 3]
    call be16_ld
    mov r14, rax
    xor r15d, r15d
or_cell:
    cmp r15, r14
    jae or_nextpg
    ; parse 3 TEXT cols via generic walk into gfo/gfl
    lea rsi, [pagebuf + 8]
    mov rax, r15
    shl rax, 1
    add rsi, rax
    call be16_ld
    lea rdi, [pagebuf]
    add rdi, rax                ; cell
    lea rdx, [pagebuf + 4096]
    mov rsi, rdi
    call varint_get
    test rcx, rcx
    jz or_nextcell
    mov rsi, rcx
    call varint_get
    test rcx, rcx
    jz or_nextcell
    mov [tmprow], rax
    mov rsi, rcx
    call varint_get             ; hdr
    test rcx, rcx
    jz or_nextcell
    mov r12, rax
    cmp r12, 128
    jae or_nextcell
    mov rsi, rcx
    xor ecx, ecx                ; k
or_ser:
    cmp rcx, 3
    jae or_serhave
    lea rdx, [pagebuf + 4096]
    push rcx
    push rsi
    call varint_get
    mov r10, rax                ; serial
    mov r11, rcx                ; next
    pop rsi
    pop rcx
    test r11, r11
    jz or_nextcell
    lea rax, [stab]
    mov rdx, rcx
    shl rdx, 3
    add rax, rdx
    mov qword [rax], r10
    mov rsi, r11
    inc rcx
    jmp or_ser
or_serhave:
    mov r11, rsi                ; body
    xor ecx, ecx                ; j
or_off:
    cmp rcx, 3
    jae or_cmp3
    lea rax, [stab]
    mov rdx, rcx
    shl rdx, 3
    add rax, rdx
    mov rax, qword [rax]        ; serial
    test rax, rax
    jz or_o0
    cmp rax, 13
    jb or_nextcell
    test al, 1
    jz or_nextcell
    sub rax, 13
    shr rax, 1
    jmp or_o1
or_o0:
    xor eax, eax
or_o1:
    lea rdx, [gfo]
    mov rdi, rcx
    shl rdi, 3
    add rdx, rdi
    mov qword [rdx], r11
    lea rdx, [gfl]
    add rdx, rdi
    mov qword [rdx], rax
    add r11, rax
    inc rcx
    jmp or_off
or_cmp3:
    ; bound last field, then compare 3 cols with from/to/type
    mov rax, qword [gfo + 16]
    add rax, qword [gfl + 16]
    lea rdx, [pagebuf + 4096]
    cmp rax, rdx
    ja or_nextcell
    mov rax, qword [gfl]
    cmp rax, [rsnlen]
    jne or_nextcell
    mov rsi, qword [gfo]
    lea rdi, [rsnbuf]
    mov rcx, rax
    rep cmpsb
    jne or_nextcell
    mov rax, qword [gfl + 8]
    cmp rax, [rllen]
    jne or_nextcell
    mov rsi, qword [gfo + 8]
    lea rdi, [relbuf]
    mov rcx, rax
    rep cmpsb
    jne or_nextcell
    mov rax, qword [gfl + 16]
    cmp rax, [typelen]
    jne or_nextcell
    mov rsi, qword [gfo + 16]
    lea rdi, [typebuf]
    mov rcx, rax
    rep cmpsb
    jne or_nextcell
    mov ebx, 1                  ; dup
    mov rax, [tmprow]
    mov [newrowid], rax         ; report existing rowid
    jmp or_nodup
or_nextcell:
    inc r15
    jmp or_cell
or_nextpg:
    inc r13
    jmp or_page
or_nodup:
    test rbx, rbx
    jnz or_dupret
    mov rdi, [f_root_rel]
    call tail_max
    test rax, rax
    jnz om_dbclose
    mov rax, [maxrowid]
    inc rax
    mov [newrowid], rax
    lea rax, [rsnbuf]
    mov qword [colp], rax
    mov rax, [rsnlen]
    mov qword [coll], rax
    lea rax, [relbuf]
    mov qword [colp + 8], rax
    mov rax, [rllen]
    mov qword [coll + 8], rax
    lea rax, [typebuf]
    mov qword [colp + 16], rax
    mov rax, [typelen]
    mov qword [coll + 16], rax
    mov qword [ncols], 3
    call build_record_text
    mov rax, [f_root_rel]
    mov [splitroot], rax
    call place_cell
    test rax, rax
    jnz om_insfail
    mov rax, [newrowid]
    mov [maxrowid], rax
    call hdr_touch
or_dupret:
    call db_close
    lea rax, [jsontmp]
    mov [outptr], rax
    mov qword [outlen], 0
    lea rsi, [jc_rowid]
    call out_cstr
    mov rax, [newrowid]
    call out_uint
    lea rsi, [jn_from]
    call out_cstr
    lea rsi, [rsnbuf]
    mov rdx, [rsnlen]
    call out_escaped
    mov al, '"'
    call out_byte
    lea rsi, [jn_to]
    call out_cstr
    lea rsi, [relbuf]
    mov rdx, [rllen]
    call out_escaped
    mov al, '"'
    call out_byte
    lea rsi, [jn_type]
    call out_cstr
    lea rsi, [typebuf]
    mov rdx, [typelen]
    call out_escaped
    mov al, '"'
    call out_byte
    mov al, '}'
    call out_byte
    jmp oc_envelope

; search_table: LIKE [qbuf]/[qlen] over table [sroot], mode [smode]:
; 0=entities (col0|col1), 1=observations (col1), 2=facts (col0|col1).
; Appends {"kind","name","text"} entries while [scount]<[slim], budget ok.
; rax 0 ok / 1 walk-fail.
search_table:
    push rbx
    mov qword [sncol], 0          ; rank within this table's hits
    mov rdi, [sroot]
    call walk_leaves
    test rax, rax
    jnz st_err
    mov qword [stci], 0
st_page:
    mov rax, [stci]
    cmp rax, [childn]
    jae st_done
    lea rsi, [childtab]
    shl rax, 3
    add rsi, rax
    mov rdi, [rsi]
    mov [scurpg], rdi
    lea rsi, [pagebuf]
    call pg_read_nc               ; full scan: probe ok, no fill (keep hot set)
    test rax, rax
    jnz st_nextpg
    cmp byte [pagebuf], 0x0D
    jne st_nextpg
    lea rsi, [pagebuf + 3]
    call be16_ld
    mov [stn], rax
    mov qword [stcell], 0
st_cell:
    mov rax, [stcell]
    cmp rax, [stn]
    jae st_nextpg
    lea rsi, [pagebuf + 8]
    shl rax, 1
    add rsi, rax
    call be16_ld
    mov [stcoff], rax               ; cell offset for ranked re-emit
    lea rsi, [pagebuf]
    add rsi, rax
    call parse_row
    test rax, rax
    jnz st_nextcell
    cmp qword [gcols], 2
    jb st_nextcell
    cmp qword [smode], 1
    je st_m1
    ; modes 0,2: col0 or col1
    mov rsi, qword [gfo]
    mov rdx, qword [gfl]
    lea rdi, [qbuf]
    mov rcx, [qlen]
    call sub_find
    test rax, rax
    jnz st_hit
    mov rsi, qword [gfo + 8]
    mov rdx, qword [gfl + 8]
    lea rdi, [qbuf]
    mov rcx, [qlen]
    call sub_find
    test rax, rax
    jz st_nextcell
    jmp st_hit
st_m1:
    ; observations: col1 only
    mov rsi, qword [gfo + 8]
    mov rdx, qword [gfl + 8]
    lea rdi, [qbuf]
    mov rcx, [qlen]
    call sub_find
    test rax, rax
    jz st_nextcell
st_hit:
    test rax, rax
    jz st_nextcell
    ; hidden names (fact/entity, or obs of a hidden entity) never surface.
    ; NB: copy aside first: the tomb walk reuses pagebuf, which gfo points
    ; into. is_tombstoned key must never alias pagebuf (same rule applies
    ; to all callers: pass rsnbuf/relbuf/fseen, never gfo).
    mov rcx, qword [gfl]
    cmp rcx, 128
    ja st_noname                  ; longer than any valid name: can't match
    mov rsi, qword [gfo]
    lea rdi, [rsnbuf]
    rep movsb
    mov rax, qword [gfl]
    mov [rsnlen], rax
    lea rsi, [rsnbuf]
    mov rdx, [rsnlen]
    call is_tombstoned
    cmp rax, 1
    je st_skip
    cmp rax, 2
    je os_dbclose
    mov rdi, [scurpg]               ; restore scan page (tomb walk reused pagebuf)
    lea rsi, [pagebuf]
    call pg_read
    test rax, rax
    jnz st_nextpg
    jmp st_collect
st_skip:
    mov rdi, [scurpg]               ; same restore on the skip path
    lea rsi, [pagebuf]
    call pg_read
    test rax, rax
    jnz st_nextpg
    jmp st_nextcell
st_noname:
    mov qword [rsnlen], -1       ; no name to rank by (score 0 at collect)
    jmp st_collect
st_collect:
    ; collect (score,mode,pgno,celloff) for usage-ranked emission
    mov rax, [sncol]
    cmp rax, 64
    jae st_sortemit              ; buffer full: rank + emit now
    mov rax, [smode]
    cmp rax, 1
    je stc_obs                   ; observations: stable rowid identity
    cmp qword [rsnlen], 0
    jl stc_noname                ; overlong field guard above: score 0
    mov rdi, [smode]
    lea rsi, [rsnbuf]
    mov rdx, [rsnlen]
    call use_score_name
    jmp stc_store
stc_obs:
    mov rdi, 1
    mov rsi, [growid]
    call use_score_id
    jmp stc_store
stc_noname:
    xor eax, eax
stc_store:
    mov rcx, [sncol]
    shl rcx, 5
    lea rdx, [sbuf]
    add rdx, rcx
    mov [rdx], rax
    mov rcx, [smode]
    mov [rdx + 8], rcx
    mov rcx, [scurpg]
    mov [rdx + 16], rcx
    mov rcx, [stcoff]
    mov [rdx + 24], rcx
    inc qword [sncol]
    mov rdi, [scurpg]               ; tomb walk reused pagebuf: restore
    lea rsi, [pagebuf]
    call pg_read
    test rax, rax
    jnz st_nextpg
    jmp st_nextcell
st_sortemit:
    ; insertion sort sbuf[0..sncol) by score desc, stable (ties keep walk order)
    mov qword [sidx], 1
ss_outer:
    mov rax, [sidx]
    cmp rax, [sncol]
    jae ss_emit
    mov rcx, rax
    shl rcx, 5
    lea rsi, [sbuf]
    add rsi, rcx
    lea rdi, [sbtmp]
    mov ecx, 4
    rep movsq
    mov rax, [sidx]
ss_inner:
    test rax, rax
    jz ss_place
    mov rcx, rax
    dec rcx
    shl rcx, 5
    lea rdx, [sbuf]
    add rdx, rcx
    mov rcx, [rdx]
    mov rsi, qword [sbtmp]
    cmp rcx, rsi
    jge ss_place
    mov rsi, rdx
    mov rcx, rax
    shl rcx, 5
    lea rdi, [sbuf]
    add rdi, rcx
    mov ecx, 4
    rep movsq
    dec rax
    jmp ss_inner
ss_place:
    shl rax, 5
    lea rdi, [sbuf]
    add rdi, rax
    lea rsi, [sbtmp]
    mov ecx, 4
    rep movsq
    inc qword [sidx]
    jmp ss_outer
ss_emit:
    mov rax, [slim]
    sub rax, [scount]               ; remaining across the 3 table passes
    jb ss_nonemit
    cmp rax, [sncol]
    cmova rax, [sncol]              ; nemit = min(remaining, collected)
    mov [nemit], rax
    mov qword [sidx], 0
    jmp se_loop
ss_nonemit:
    xor eax, eax
    mov [nemit], rax
    mov qword [sidx], 0
    jmp se_loop
se_loop:
    mov rax, [sidx]
    cmp rax, [nemit]
    jae se_done
    cmp qword [outlen], 60000
    ja se_done
    mov rcx, rax
    shl rcx, 5
    lea rdx, [sbuf]
    add rdx, rcx
    mov rcx, [rdx + 8]
    mov [smode], rcx
    mov rcx, [rdx + 16]
    mov [scurpg], rcx
    mov rcx, [rdx + 24]
    mov [stcoff], rcx
    mov rdi, [scurpg]
    lea rsi, [pagebuf]
    call pg_read                ; cache-hot re-read
    test rax, rax
    jnz se_next
    cmp byte [pagebuf], 0x0D
    jne se_next
    lea rsi, [pagebuf]
    add rsi, [stcoff]
    call parse_row
    test rax, rax
    jnz se_next
    mov rax, [smode]
    cmp rax, 1
    je se_obs                    ; observations: stable rowid identity
    mov rdi, [smode]
    mov rsi, qword [gfo]         ; col0 = name (facts, entities)
    mov rdx, qword [gfl]
    call use_bump_name           ; surfaced -> learn
    jmp se_emitted
se_obs:
    mov rdi, 1
    mov rsi, [growid]
    call use_bump_id
se_emitted:
    call st_emit
se_next:
    inc qword [sidx]
    jmp se_loop
se_done:
    pop rbx
    xor eax, eax
    ret
st_emit:
    cmp byte [hfirst], 1
    je st_first
    mov al, ','
    call out_byte
    jmp st_put
st_first:
    mov byte [hfirst], 0
st_put:
    lea rsi, [jn_kind]
    call out_cstr
    cmp qword [smode], 0
    je st_kent
    cmp qword [smode], 1
    je st_kobs
    lea rsi, [kd_fact]
    call out_cstr
    jmp st_kend
st_kent:
    lea rsi, [kd_ent]
    call out_cstr
    jmp st_kend
st_kobs:
    lea rsi, [kd_obs]
    call out_cstr
st_kend:
    mov al, '"'
    call out_byte
    lea rsi, [jn_name]
    call out_cstr
    mov rsi, qword [gfo]
    mov rdx, qword [gfl]
    call out_escaped
    mov al, '"'
    call out_byte
    lea rsi, [jn_text]
    call out_cstr
    cmp qword [smode], 0
    je st_tent
    mov rsi, qword [gfo + 8]
    mov rdx, qword [gfl + 8]
    call out_escaped
    jmp st_tend
st_tent:
    mov rsi, qword [gfo + 8]
    mov rdx, qword [gfl + 8]
    call out_escaped
st_tend:
    mov al, '"'
    call out_byte
    mov al, '}'
    call out_byte
    inc qword [scount]
    ret                         ; end st_emit
st_nextcell:
    inc qword [stcell]
    jmp st_cell
st_nextpg:
    inc qword [stci]
    jmp st_page
st_done:
    jmp st_sortemit              ; scan complete: rank + emit collected
st_err:
    pop rbx
    mov eax, 1
    ret

; tomb_insert(rsi=name, rdx=len): append one tombstone row. Db open+locked.
; rax 0 ok / 1 io-or-full. Preserves rbx,rbp,r12-r15.
tomb_insert:
    push rbx
    push r12
    mov [tombnm], rsi
    mov [tombnl], rdx
    mov rdi, [f_root_tomb]
    call tail_max
    test rax, rax
    jnz ti_err
    mov rax, [maxrowid]
    inc rax
    mov [newrowid], rax
    mov rsi, [tombnm]
    mov rdx, [tombnl]
    mov qword [colp], rsi
    mov qword [coll], rdx
    mov qword [ncols], 1
    call build_record_text
    mov rax, [f_root_tomb]
    mov [splitroot], rax
    call place_cell
    test rax, rax
    jnz ti_err
    mov rax, [newrowid]
    mov [maxrowid], rax
    call hdr_touch
    test rax, rax
    jnz ti_err
    pop r12
    pop rbx
    xor eax, eax
    ret
ti_err:
    pop r12
    pop rbx
    mov eax, 1
    ret

; op_delete {name}: tombstone one fact/entity name (write-once; bytes remain).
op_delete:
    mov rsi, [pp]
    lea rdi, [k_args]
    mov ecx, 11
    call find_val
    test rax, rax
    jz dc_params
    mov [ap], rax
    mov rsi, [ap]
    lea rdi, [k_name]
    mov ecx, 6
    call find_val
    test rax, rax
    jz dc_params
    mov rsi, rax
    lea rdi, [rsnbuf]
    mov ecx, 128
    call parse_str
    test rax, rax
    jz dc_params
    test rdx, rdx
    jz dc_params
    mov [rsnlen], rdx
    lea rsi, [rsnbuf]
    mov rdx, [rsnlen]
    call valid_name
    test rax, rax
    jnz oc_badname
    call db_open_ex
    test rax, rax
    jnz oc_db
    lea rsi, [rsnbuf]
    mov rdx, [rsnlen]
    call is_tombstoned
    cmp rax, 1
    je od_dup
    cmp rax, 2
    je om_dbclose
    lea rsi, [rsnbuf]
    mov rdx, [rsnlen]
    mov [mkey], rsi
    mov [mkeylen], rdx
    mov rdi, [f_root_facts]
    call scan_key_latest          ; must have a version to bury
    cmp rax, 2
    je om_dbclose
    cmp rax, 1
    jne od_nothing
    lea rsi, [rsnbuf]
    mov rdx, [rsnlen]
    call tomb_insert
    test rax, rax
    jnz om_dbclose
    call db_close
    lea rax, [jsontmp]
    mov [outptr], rax
    mov qword [outlen], 0
    lea rsi, [jn_versions]
    call out_cstr
    lea rsi, [rsnbuf]
    mov rdx, [rsnlen]
    call out_escaped
    mov al, '"'
    call out_byte
    lea rsi, [jn_deleted]
    call out_cstr
    lea rsi, [b_true]
    call out_cstr
    mov al, '}'
    call out_byte
    jmp oc_envelope
od_nothing:
    call db_close
    lea rdi, [c_params]
    lea rsi, [m_nofile]
    jmp err_id
od_dup:
    call db_close
    lea rax, [jsontmp]
    mov [outptr], rax
    mov qword [outlen], 0
    lea rsi, [jn_versions]
    call out_cstr
    lea rsi, [rsnbuf]
    mov rdx, [rsnlen]
    call out_escaped
    mov al, '"'
    call out_byte
    lea rsi, [jn_deleted]
    call out_cstr
    lea rsi, [b_false]
    call out_cstr
    lea rsi, [jn_note]
    call out_cstr
    lea rsi, [m_already]
    call out_cstr
    mov al, '"'
    call out_byte
    mov al, '}'
    call out_byte
    jmp oc_envelope

; collect_prefix(rdi=root): distinct names starting with qbuf/qlen into
; fseen/fseenn (cap 128, sets dpcap). rax 0 ok / 1 io. No output.
collect_prefix:
    push rbx
    push r12
    push r15
    call walk_leaves
    test rax, rax
    jnz cp_err
    mov rax, [childn]
    test rax, rax
    jz cp_done
    dec rax
    mov [wn], rax
cp_page:
    lea rsi, [childtab]
    mov rax, [wn]
    shl rax, 3
    add rsi, rax
    mov rdi, [rsi]
    lea rsi, [pagebuf]
    call pg_read
    test rax, rax
    jnz cp_nextpg
    cmp byte [pagebuf], 0x0D
    jne cp_nextpg
    lea rsi, [pagebuf + 3]
    call be16_ld
    test rax, rax
    jz cp_nextpg
    mov rbx, rax
    dec rbx
cp_cell:
    lea rsi, [pagebuf + 8]
    mov rax, rbx
    shl rax, 1
    add rsi, rax
    call be16_ld
    lea r15, [pagebuf]
    add r15, rax
    lea rdx, [pagebuf + 4096]
    mov rsi, r15
    call varint_get
    test rcx, rcx
    jz cp_nextcell
    mov rsi, rcx
    call varint_get
    test rcx, rcx
    jz cp_nextcell
    mov rsi, rcx
    call varint_get
    test rcx, rcx
    jz cp_nextcell
    mov rsi, rcx
    call varint_get
    test rcx, rcx
    jz cp_nextcell
    mov r10, rax
    cmp r10, 13
    jb cp_nextcell
    test r10b, 1
    jz cp_nextcell
    sub r10, 13
    shr r10, 1
    cmp r10, 128
    ja cp_nextcell
    mov rsi, rcx
    call varint_get               ; s1 = body serial (skip to body)
    test rcx, rcx
    jz cp_nextcell
    mov r11, rcx                  ; body = col0 (name) value
    mov rax, r11
    add rax, r10
    lea rdx, [pagebuf + 4096]
    cmp rax, rdx
    ja cp_nextcell
    ; prefix?
    mov rcx, [qlen]
    cmp r10, rcx
    jb cp_nextcell
    mov rsi, r11
    lea rdi, [qbuf]
    rep cmpsb
    jne cp_nextcell
    ; seen?
    xor r12d, r12d
cp_seen:
    cmp r12, [fseenn]
    jae cp_add
    lea rsi, [fseen]
    mov rax, r12
    imul rax, rax, 129
    add rsi, rax
    movzx eax, byte [rsi]
    cmp rax, r10
    jne cp_nextseen
    lea rdi, [rsi + 1]
    mov rsi, r11
    mov rcx, r10
    rep cmpsb
    je cp_nextcell
cp_nextseen:
    inc r12
    jmp cp_seen
cp_add:
    cmp qword [fseenn], 128
    jae cp_full
    lea rdi, [fseen]
    mov rax, [fseenn]
    imul rax, rax, 129
    add rdi, rax
    mov rax, r10
    mov [rdi], al
    mov rsi, r11
    lea rdi, [rdi + 1]
    mov rcx, r10
    rep movsb
    inc qword [fseenn]
cp_nextcell:
    test rbx, rbx
    jz cp_nextpg
    dec rbx
    jmp cp_cell
cp_nextpg:
    cmp qword [wn], 0
    je cp_done
    dec qword [wn]
    jmp cp_page
cp_full:
    mov qword [dpcap], 1
cp_done:
    pop r15
    pop r12
    pop rbx
    xor eax, eax
    ret
cp_err:
    pop r15
    pop r12
    pop rbx
    mov eax, 1
    ret

; op_delprefix {prefix}: tombstone all facts/entities starting with prefix.
op_delprefix:
    mov rsi, [pp]
    lea rdi, [k_args]
    mov ecx, 11
    call find_val
    test rax, rax
    jz dc_params
    mov [ap], rax
    mov rsi, [ap]
    lea rdi, [k_prefix]
    mov ecx, 8
    call find_val
    test rax, rax
    jz dc_params
    mov rsi, rax
    lea rdi, [qbuf]
    mov ecx, 128
    call parse_str
    test rax, rax
    jz dc_params
    test rdx, rdx
    jz dc_params
    mov [qlen], rdx
    lea rsi, [qbuf]
    mov rdx, [qlen]
    call ascii_only
    test rax, rax
    jnz oc_ascii
    call db_open_ex
    test rax, rax
    jnz oc_db
    mov qword [fseenn], 0
    mov qword [dpcap], 0
    mov qword [scount], 0
    mov rdi, [f_root_facts]
    call collect_prefix
    test rax, rax
    jnz om_dbclose
    mov rdi, [f_root_ent]
    call collect_prefix
    test rax, rax
    jnz om_dbclose
    mov qword [stci], 0
dp_each:
    mov rax, [stci]
    cmp rax, [fseenn]
    jae dp_done
    lea rsi, [fseen]
    imul rax, rax, 129
    add rsi, rax
    movzx edx, byte [rsi]
    lea rsi, [rsi + 1]
    call is_tombstoned
    cmp rax, 1
    je dp_next
    cmp rax, 2
    je om_dbclose
    mov rax, [stci]
    lea rsi, [fseen]
    imul rax, rax, 129
    add rsi, rax
    movzx edx, byte [rsi]
    lea rsi, [rsi + 1]
    call tomb_insert
    test rax, rax
    jnz om_dbclose
    inc qword [scount]
dp_next:
    inc qword [stci]
    jmp dp_each
dp_done:
    call db_close
    lea rax, [jsontmp]
    mov [outptr], rax
    mov qword [outlen], 0
    lea rsi, [jn_prefix]
    call out_cstr
    lea rsi, [qbuf]
    mov rdx, [qlen]
    call out_escaped
    mov al, '"'
    call out_byte
    lea rsi, [jn_tombed]
    call out_cstr
    mov rax, [scount]
    call out_uint
    lea rsi, [jn_capped]
    call out_cstr
    cmp qword [dpcap], 0
    je dp_uncapped
    lea rsi, [b_true]
    call out_cstr
    jmp dp_tail
dp_uncapped:
    lea rsi, [b_false]
    call out_cstr
dp_tail:
    mov al, '}'
    call out_byte
    jmp oc_envelope

; op_versions {name, limit?}: every version of a fact, newest first.
op_versions:
    mov rsi, [pp]
    lea rdi, [k_args]
    mov ecx, 11
    call find_val
    test rax, rax
    jz dc_params
    mov [ap], rax
    mov rsi, [ap]
    lea rdi, [k_name]
    mov ecx, 6
    call find_val
    test rax, rax
    jz dc_params
    mov rsi, rax
    lea rdi, [rsnbuf]
    mov ecx, 128
    call parse_str
    test rax, rax
    jz dc_params
    test rdx, rdx
    jz dc_params
    mov [rsnlen], rdx
    lea rsi, [rsnbuf]
    mov rdx, [rsnlen]
    call valid_name
    test rax, rax
    jnz oc_badname
    mov qword [slim], 20
    mov rsi, [ap]
    lea rdi, [k_limit]
    mov ecx, 7
    call find_val
    test rax, rax
    jz ov_nolim
    mov rsi, rax
    call parse_int
    test rax, rax
    jnz dc_params
    mov rax, [numval]
    cmp rax, 1
    jb dc_params
    cmp rax, 20
    ja dc_params
    mov [slim], rax
ov_nolim:
    call db_open
    test rax, rax
    jnz oc_db
    lea rsi, [rsnbuf]
    mov rdx, [rsnlen]
    call is_tombstoned
    cmp rax, 2
    je oc_corrupt
    mov [ts1], rax                ; tombstoned flag (0/1)
    lea rax, [jsontmp]
    mov [outptr], rax
    call out_reset
    lea rsi, [jn_versions]
    call out_cstr
    lea rsi, [rsnbuf]
    mov rdx, [rsnlen]
    call out_escaped
    mov al, '"'
    call out_byte
    lea rsi, [jn_tombflag]
    call out_cstr
    cmp qword [ts1], 0
    je ov_live
    lea rsi, [b_true]
    call out_cstr
    jmp ov_arr
ov_live:
    lea rsi, [b_false]
    call out_cstr
ov_arr:
    lea rsi, [jn_versarr]
    call out_cstr
    mov byte [hfirst], 1
    mov qword [scount], 0
    mov rdi, [f_root_facts]
    call walk_leaves
    test rax, rax
    jnz ov_dbclose
    mov rax, [childn]
    test rax, rax
    jz ov_tail
    dec rax
    mov [wn], rax
ov_page:
    lea rsi, [childtab]
    mov rax, [wn]
    shl rax, 3
    add rsi, rax
    mov rdi, [rsi]
    lea rsi, [pagebuf]
    call pg_read
    test rax, rax
    jnz ov_nextpg
    cmp byte [pagebuf], 0x0D
    jne ov_nextpg
    lea rsi, [pagebuf + 3]
    call be16_ld
    test rax, rax
    jz ov_nextpg
    mov rbx, rax
    dec rbx
ov_cell:
    lea rsi, [pagebuf + 8]
    mov rax, rbx
    shl rax, 1
    add rsi, rax
    call be16_ld
    lea rsi, [pagebuf]
    add rsi, rax
    lea rdx, [pagebuf + 4096]
    call varint_get
    test rcx, rcx
    jz ov_nextcell
    mov rsi, rcx
    call varint_get
    test rcx, rcx
    jz ov_nextcell
    mov [tmprow], rax             ; rowid
    mov rsi, rcx
    call varint_get
    test rcx, rcx
    jz ov_nextcell
    mov rsi, rcx
    call varint_get               ; s0 = name serial
    test rcx, rcx
    jz ov_nextcell
    mov r10, rax
    cmp r10, 13
    jb ov_nextcell
    test r10b, 1
    jz ov_nextcell
    sub r10, 13
    shr r10, 1                    ; namelen
    cmp r10, [rsnlen]
    jne ov_nextcell
    mov rsi, rcx
    call varint_get               ; s1 = body serial
    test rcx, rcx
    jz ov_nextcell
    mov r12, rax
    cmp r12, 13
    jb ov_nextcell
    test r12b, 1
    jz ov_nextcell
    sub r12, 13
    shr r12, 1                    ; bodylen
    mov r11, rcx                  ; body = col0 (name) value
    mov rax, r11
    add rax, r10
    add rax, r12                  ; col1 end
    lea rdx, [pagebuf + 4096]
    cmp rax, rdx
    ja ov_nextcell
    mov rsi, r11
    lea rdi, [rsnbuf]
    mov rcx, r10
    rep cmpsb
    jne ov_nextcell
    mov rsi, r11
    add rsi, r10                  ; col1 (body) value
    mov [ulkey], rsi              ; borrow as scratch (no load/flush here)
    mov [ulhits], r12
    ; cap + budget
    mov rax, [scount]
    cmp rax, [slim]
    jae ov_tail
    cmp qword [outlen], 60000
    ja ov_tail
    cmp byte [hfirst], 1
    je ov_first
    mov al, ','
    call out_byte
    jmp ov_emit
ov_first:
    mov byte [hfirst], 0
ov_emit:
    mov al, '{'
    call out_byte
    lea rsi, [jc_rowid + 1]       ; '"rowid":' (skip leading {)
    call out_cstr
    mov rax, [tmprow]
    call out_uint
    lea rsi, [jn_body]
    call out_cstr
    mov rsi, [ulkey]
    mov rdx, [ulhits]
    call out_escaped
    mov al, '"'
    call out_byte
    lea rsi, [jn_current]
    call out_cstr
    cmp qword [scount], 0
    je ov_cur
    lea rsi, [b_false]
    call out_cstr
    jmp ov_emitted
ov_cur:
    lea rsi, [b_true]
    call out_cstr
ov_emitted:
    mov al, '}'
    call out_byte
    inc qword [scount]
ov_nextcell:
    test rbx, rbx
    jz ov_nextpg
    dec rbx
    jmp ov_cell
ov_nextpg:
    cmp qword [wn], 0
    je ov_tail
    dec qword [wn]
    jmp ov_page
ov_tail:
    call db_close
    mov al, ']'
    call out_byte
    mov al, '}'
    call out_byte
    jmp oc_envelope
ov_dbclose:
    call db_close
    lea rdi, [c_internal]
    lea rsi, [m_nodb]
    jmp err_id

; op_health {}: diagnostics for operators.
; op_feedback {name, signal, kind?}: pos/neg++, tick, inline durable flush.
; Tombstoned names are refused with an explicit shape (ranking the buried
; teaches nothing). Phantom names are accepted (ranking only affects
; surfaced rows) and documented.
op_feedback:
    mov rsi, [pp]
    lea rdi, [k_args]
    mov ecx, 11
    call find_val
    test rax, rax
    jz dc_params
    mov [ap], rax
    mov rsi, [ap]
    lea rdi, [k_name]
    mov ecx, 6
    call find_val
    test rax, rax
    jz dc_params
    mov rsi, rax
    lea rdi, [rsnbuf]
    mov ecx, 128
    call parse_str
    test rax, rax
    jz dc_params
    test rdx, rdx
    jz dc_params
    mov [rsnlen], rdx
    lea rsi, [rsnbuf]
    mov rdx, [rsnlen]
    call valid_name
    test rax, rax
    jnz oc_badname
    mov qword [fbkind], 2
    mov rsi, [ap]
    lea rdi, [k_kind]
    mov ecx, 6
    call find_val
    test rax, rax
    jz ofb_sig
    mov rsi, rax
    lea rdi, [sigbuf]
    mov ecx, 16
    call parse_str
    test rax, rax
    jz dc_params
    test rdx, rdx
    jz dc_params
    mov [siglen], rdx
    lea rsi, [sigbuf]
    mov rdx, [siglen]
    lea rdi, [v_fact]
    call cmp_name
    test rax, rax
    jnz ofb_fact
    lea rsi, [sigbuf]
    mov rdx, [siglen]
    lea rdi, [v_entity]
    call cmp_name
    test rax, rax
    jnz ofb_ent
    lea rsi, [sigbuf]
    mov rdx, [siglen]
    lea rdi, [v_obs]
    call cmp_name
    test rax, rax
    jnz ofb_obs
    lea rsi, [sigbuf]
    mov rdx, [siglen]
    lea rdi, [v_task]
    call cmp_name
    test rax, rax
    jnz ofb_task
    jmp dc_params
ofb_fact:
    mov qword [fbkind], 2
    jmp ofb_sig
ofb_ent:
    mov qword [fbkind], 0
    jmp ofb_sig
ofb_obs:
    mov qword [fbkind], 1
    jmp ofb_sig
ofb_task:
    mov qword [fbkind], 3
ofb_sig:
    mov rsi, [ap]
    lea rdi, [k_signal]
    mov ecx, 8
    call find_val
    test rax, rax
    jz dc_params
    mov rsi, rax
    lea rdi, [sigbuf]
    mov ecx, 16
    call parse_str
    test rax, rax
    jz dc_params
    test rdx, rdx
    jz dc_params
    mov [siglen], rdx
    lea rsi, [sigbuf]
    mov rdx, [siglen]
    lea rdi, [v_useful]
    call cmp_name
    test rax, rax
    jnz ofb_pos
    lea rsi, [sigbuf]
    mov rdx, [siglen]
    lea rdi, [v_mislead]
    call cmp_name
    test rax, rax
    jnz ofb_neg
    jmp dc_params
ofb_pos:
    mov qword [fbsig], 1
    jmp ofb_open
ofb_neg:
    mov qword [fbsig], 0
ofb_open:
    cmp qword [fbkind], 1
    jne ofb_db
    lea rsi, [rsnbuf]
    mov rdx, [rsnlen]
    call dec_parse               ; observations: decimal rowid identity
    test rax, rax
    jz dc_params
    test rdx, rdx
    jz dc_params
    mov [fbobsid], rdx
ofb_db:
    call db_open_ex
    test rax, rax
    jnz oc_db
    lea rsi, [rsnbuf]
    mov rdx, [rsnlen]
    call is_tombstoned
    cmp rax, 1
    je ofb_tomb
    cmp rax, 2
    je om_dbclose
    cmp qword [fbkind], 1
    je ofb_obsbump
    mov rdi, [fbkind]
    lea rsi, [rsnbuf]
    mov rdx, [rsnlen]
    mov rcx, [fbsig]
    call use_fb_name
    jmp ofb_flush
ofb_obsbump:
    mov rdi, 1
    mov rsi, [fbobsid]
    mov rdx, [fbsig]
    call use_fb_id
ofb_flush:
    call use_flush               ; durable on return: no silent loss
    test rax, rax
    jnz om_dbclose
    call db_close
    lea rax, [jsontmp]
    mov [outptr], rax
    mov qword [outlen], 0
    lea rsi, [jn_versions]
    call out_cstr
    lea rsi, [rsnbuf]
    mov rdx, [rsnlen]
    call out_escaped
    mov al, '"'
    call out_byte
    lea rsi, [jn_signal]
    call out_cstr
    lea rsi, [sigbuf]
    mov rdx, [siglen]
    call out_escaped
    mov al, '"'
    call out_byte
    lea rsi, [jn_recorded]
    call out_cstr
    lea rsi, [b_true]
    call out_cstr
    mov al, '}'
    call out_byte
    jmp oc_envelope
ofb_tomb:
    call db_close
    lea rax, [jsontmp]
    mov [outptr], rax
    mov qword [outlen], 0
    lea rsi, [jn_versions]
    call out_cstr
    lea rsi, [rsnbuf]
    mov rdx, [rsnlen]
    call out_escaped
    mov al, '"'
    call out_byte
    lea rsi, [jn_recorded]
    call out_cstr
    lea rsi, [b_false]
    call out_cstr
    lea rsi, [jn_note]
    call out_cstr
    lea rsi, [m_tomb]
    call out_cstr
    mov al, '"'
    call out_byte
    mov al, '}'
    call out_byte
    jmp oc_envelope
; op_explain {name, kind?}: why a memory ranks as it does. Read-only.
op_explain:
    mov rsi, [pp]
    lea rdi, [k_args]
    mov ecx, 11
    call find_val
    test rax, rax
    jz dc_params
    mov [ap], rax
    mov rsi, [ap]
    lea rdi, [k_name]
    mov ecx, 6
    call find_val
    test rax, rax
    jz dc_params
    mov rsi, rax
    lea rdi, [rsnbuf]
    mov ecx, 128
    call parse_str
    test rax, rax
    jz dc_params
    test rdx, rdx
    jz dc_params
    mov [rsnlen], rdx
    lea rsi, [rsnbuf]
    mov rdx, [rsnlen]
    call valid_name
    test rax, rax
    jnz oc_badname
    mov qword [fbkind], 2
    mov rsi, [ap]
    lea rdi, [k_kind]
    mov ecx, 6
    call find_val
    test rax, rax
    jz oex_db
    mov rsi, rax
    lea rdi, [sigbuf]
    mov ecx, 16
    call parse_str
    test rax, rax
    jz dc_params
    test rdx, rdx
    jz dc_params
    mov [siglen], rdx
    lea rsi, [sigbuf]
    mov rdx, [siglen]
    lea rdi, [v_fact]
    call cmp_name
    test rax, rax
    jnz oex_db
    lea rsi, [sigbuf]
    mov rdx, [siglen]
    lea rdi, [v_entity]
    call cmp_name
    test rax, rax
    jnz oex_ent
    lea rsi, [sigbuf]
    mov rdx, [siglen]
    lea rdi, [v_obs]
    call cmp_name
    test rax, rax
    jnz oex_obs
    lea rsi, [sigbuf]
    mov rdx, [siglen]
    lea rdi, [v_task]
    call cmp_name
    test rax, rax
    jnz oex_task
    jmp dc_params
oex_ent:
    mov qword [fbkind], 0
    jmp oex_db
oex_obs:
    mov qword [fbkind], 1
    jmp oex_db
oex_task:
    mov qword [fbkind], 3
oex_db:
    cmp qword [fbkind], 1
    jne oex_open
    lea rsi, [rsnbuf]
    mov rdx, [rsnlen]
    call dec_parse
    test rax, rax
    jz dc_params
    test rdx, rdx
    jz dc_params
    mov [fbobsid], rdx
oex_open:
    call db_open
    test rax, rax
    jnz oc_db
    cmp qword [fbkind], 1
    je oex_obslookup
    mov rdi, [fbkind]
    lea rsi, [rsnbuf]
    mov rdx, [rsnlen]
    call use_slot_name
    jmp oex_got
oex_obslookup:
    mov rdi, 1
    mov rsi, [fbobsid]
    call use_slot_id
oex_got:
    test rax, rax
    jz oex_zero
    push rdx
    call uscore
    mov [exscore], rax
    pop rdx
    mov eax, [rdx + 12]
    mov dword [exacc], eax
    mov eax, [rdx + 16]
    mov dword [expos], eax
    mov eax, [rdx + 20]
    mov dword [exneg], eax
    mov eax, [rdx + 24]
    mov dword [exlast], eax
    movzx eax, word [rdx + 28]
    mov dword [exconf], eax
    jmp oex_close
oex_zero:
    mov qword [exscore], 0
    mov qword [exacc], 0
    mov qword [expos], 0
    mov qword [exneg], 0
    mov qword [exlast], 0
    mov qword [exconf], 0
oex_close:
    mov eax, dword [utick]
    mov dword [exnow], eax
    call db_close
    lea rax, [jsontmp]
    mov [outptr], rax
    mov qword [outlen], 0
    lea rsi, [jn_versions]
    call out_cstr
    lea rsi, [rsnbuf]
    mov rdx, [rsnlen]
    call out_escaped
    mov al, '"'
    call out_byte
    lea rsi, [jn_kindkey]
    call out_cstr
    mov rax, [fbkind]
    call out_uint
    lea rsi, [jn_access]
    call out_cstr
    mov rax, [exacc]
    call out_uint
    lea rsi, [jn_useful]
    call out_cstr
    mov rax, [expos]
    call out_uint
    lea rsi, [jn_mislead]
    call out_cstr
    mov rax, [exneg]
    call out_uint
    lea rsi, [jn_last]
    call out_cstr
    mov rax, [exlast]
    call out_uint
    lea rsi, [jn_now]
    call out_cstr
    mov rax, [exnow]
    call out_uint
    lea rsi, [jn_conf]
    call out_cstr
    mov rax, [exconf]
    call out_uint
    lea rsi, [jn_score]
    call out_cstr
    mov rax, [exscore]
    call out_uint
    lea rsi, [jn_weights]
    call out_cstr
    mov rax, U_WA
    call out_uint
    lea rsi, [jn_wp]
    call out_cstr
    mov rax, U_WP
    call out_uint
    lea rsi, [jn_wn]
    call out_cstr
    mov rax, U_WN
    call out_uint
    lea rsi, [jn_wr]
    call out_cstr
    mov rax, U_WR
    call out_uint
    lea rsi, [jn_wc]
    call out_cstr
    mov rax, U_WC
    call out_uint
    mov al, '}'
    call out_byte
    lea rsi, [jn_window]
    call out_cstr
    mov rax, U_RWIN
    call out_uint
    mov al, '}'
    call out_byte
    jmp oc_envelope
op_health:
    call db_open
    test rax, rax
    jnz oc_db
    mov qword [scount], 0
    cmp qword [f_root_facts], 0
    je oh_1
    inc qword [scount]
oh_1:
    cmp qword [f_root_ent], 0
    je oh_2
    inc qword [scount]
oh_2:
    cmp qword [f_root_obs], 0
    je oh_3
    inc qword [scount]
oh_3:
    cmp qword [f_root_rel], 0
    je oh_4
    inc qword [scount]
oh_4:
    cmp qword [f_root_tasks], 0
    je oh_5
    inc qword [scount]
oh_5:
    cmp qword [f_root_use], 0
    je oh_6
    inc qword [scount]
oh_6:
    cmp qword [f_root_tomb], 0
    je oh_7
    inc qword [scount]
oh_7:
    mov rax, [dbpages]
    mov [tmprow], rax
    call jhave
    mov [ts1], rax
    xor ecx, ecx
    xor eax, eax
oh_cache:
    cmp rcx, 16
    jae oh_cached
    lea rsi, [cpg]
    mov rdx, rcx
    shl rdx, 3
    cmp qword [rsi + rdx], 0
    je oh_cnext
    inc rax
oh_cnext:
    inc rcx
    jmp oh_cache
oh_cached:
    mov [ts2], rax
    xor ecx, ecx
    xor eax, eax
oh_use:
    cmp rcx, USLOTS
    jae oh_used
    mov rdx, rcx
    shl rdx, 5                  ; USLOT_SZ
    lea rsi, [utab]
    cmp qword [rsi + rdx], 0
    je oh_unext
    inc rax
oh_unext:
    inc rcx
    jmp oh_use
oh_used:
    mov [ts3], rax
    call db_close
    lea rax, [jsontmp]
    mov [outptr], rax
    mov qword [outlen], 0
    lea rsi, [jn_tables]
    call out_cstr
    mov rax, [scount]
    call out_uint
    lea rsi, [jn_pages]
    call out_cstr
    mov rax, [tmprow]
    call out_uint
    lea rsi, [jn_journal]
    call out_cstr
    cmp qword [ts1], 0
    je oh_nj
    lea rsi, [b_true]
    call out_cstr
    jmp oh_nw
oh_nj:
    lea rsi, [b_false]
    call out_cstr
oh_nw:
    lea rsi, [jn_cacheused]
    call out_cstr
    mov rax, [ts2]
    call out_uint
    lea rsi, [jn_tracked]
    call out_cstr
    mov rax, [ts3]
    call out_uint
    lea rsi, [jn_pending]
    call out_cstr
    cmp qword [udirty], 0
    je oh_np
    lea rsi, [b_true]
    call out_cstr
    jmp hh_tail
oh_np:
    lea rsi, [b_false]
    call out_cstr
hh_tail:
    mov al, '}'
    call out_byte
    jmp oc_envelope

; op_search {query, limit?}
op_search:
    mov rsi, [pp]
    lea rdi, [k_args]
    mov ecx, 11
    call find_val
    test rax, rax
    jz dc_params
    mov [ap], rax
    mov rsi, [ap]
    lea rdi, [k_query]
    mov ecx, 7
    call find_val
    test rax, rax
    jz dc_params
    mov rsi, rax
    lea rdi, [qbuf]
    mov ecx, 128
    call parse_str
    test rax, rax
    jz dc_params
    test rdx, rdx
    jz dc_params
    mov [qlen], rdx
    lea rsi, [qbuf]
    mov rdx, [qlen]
    call ascii_only
    test rax, rax
    jnz oc_ascii
    mov qword [slim], 10
    mov rsi, [ap]
    lea rdi, [k_limit]
    mov ecx, 7
    call find_val
    test rax, rax
    jz os_nolim
    mov rsi, rax
    call parse_int
    test rax, rax
    jnz dc_params
    mov rax, [numval]
    cmp rax, 1
    jb dc_params
    cmp rax, 20
    ja dc_params
    mov [slim], rax
os_nolim:
    call db_open
    test rax, rax
    jnz oc_db
    lea rax, [jsontmp]
    mov [outptr], rax
    call out_reset
    lea rsi, [jn_results]
    call out_cstr
    mov qword [scount], 0
    mov byte [hfirst], 1
    mov rax, [f_root_ent]
    mov [sroot], rax
    mov qword [smode], 0
    call search_table
    test rax, rax
    jnz os_dbclose
    mov rax, [f_root_obs]
    mov [sroot], rax
    mov qword [smode], 1
    call search_table
    test rax, rax
    jnz os_dbclose
    mov rax, [f_root_facts]
    mov [sroot], rax
    mov qword [smode], 2
    call search_table
    test rax, rax
    jnz os_dbclose
    call db_close
    mov al, ']'
    call out_byte
    mov al, '}'
    call out_byte
    jmp oc_envelope
os_dbclose:
    call db_close
    lea rdi, [c_internal]
    lea rsi, [m_nodb]
    jmp err_id

; op_open {names[1..16]}: entities + observations + relations, streamed.
op_open:
    mov rsi, [pp]
    lea rdi, [k_args]
    mov ecx, 11
    call find_val
    test rax, rax
    jz dc_params
    mov [ap], rax
    mov rsi, [ap]
    lea rdi, [k_names]
    mov ecx, 7
    call find_val
    test rax, rax
    jz dc_params
    cmp rax, [le]
    jae dc_params
    cmp byte [rax], '['
    jne dc_params
    inc rax
    mov [obsarr], rax
    call db_open
    test rax, rax
    jnz oc_db
    lea rax, [jsontmp]
    mov [outptr], rax
    call out_reset
    lea rsi, [jn_nodes]
    call out_cstr
    mov byte [hfirst], 1
    xor ebx, ebx                ; names done
oo_loop:
    cmp ebx, 16
    jae oo_many
    mov rsi, [obsarr]
    call skip_ws_comma
    mov rsi, [obsarr]
    cmp rsi, [le]
    jae oo_bad
    cmp byte [rsi], ']'
    je oo_tail
    cmp byte [rsi], '"'
    jne oo_bad
    lea rdi, [relbuf]
    mov ecx, 128
    call parse_str
    test rax, rax
    jz oo_bad
    mov [obsarr], rax
    mov [rllen], rdx
    test rdx, rdx
    jz oo_bad
    lea rsi, [relbuf]
    mov rdx, [rllen]
    call valid_name
    test rax, rax
    jnz oo_bad
    inc rbx
    ; lookup entity (latest); tombstoned names report missing
    lea rsi, [relbuf]
    mov rdx, [rllen]
    call is_tombstoned
    cmp rax, 1
    je oo_missing
    cmp rax, 2
    je oo_dbclose
    lea rsi, [relbuf]
    mov rdx, [rllen]
    mov [mkey], rsi
    mov [mkeylen], rdx
    mov rdi, [f_root_ent]
    call scan_key_latest
    cmp rax, 2
    je oo_dbclose
    cmp rax, 1
    jne oo_missing
    ; full entry
    cmp qword [outlen], 60000
    ja oo_tail
    cmp byte [hfirst], 1
    je oo_first
    mov al, ','
    call out_byte
    jmp oo_head
oo_first:
    mov byte [hfirst], 0
oo_head:
    mov al, '{'
    call out_byte
    lea rsi, [jn_name + 1]      ; '"name":"' (skip leading comma)
    call out_cstr
    lea rsi, [relbuf]
    mov rdx, [rllen]
    call out_escaped
    mov al, '"'
    call out_byte
    lea rsi, [jn_type]
    call out_cstr
    mov rsi, qword [gfo + 8]
    mov rdx, qword [gfl + 8]
    call out_escaped
    mov al, '"'
    call out_byte
    lea rsi, [jn_project]
    call out_cstr
    mov rsi, qword [gfo + 16]
    mov rdx, qword [gfl + 16]
    call out_escaped
    mov al, '"'
    call out_byte
    lea rsi, [jn_obs]
    call out_cstr
    mov byte [hfirst], 1        ; reuse as inner-array first flag
    mov qword [obcount], 0
    mov rdi, [f_root_obs]
    call walk_leaves
    test rax, rax
    jnz oo_dbclose
    mov qword [stci], 0
oo_opage:
    mov rax, [stci]
    cmp rax, [childn]
    jae oo_obsdone
    lea rsi, [childtab]
    shl rax, 3
    add rsi, rax
    mov rdi, [rsi]
    lea rsi, [pagebuf]
    call pg_read
    test rax, rax
    jnz oo_onextpg
    cmp byte [pagebuf], 0x0D
    jne oo_onextpg
    lea rsi, [pagebuf + 3]
    call be16_ld
    mov [stn], rax
    mov qword [stcell], 0
oo_ocell:
    mov rax, [stcell]
    cmp rax, [stn]
    jae oo_onextpg
    cmp qword [obcount], 50
    jae oo_obsdone
    cmp qword [outlen], 60000
    ja oo_obsdone
    lea rsi, [pagebuf + 8]
    shl rax, 1
    add rsi, rax
    call be16_ld
    lea rsi, [pagebuf]
    add rsi, rax
    call parse_row
    test rax, rax
    jnz oo_ocellnext
    cmp qword [gcols], 2
    jb oo_ocellnext
    mov rax, qword [gfl]
    cmp rax, [rllen]
    jne oo_ocellnext
    mov rsi, qword [gfo]
    lea rdi, [relbuf]
    mov rcx, rax
    rep cmpsb
    jne oo_ocellnext
    cmp byte [hfirst], 1
    je oo_ofirst
    mov al, ','
    call out_byte
    jmp oo_oemit
oo_ofirst:
    mov byte [hfirst], 0
oo_oemit:
    mov al, '"'
    call out_byte
    mov rsi, qword [gfo + 8]
    mov rdx, qword [gfl + 8]
    call out_escaped
    mov al, '"'
    call out_byte
    inc qword [obcount]
oo_ocellnext:
    inc qword [stcell]
    jmp oo_ocell
oo_onextpg:
    inc qword [stci]
    jmp oo_opage
oo_obsdone:
    lea rsi, [jn_rels]
    call out_cstr
    mov byte [hfirst], 1
    mov qword [relcount], 0
    mov rdi, [f_root_rel]
    call walk_leaves
    test rax, rax
    jnz oo_dbclose
    mov qword [stci], 0
oo_rpage:
    mov rax, [stci]
    cmp rax, [childn]
    jae oo_relsdone
    lea rsi, [childtab]
    shl rax, 3
    add rsi, rax
    mov rdi, [rsi]
    lea rsi, [pagebuf]
    call pg_read
    test rax, rax
    jnz oo_rnextpg
    cmp byte [pagebuf], 0x0D
    jne oo_rnextpg
    lea rsi, [pagebuf + 3]
    call be16_ld
    mov [stn], rax
    mov qword [stcell], 0
oo_rcell:
    mov rax, [stcell]
    cmp rax, [stn]
    jae oo_rnextpg
    cmp qword [relcount], 50
    jae oo_relsdone
    cmp qword [outlen], 60000
    ja oo_relsdone
    lea rsi, [pagebuf + 8]
    shl rax, 1
    add rsi, rax
    call be16_ld
    lea rsi, [pagebuf]
    add rsi, rax
    call parse_row
    test rax, rax
    jnz oo_rcellnext
    cmp qword [gcols], 3
    jb oo_rcellnext
    ; col0==name or col1==name?
    mov rax, qword [gfl]
    cmp rax, [rllen]
    jne oo_trycol1
    mov rsi, qword [gfo]
    lea rdi, [relbuf]
    mov rcx, rax
    rep cmpsb
    je oo_rhit
oo_trycol1:
    mov rax, qword [gfl + 8]
    cmp rax, [rllen]
    jne oo_rcellnext
    mov rsi, qword [gfo + 8]
    lea rdi, [relbuf]
    mov rcx, rax
    rep cmpsb
    jne oo_rcellnext
oo_rhit:
    cmp byte [hfirst], 1
    je oo_rfirst
    mov al, ','
    call out_byte
    jmp oo_remit
oo_rfirst:
    mov byte [hfirst], 0
oo_remit:
    mov al, '{'
    call out_byte
    lea rsi, [jn_from + 1]      ; '"from":"'
    call out_cstr
    mov rsi, qword [gfo]
    mov rdx, qword [gfl]
    call out_escaped
    mov al, '"'
    call out_byte
    lea rsi, [jn_to]
    call out_cstr
    mov rsi, qword [gfo + 8]
    mov rdx, qword [gfl + 8]
    call out_escaped
    mov al, '"'
    call out_byte
    lea rsi, [jn_type]
    call out_cstr
    mov rsi, qword [gfo + 16]
    mov rdx, qword [gfl + 16]
    call out_escaped
    mov al, '"'
    call out_byte
    mov al, '}'
    call out_byte
    inc qword [relcount]
oo_rcellnext:
    inc qword [stcell]
    jmp oo_rcell
oo_rnextpg:
    inc qword [stci]
    jmp oo_rpage
oo_relsdone:
    mov al, ']'
    call out_byte
    mov al, '}'
    call out_byte
    jmp oo_loop
oo_missing:
    cmp qword [outlen], 60000
    ja oo_tail
    cmp byte [hfirst], 1
    je oo_mfirst
    mov al, ','
    call out_byte
    jmp oo_memit
oo_mfirst:
    mov byte [hfirst], 0
oo_memit:
    lea rsi, [jn_missing]
    call out_cstr
    lea rsi, [relbuf]
    mov rdx, [rllen]
    call out_escaped
    lea rsi, [jn_miss2]
    call out_cstr
    jmp oo_loop
oo_tail:
    call db_close
    mov al, ']'
    call out_byte
    mov al, '}'
    call out_byte
    jmp oc_envelope
oo_many:
    call db_close
    lea rdi, [c_params]
    lea rsi, [m_big]
    jmp err_id
oo_bad:
    call db_close
    lea rdi, [c_params]
    lea rsi, [m_params]
    jmp err_id
oo_dbclose:
    call db_close
    lea rdi, [c_internal]
    lea rsi, [m_nodb]
    jmp err_id

; ---- memory: tasks (stable tid from header taskseq, append-version) ----
; op_mktask {title, body?, status?, project?, priority?}
op_mktask:
    mov rsi, [pp]
    lea rdi, [k_args]
    mov ecx, 11
    call find_val
    test rax, rax
    jz dc_params
    mov [ap], rax
    mov rsi, [ap]
    lea rdi, [k_title]
    mov ecx, 7
    call find_val
    test rax, rax
    jz dc_params
    mov rsi, rax
    lea rdi, [titlebuf]
    mov ecx, 128
    call parse_str
    test rax, rax
    jz dc_params
    test rdx, rdx
    jz dc_params
    mov [titlelen], rdx
    lea rsi, [titlebuf]
    mov rdx, [titlelen]
    call ascii_only
    test rax, rax
    jnz oc_ascii
    ; body? default ""
    mov qword [taskblen], 0
    mov rsi, [ap]
    lea rdi, [k_body]
    mov ecx, 6
    call find_val
    test rax, rax
    jz omt_nobody
    mov rsi, rax
    lea rdi, [taskbuf]
    mov ecx, 1024
    call parse_str
    test rax, rax
    jz dc_params
    mov [taskblen], rdx
    lea rsi, [taskbuf]
    mov rdx, [taskblen]
    call ascii_only
    test rax, rax
    jnz oc_ascii
omt_nobody:
    ; status? default not_started
    lea rsi, [st_ns]
    lea rdi, [stbuf]
    mov ecx, 11
    rep movsb
    mov qword [stlen], 11
    mov rsi, [ap]
    lea rdi, [k_status]
    mov ecx, 8
    call find_val
    test rax, rax
    jz omt_nostat
    mov rsi, rax
    lea rdi, [stbuf]
    mov ecx, 16
    call parse_str
    test rax, rax
    jz dc_params
    test rdx, rdx
    jz dc_params
    mov [stlen], rdx
    lea rsi, [stbuf]
    mov rdx, [stlen]
    call match_status
    test rax, rax
    jnz dc_params
omt_nostat:
    ; project? default ""
    mov qword [projlen], 0
    mov rsi, [ap]
    lea rdi, [k_project]
    mov ecx, 9
    call find_val
    test rax, rax
    jz omt_noproj
    mov rsi, rax
    lea rdi, [projbuf]
    mov ecx, 32
    call parse_str
    test rax, rax
    jz dc_params
    mov [projlen], rdx
    lea rsi, [projbuf]
    mov rdx, [projlen]
    call ascii_only
    test rax, rax
    jnz oc_ascii
omt_noproj:
    ; priority? default medium
    lea rsi, [pr_me]
    lea rdi, [pribuf]
    mov ecx, 6
    rep movsb
    mov qword [prilen], 6
    mov rsi, [ap]
    lea rdi, [k_priority]
    mov ecx, 10
    call find_val
    test rax, rax
    jz omt_nopri
    mov rsi, rax
    lea rdi, [pribuf]
    mov ecx, 16
    call parse_str
    test rax, rax
    jz dc_params
    test rdx, rdx
    jz dc_params
    mov [prilen], rdx
    lea rsi, [pribuf]
    mov rdx, [prilen]
    call match_priority
    test rax, rax
    jnz dc_params
omt_nopri:
    call db_open_ex
    test rax, rax
    jnz oc_db
    mov rax, [taskseq]
    inc rax
    mov [taskseq], rax
    mov [qtid], rax
    lea rdi, [relbuf]
    call ultoa
    mov [rllen], rcx
    mov rdi, [f_root_tasks]
    call tail_max
    test rax, rax
    jnz om_dbclose
    mov rax, [maxrowid]
    inc rax
    mov [newrowid], rax
    lea rax, [titlebuf]
    mov qword [colp], rax
    mov rax, [titlelen]
    mov qword [coll], rax
    lea rax, [taskbuf]
    mov qword [colp + 8], rax
    mov rax, [taskblen]
    mov qword [coll + 8], rax
    lea rax, [stbuf]
    mov qword [colp + 16], rax
    mov rax, [stlen]
    mov qword [coll + 16], rax
    lea rax, [projbuf]
    mov qword [colp + 24], rax
    mov rax, [projlen]
    mov qword [coll + 24], rax
    lea rax, [pribuf]
    mov qword [colp + 32], rax
    mov rax, [prilen]
    mov qword [coll + 32], rax
    lea rax, [relbuf]
    mov qword [colp + 40], rax
    mov rax, [rllen]
    mov qword [coll + 40], rax
    mov qword [ncols], 6
    call build_record_text
    mov rax, [f_root_tasks]
    mov [splitroot], rax
    call place_cell
    test rax, rax
    jnz om_insfail
    mov rax, [newrowid]
    mov [maxrowid], rax
    call hdr_touch
    call db_close
    ; inner {"id":T,"title":"..","status":".."}
    lea rax, [jsontmp]
    mov [outptr], rax
    mov qword [outlen], 0
    lea rsi, [jn_id]
    call out_cstr
    mov rax, [qtid]
    call out_uint
    lea rsi, [jn_title]
    call out_cstr
    lea rsi, [titlebuf]
    mov rdx, [titlelen]
    call out_escaped
    mov al, '"'
    call out_byte
    lea rsi, [jn_status]
    call out_cstr
    lea rsi, [stbuf]
    mov rdx, [stlen]
    call out_escaped
    mov al, '"'
    call out_byte
    mov al, '}'
    call out_byte
    jmp oc_envelope

; op_query {status?, project?, search?, limit?} newest-first.
op_query:
    mov rsi, [pp]
    lea rdi, [k_args]
    mov ecx, 11
    call find_val
    test rax, rax
    jz dc_params
    mov [ap], rax
    mov qword [tmask], 0
    mov rsi, [ap]
    lea rdi, [k_status]
    mov ecx, 8
    call find_val
    test rax, rax
    jz oq_nostat
    mov rsi, rax
    lea rdi, [stbuf]
    mov ecx, 16
    call parse_str
    test rax, rax
    jz dc_params
    test rdx, rdx
    jz dc_params
    mov [stlen], rdx
    lea rsi, [stbuf]
    mov rdx, [stlen]
    call match_status
    test rax, rax
    jnz dc_params
    or qword [tmask], 1
oq_nostat:
    mov rsi, [ap]
    lea rdi, [k_project]
    mov ecx, 9
    call find_val
    test rax, rax
    jz oq_noproj
    mov rsi, rax
    lea rdi, [projbuf]
    mov ecx, 32
    call parse_str
    test rax, rax
    jz dc_params
    mov [projlen], rdx
    lea rsi, [projbuf]
    mov rdx, [projlen]
    call ascii_only
    test rax, rax
    jnz oc_ascii
    or qword [tmask], 2
oq_noproj:
    mov rsi, [ap]
    lea rdi, [k_search]
    mov ecx, 8
    call find_val
    test rax, rax
    jz oq_nosearch
    mov rsi, rax
    lea rdi, [qbuf]
    mov ecx, 128
    call parse_str
    test rax, rax
    jz dc_params
    test rdx, rdx
    jz dc_params
    mov [qlen], rdx
    lea rsi, [qbuf]
    mov rdx, [qlen]
    call ascii_only
    test rax, rax
    jnz oc_ascii
    or qword [tmask], 4
oq_nosearch:
    mov qword [slim], 20
    mov rsi, [ap]
    lea rdi, [k_limit]
    mov ecx, 7
    call find_val
    test rax, rax
    jz oq_nolim
    mov rsi, rax
    call parse_int
    test rax, rax
    jnz dc_params
    mov rax, [numval]
    cmp rax, 1
    jb dc_params
    cmp rax, 50
    ja dc_params
    mov [slim], rax
oq_nolim:
    call db_open
    test rax, rax
    jnz oc_db
    lea rax, [jsontmp]
    mov [outptr], rax
    call out_reset
    lea rsi, [jn_tasks]
    call out_cstr
    mov qword [scount], 0
    mov qword [tseenn], 0
    mov byte [hfirst], 1
    mov rdi, [f_root_tasks]
    call walk_leaves
    test rax, rax
    jnz os_dbclose
    mov rax, [childn]
    test rax, rax
    jz oq_tail
    dec rax
    mov [stci], rax              ; start at last page index
oq_page:
    lea rsi, [childtab]
    mov rax, [stci]
    shl rax, 3
    add rsi, rax
    mov rdi, [rsi]
    lea rsi, [pagebuf]
    call pg_read
    test rax, rax
    jnz oq_nextpg
    cmp byte [pagebuf], 0x0D
    jne oq_nextpg
    lea rsi, [pagebuf + 3]
    call be16_ld
    test rax, rax
    jz oq_nextpg
    mov [stn], rax
    dec rax
    mov [stcell], rax
oq_cell:
    lea rsi, [pagebuf + 8]
    mov rax, [stcell]
    shl rax, 1
    add rsi, rax
    call be16_ld
    lea rsi, [pagebuf]
    add rsi, rax
    call parse_row
    test rax, rax
    jnz oq_nextcell
    cmp qword [gcols], 6
    jb oq_nextcell
    ; tid integer?
    mov rsi, qword [gfo + 40]
    mov rdx, qword [gfl + 40]
    call dec_atoi
    cmp rax, -1
    je oq_nextcell
    mov [qtid], rax
    ; dedupe by tid in tseetab
    xor ecx, ecx
oq_seen:
    cmp rcx, [tseenn]
    jae oq_new
    lea rdx, [tseetab]
    mov rsi, rcx
    shl rsi, 3
    add rdx, rsi
    cmp qword [rdx], rax
    je oq_nextcell
    inc rcx
    jmp oq_seen
oq_new:
    cmp qword [tseenn], 512
    jae oq_tail
    lea rsi, [tseetab]
    mov rcx, [tseenn]
    shl rcx, 3
    add rsi, rcx
    mov rcx, [qtid]
    mov qword [rsi], rcx
    inc qword [tseenn]
    jmp oq_filter
oq_filter:
    ; status filter?
    test qword [tmask], 1
    jz oq_fproj
    mov rax, qword [gfl + 16]
    cmp rax, [stlen]
    jne oq_nextcell
    mov rsi, qword [gfo + 16]
    lea rdi, [stbuf]
    mov rcx, rax
    rep cmpsb
    jne oq_nextcell
oq_fproj:
    test qword [tmask], 2
    jz oq_fsearch
    mov rax, qword [gfl + 24]
    cmp rax, [projlen]
    jne oq_nextcell
    mov rsi, qword [gfo + 24]
    lea rdi, [projbuf]
    mov rcx, rax
    rep cmpsb
    jne oq_nextcell
oq_fsearch:
    test qword [tmask], 4
    jz oq_emitq
    mov rsi, qword [gfo]
    mov rdx, qword [gfl]
    lea rdi, [qbuf]
    mov rcx, [qlen]
    call sub_find
    test rax, rax
    jnz oq_emitq
    mov rsi, qword [gfo + 8]
    mov rdx, qword [gfl + 8]
    lea rdi, [qbuf]
    mov rcx, [qlen]
    call sub_find
    test rax, rax
    jz oq_nextcell
oq_emitq:
    mov rax, [scount]
    cmp rax, [slim]
    jae oq_tail
    cmp qword [outlen], 60000
    ja oq_tail
    cmp byte [hfirst], 1
    je oq_qfirst
    mov al, ','
    call out_byte
    jmp oq_qput
oq_qfirst:
    mov byte [hfirst], 0
oq_qput:
    mov al, '{'
    call out_byte
    lea rsi, [jn_id + 1]        ; '"id":'
    call out_cstr
    mov rsi, qword [gfo + 40]
    mov rdx, qword [gfl + 40]
    call out_escaped_rawnum
    lea rsi, [jn_title]
    call out_cstr
    mov rsi, qword [gfo]
    mov rdx, qword [gfl]
    call out_escaped
    mov al, '"'
    call out_byte
    lea rsi, [jn_status]
    call out_cstr
    mov rsi, qword [gfo + 16]
    mov rdx, qword [gfl + 16]
    call out_escaped
    mov al, '"'
    call out_byte
    lea rsi, [jn_project]
    call out_cstr
    mov rsi, qword [gfo + 24]
    mov rdx, qword [gfl + 24]
    call out_escaped
    mov al, '"'
    call out_byte
    lea rsi, [jn_priority]
    call out_cstr
    mov rsi, qword [gfo + 32]
    mov rdx, qword [gfl + 32]
    call out_escaped
    mov al, '"'
    call out_byte
    lea rsi, [jn_body]
    call out_cstr
    mov rsi, qword [gfo + 8]
    mov rdx, qword [gfl + 8]
    call out_escaped
    mov al, '"'
    call out_byte
    mov al, '}'
    call out_byte
    inc qword [scount]
oq_nextcell:
    cmp qword [stcell], 0
    je oq_nextpg
    dec qword [stcell]
    jmp oq_cell
oq_nextpg:
    cmp qword [stci], 0
    je oq_tail
    dec qword [stci]
    jmp oq_page
oq_tail:
    call db_close
    mov al, ']'
    call out_byte
    mov al, '}'
    call out_byte
    jmp oc_envelope

; out_escaped_rawnum(rsi=digits, rdx=len): raw copy (validated digits).
out_escaped_rawnum:
    test rdx, rdx
    jz oer_ret
    mov rcx, rdx
    mov rax, [outlen]
    mov rdi, [outptr]
    add rdi, rax
    add rax, rcx
    mov [outlen], rax
    rep movsb
oer_ret:
    ret

; op_updtask {id, title?, body?, status?, project?, priority?}
op_updtask:
    mov rsi, [pp]
    lea rdi, [k_args]
    mov ecx, 11
    call find_val
    test rax, rax
    jz dc_params
    mov [ap], rax
    mov rsi, [ap]
    lea rdi, [k_id]
    mov ecx, 4
    call find_val
    test rax, rax
    jz dc_params
    mov rsi, rax
    call parse_int
    test rax, rax
    jnz dc_params
    mov rax, [numval]
    cmp rax, 1
    jb dc_params
    mov [qtid], rax
    mov qword [tmask], 0
    mov rsi, [ap]
    lea rdi, [k_title]
    mov ecx, 7
    call find_val
    test rax, rax
    jz ou_notitle
    mov rsi, rax
    lea rdi, [titlebuf]
    mov ecx, 128
    call parse_str
    test rax, rax
    jz dc_params
    test rdx, rdx
    jz dc_params
    mov [titlelen], rdx
    lea rsi, [titlebuf]
    mov rdx, [titlelen]
    call ascii_only
    test rax, rax
    jnz oc_ascii
    or qword [tmask], 1
ou_notitle:
    mov rsi, [ap]
    lea rdi, [k_body]
    mov ecx, 6
    call find_val
    test rax, rax
    jz ou_nobody
    mov rsi, rax
    lea rdi, [taskbuf]
    mov ecx, 1024
    call parse_str
    test rax, rax
    jz dc_params
    mov [taskblen], rdx
    lea rsi, [taskbuf]
    mov rdx, [taskblen]
    call ascii_only
    test rax, rax
    jnz oc_ascii
    or qword [tmask], 2
ou_nobody:
    mov rsi, [ap]
    lea rdi, [k_status]
    mov ecx, 8
    call find_val
    test rax, rax
    jz ou_nostat
    mov rsi, rax
    lea rdi, [stbuf]
    mov ecx, 16
    call parse_str
    test rax, rax
    jz dc_params
    test rdx, rdx
    jz dc_params
    mov [stlen], rdx
    lea rsi, [stbuf]
    mov rdx, [stlen]
    call match_status
    test rax, rax
    jnz dc_params
    or qword [tmask], 4
ou_nostat:
    mov rsi, [ap]
    lea rdi, [k_project]
    mov ecx, 9
    call find_val
    test rax, rax
    jz ou_noproj
    mov rsi, rax
    lea rdi, [projbuf]
    mov ecx, 32
    call parse_str
    test rax, rax
    jz dc_params
    mov [projlen], rdx
    lea rsi, [projbuf]
    mov rdx, [projlen]
    call ascii_only
    test rax, rax
    jnz oc_ascii
    or qword [tmask], 8
ou_noproj:
    mov rsi, [ap]
    lea rdi, [k_priority]
    mov ecx, 10
    call find_val
    test rax, rax
    jz ou_nopri
    mov rsi, rax
    lea rdi, [pribuf]
    mov ecx, 16
    call parse_str
    test rax, rax
    jz dc_params
    test rdx, rdx
    jz dc_params
    mov [prilen], rdx
    lea rsi, [pribuf]
    mov rdx, [prilen]
    call match_priority
    test rax, rax
    jnz dc_params
    or qword [tmask], 16
ou_nopri:
    test qword [tmask], 31
    jz dc_params
    call db_open_ex
    test rax, rax
    jnz oc_db
    ; find latest row with tid==qtid (newest-first walk)
    mov rdi, [f_root_tasks]
    call walk_leaves
    test rax, rax
    jnz om_dbclose
    mov rax, [childn]
    test rax, rax
    jz ou_miss
    dec rax
    mov [stci], rax              ; start at last page index
ou_page:
    lea rsi, [childtab]
    mov rax, [stci]
    shl rax, 3
    add rsi, rax
    mov rdi, [rsi]
    lea rsi, [pagebuf]
    call pg_read
    test rax, rax
    jnz ou_nextpg
    cmp byte [pagebuf], 0x0D
    jne ou_nextpg
    lea rsi, [pagebuf + 3]
    call be16_ld
    test rax, rax
    jz ou_nextpg
    mov [stn], rax
    dec rax
    mov [stcell], rax
ou_cell:
    lea rsi, [pagebuf + 8]
    mov rax, [stcell]
    shl rax, 1
    add rsi, rax
    call be16_ld
    lea rsi, [pagebuf]
    add rsi, rax
    call parse_row
    test rax, rax
    jnz ou_nextcell
    cmp qword [gcols], 6
    jb ou_nextcell
    mov rsi, qword [gfo + 40]
    mov rdx, qword [gfl + 40]
    call dec_atoi
    cmp rax, [qtid]
    jne ou_nextcell
    jmp ou_found
ou_nextcell:
    cmp qword [stcell], 0
    je ou_nextpg
    dec qword [stcell]
    jmp ou_cell
ou_nextpg:
    cmp qword [stci], 0
    je ou_miss
    dec qword [stci]
    jmp ou_page
ou_miss:
    call db_close
    lea rdi, [c_params]
    lea rsi, [m_nofile]
    jmp err_id
ou_found:
    ; snapshot current row into bufs for absent fields (pagebuf churns next)
    test qword [tmask], 1
    jnz ou_s1
    mov rax, qword [gfl]
    cmp rax, 128
    ja ou_corrupt
    mov rsi, qword [gfo]
    lea rdi, [titlebuf]
    mov rcx, rax
    rep movsb
    mov [titlelen], rax
ou_s1:
    test qword [tmask], 2
    jnz ou_s2
    mov rax, qword [gfl + 8]
    cmp rax, 1024
    ja ou_corrupt
    mov rsi, qword [gfo + 8]
    lea rdi, [taskbuf]
    mov rcx, rax
    rep movsb
    mov [taskblen], rax
ou_s2:
    test qword [tmask], 4
    jnz ou_s3
    mov rax, qword [gfl + 16]
    cmp rax, 16
    ja ou_corrupt
    mov rsi, qword [gfo + 16]
    lea rdi, [stbuf]
    mov rcx, rax
    rep movsb
    mov [stlen], rax
ou_s3:
    test qword [tmask], 8
    jnz ou_s4
    mov rax, qword [gfl + 24]
    cmp rax, 32
    ja ou_corrupt
    mov rsi, qword [gfo + 24]
    lea rdi, [projbuf]
    mov rcx, rax
    rep movsb
    mov [projlen], rax
ou_s4:
    test qword [tmask], 16
    jnz ou_s5
    mov rax, qword [gfl + 32]
    cmp rax, 16
    ja ou_corrupt
    mov rsi, qword [gfo + 32]
    lea rdi, [pribuf]
    mov rcx, rax
    rep movsb
    mov [prilen], rax
ou_s5:
    mov rax, qword [gfl + 40]
    cmp rax, 64
    ja ou_corrupt
    mov rsi, qword [gfo + 40]
    lea rdi, [relbuf]
    mov rcx, rax
    rep movsb
    mov [rllen], rax
    ; colp/coll all from bufs now (pagebuf-independent)
    lea rax, [titlebuf]
    mov qword [colp], rax
    mov rax, [titlelen]
    mov qword [coll], rax
    lea rax, [taskbuf]
    mov qword [colp + 8], rax
    mov rax, [taskblen]
    mov qword [coll + 8], rax
    lea rax, [stbuf]
    mov qword [colp + 16], rax
    mov rax, [stlen]
    mov qword [coll + 16], rax
    lea rax, [projbuf]
    mov qword [colp + 24], rax
    mov rax, [projlen]
    mov qword [coll + 24], rax
    lea rax, [pribuf]
    mov qword [colp + 32], rax
    mov rax, [prilen]
    mov qword [coll + 32], rax
    lea rax, [relbuf]
    mov qword [colp + 40], rax
    mov rax, [rllen]
    mov qword [coll + 40], rax
    mov qword [ncols], 6
    ; response inner from bufs, then persist
    lea rax, [jsontmp]
    mov [outptr], rax
    mov qword [outlen], 0
    lea rsi, [jn_id]
    call out_cstr
    lea rsi, [relbuf]
    mov rdx, [rllen]
    call out_escaped_rawnum
    lea rsi, [jn_title]
    call out_cstr
    lea rsi, [titlebuf]
    mov rdx, [titlelen]
    call out_escaped
    mov al, '"'
    call out_byte
    lea rsi, [jn_status]
    call out_cstr
    lea rsi, [stbuf]
    mov rdx, [stlen]
    call out_escaped
    mov al, '"'
    call out_byte
    mov al, '}'
    call out_byte
    mov rax, [outlen]
    mov [innerlen], rax
    ; now persist the new version
    mov rdi, [f_root_tasks]
    call tail_max
    test rax, rax
    jnz om_dbclose
    mov rax, [maxrowid]
    inc rax
    mov [newrowid], rax
    call build_record_text
    mov rax, [f_root_tasks]
    mov [splitroot], rax
    call place_cell
    test rax, rax
    jnz om_insfail
    mov rax, [newrowid]
    mov [maxrowid], rax
    call hdr_touch
    mov edi, 3                    ; task update re-asserts a stable id
    mov rsi, [qtid]
    call use_conf_id
    call db_close
    jmp oc_envelope
ou_corrupt:
    call db_close
    lea rdi, [c_internal]
    lea rsi, [m_nodb]
    jmp err_id

; op_think
op_think:
    mov rsi, [pp]
    lea rdi, [k_args]
    mov ecx, 11
    call find_val
    test rax, rax
    jz dc_params
    mov [ap], rax
    ; thought (required string)
    mov rsi, [ap]
    lea rdi, [k_thought]
    mov ecx, 9
    call find_val
    test rax, rax
    jz dc_params
    mov rsi, rax
    lea rdi, [thtmp]
    mov ecx, 2048
    call parse_str
    test rax, rax
    jz dc_params
    test rdx, rdx
    jz dc_params
    mov [thlen], rdx
    ; nextThoughtNeeded (required bool)
    mov rsi, [ap]
    lea rdi, [k_next]
    mov ecx, 19
    call find_val
    test rax, rax
    jz dc_params
    mov rsi, rax
    call parse_bool
    test rax, rax
    jnz dc_params
    mov al, [boolval]
    mov [v_next], al
    ; thoughtNumber (required int)
    mov rsi, [ap]
    lea rdi, [k_thnum]
    mov ecx, 15
    call find_val
    test rax, rax
    jz dc_params
    mov rsi, rax
    call parse_int
    test rax, rax
    jnz dc_params
    mov rax, [numval]
    mov [v_num], rax
    cmp qword [v_num], 1
    jb dc_params
    ; totalThoughts (required int >= 1)
    mov rsi, [ap]
    lea rdi, [k_thtotal]
    mov ecx, 15
    call find_val
    test rax, rax
    jz dc_params
    mov rsi, rax
    call parse_int
    test rax, rax
    jnz dc_params
    mov rax, [numval]
    mov [v_total], rax
    cmp qword [v_total], 1
    jb dc_params
    ; optionals, defaults absent
    mov qword [gotmask], 0
    mov qword [v_isrev], 0
    mov qword [v_rev], -1
    mov qword [v_brfrom], -1
    mov qword [v_more], 0
    mov qword [bidlen], 0
    ; isRevision?
    mov rsi, [ap]
    lea rdi, [k_isrev]
    mov ecx, 12
    call find_val
    test rax, rax
    jz ot_norev
    mov rsi, rax
    call parse_bool
    test rax, rax
    jnz dc_params
    mov al, [boolval]
    mov [v_isrev], al
    or qword [gotmask], 1
ot_norev:
    ; revisesThought?
    mov rsi, [ap]
    lea rdi, [k_rev]
    mov ecx, 16
    call find_val
    test rax, rax
    jz ot_norevt
    mov rsi, rax
    call parse_int
    test rax, rax
    jnz dc_params
    mov rax, [numval]
    mov [v_rev], rax
    or qword [gotmask], 2
ot_norevt:
    ; branchFromThought?
    mov rsi, [ap]
    lea rdi, [k_brfrom]
    mov ecx, 19
    call find_val
    test rax, rax
    jz ot_nobr
    mov rsi, rax
    call parse_int
    test rax, rax
    jnz dc_params
    mov rax, [numval]
    mov [v_brfrom], rax
    or qword [gotmask], 4
ot_nobr:
    ; branchId?
    mov rsi, [ap]
    lea rdi, [k_brid]
    mov ecx, 10
    call find_val
    test rax, rax
    jz ot_nobid
    mov rsi, rax
    lea rdi, [bidtmp]
    mov ecx, 40
    call parse_str
    test rax, rax
    jz dc_params
    mov [bidlen], rdx
    or qword [gotmask], 8
ot_nobid:
    ; needsMoreThoughts?
    mov rsi, [ap]
    lea rdi, [k_more]
    mov ecx, 19
    call find_val
    test rax, rax
    jz ot_store
    mov rsi, rax
    call parse_bool
    test rax, rax
    jnz dc_params
    mov al, [boolval]
    mov [v_more], al
    or qword [gotmask], 16
ot_store:
    ; validate workflow references against recorded history
    test qword [gotmask], 2   ; revisesThought in 1..hcount?
    jz ot_vbr
    mov rax, [v_rev]
    cmp rax, 1
    jb ot_unknown
    cmp rax, [hcount]
    ja ot_unknown
ot_vbr:
    test qword [gotmask], 4   ; branchFromThought in 1..hcount?
    jz ot_vok
    mov rax, [v_brfrom]
    cmp rax, 1
    jb ot_unknown
    cmp rax, [hcount]
    ja ot_unknown
    jmp ot_vok
ot_unknown:
    lea rdi, [c_params]
    lea rsi, [m_unknown]
    jmp err_id
ot_vok:
    ; slot = hcount % 64 ; each slot 2144 bytes
    mov rax, [hcount]
    and rax, 63
    mov rbx, rax
    shl rbx, 11               ; *2048
    mov rcx, rax
    shl rcx, 6                ; *64
    add rbx, rcx
    mov rcx, rax
    shl rcx, 5                ; *32
    add rbx, rcx              ; rbx = idx*2144
    lea rdi, [thslots]
    add rdi, rbx              ; rdi = slot
    lea rsi, [thtmp]          ; text
    mov rcx, [thlen]
    mov [rdi + 2048], rcx
    push rdi
    add rdi, 0                ; text at +0
    rep movsb
    pop rdi
    mov rax, [v_num]
    mov [rdi + 2056], rax
    mov rax, [v_total]
    mov [rdi + 2064], rax
    mov al, [v_next]
    movzx rax, al
    mov [rdi + 2072], rax     ; bit0 = nextNeeded
    movzx rax, byte [v_isrev]
    shl rax, 1
    or [rdi + 2072], rax      ; bit1 = isRevision
    test qword [gotmask], 16
    jz st_nomask
    or qword [rdi + 2072], 4  ; bit2 = needsMore provided
    cmp byte [v_more], 0
    je st_nomask
    or qword [rdi + 2072], 8  ; bit3 = needsMore value
st_nomask:
    mov rax, [v_rev]
    mov [rdi + 2080], rax
    mov rax, [v_brfrom]
    mov [rdi + 2088], rax
    mov rcx, [bidlen]
    mov [rdi + 2096], rcx
    test rcx, rcx
    jz ot_count
    lea rsi, [bidtmp]
    lea rax, [rdi + 2104]
    push rdi
    mov rdi, rax
    rep movsb
    pop rdi
ot_count:
    inc qword [hcount]
    ; ---- phase 1: inner summary JSON into jsontmp ----
    lea rax, [jsontmp]
    mov [outptr], rax
    mov qword [outlen], 0
    lea rsi, [jr_num]
    call out_cstr
    mov rax, [v_num]
    call out_uint
    lea rsi, [jr_total]
    call out_cstr
    mov rax, [v_total]
    call out_uint
    lea rsi, [jr_next]
    call out_cstr
    cmp byte [v_next], 0
    je ot_jfalse
    lea rsi, [b_true]
    call out_cstr
    jmp ot_jhist
ot_jfalse:
    lea rsi, [b_false]
    call out_cstr
ot_jhist:
    lea rsi, [jr_hist]
    call out_cstr
    mov rax, [hcount]
    call out_uint
    test qword [gotmask], 1   ; isRevision?
    jz ot_skipr
    lea rsi, [jr_isrev]
    call out_cstr
    cmp byte [v_isrev], 0
    je ot_rfalse
    lea rsi, [b_true]
    call out_cstr
    jmp ot_skipr2
ot_rfalse:
    lea rsi, [b_false]
    call out_cstr
ot_skipr2:
ot_skipr:
    test qword [gotmask], 2   ; revisesThought?
    jz ot_skiprev
    lea rsi, [jr_rev]
    call out_cstr
    mov rax, [v_rev]
    call out_uint
ot_skiprev:
    test qword [gotmask], 4   ; branchFromThought?
    jz ot_skipbr
    lea rsi, [jr_brfrom]
    call out_cstr
    mov rax, [v_brfrom]
    call out_uint
ot_skipbr:
    test qword [gotmask], 8   ; branchId?
    jz ot_skipbid
    lea rsi, [jr_bid]
    call out_cstr
    lea rsi, [bidtmp]
    mov rdx, [bidlen]
    call out_escaped
    mov al, '"'
    call out_byte
ot_skipbid:
    test qword [gotmask], 16  ; needsMoreThoughts?
    jz ot_inner_end
    lea rsi, [jr_more]
    call out_cstr
    cmp byte [v_more], 0
    je ot_mfalse
    lea rsi, [b_true]
    call out_cstr
    jmp ot_inner_end
ot_mfalse:
    lea rsi, [b_false]
    call out_cstr
ot_inner_end:
    mov al, '}'               ; close inner object
    call out_byte
    mov rax, [outlen]
    mov [innerlen], rax
    ; ---- phase 2: outer MCP envelope into outbuf ----
    lea rax, [outbuf]
    mov [outptr], rax
    call out_reset
    lea rsi, [j1]
    call out_cstr
    lea rsi, [idbuf]
    mov rdx, [idlen]
    call out_bytes
    lea rsi, [jrescontent]
    call out_cstr
    lea rsi, [jsontmp]
    mov rdx, [innerlen]
    call out_escaped
    lea rsi, [jcontent_end2]
    call out_cstr
    mov al, 10
    call out_byte
    jmp emit

; PeaBrain on-board model (Stages 1-3 proven). Code lives in the model dir.
include 'model/md_code.asm'

segment gnustack

segment readable writeable

jnull db 'null', 0
v3msg db 'tinythink: x86-64-v3 CPU required (AVX/AVX2/FMA/BMI1/BMI2/LZCNT)', 10
v3msg_len = $ - v3msg

j1 db '{"jsonrpc":"2.0","id":', 0
jres db ',"result":', 0
jerr1 db ',"error":{"code":', 0
jerr2 db ',"message":"', 0
jerr3 db '"}', 0
jrescontent db ',"result":{"content":[{"type":"text","text":"', 0
jcontent_end2 db '"}]}}', 0

jr_num db '{"thoughtNumber":', 0
jr_total db ',"totalThoughts":', 0
jr_next db ',"nextThoughtNeeded":', 0
jr_hist db ',"thoughtHistoryLength":', 0
jr_isrev db ',"isRevision":', 0
jr_rev db ',"revisesThought":', 0
jr_brfrom db ',"branchFromThought":', 0
jr_bid db ',"branchId":"', 0
jr_more db ',"needsMoreThoughts":', 0
jr_thought db ',"thought":"', 0
jhisthead db '{"history":[', 0
jhisttail db '],"historyLength":', 0
r_resetok db '{"reset":true,"thoughtHistoryLength":0}', 0

b_true db 'true', 0
b_false db 'false', 0
st_ns db 'not_started', 0
st_ip db 'in_progress', 0
st_dn db 'done', 0
st_ar db 'archived', 0
st_ca db 'cancelled', 0
pr_lo db 'low', 0
pr_me db 'medium', 0
pr_hi db 'high', 0
pr_cr db 'critical', 0
kd_ent db 'entity', 0
kd_obs db 'observation', 0
kd_fact db 'fact', 0
c127 db 127
c31 db 31
c34 db 34
c92 db 92
c9 db 9
c10 db 10
c13 db 13

k_method db '"method"', 0
k_id db '"id"', 0
k_params db '"params"', 0
k_name db '"name"', 0
k_args db '"arguments"', 0
k_thought db '"thought"', 0
k_next db '"nextThoughtNeeded"', 0
k_thnum db '"thoughtNumber"', 0
k_thtotal db '"totalThoughts"', 0
k_isrev db '"isRevision"', 0
k_rev db '"revisesThought"', 0
k_brfrom db '"branchFromThought"', 0
k_brid db '"branchId"', 0
k_more db '"needsMoreThoughts"', 0
k_reason db '"reason"', 0
k_conc db '"conclusion"', 0
k_valid db '"valid"', 0
k_limit db '"limit"', 0
k_confirm db '"confirm"', 0
k_text db '"text"', 0
k_title db '"title"', 0
k_body db '"body"', 0
k_status db '"status"', 0
k_project db '"project"', 0
k_priority db '"priority"', 0
k_type db '"type"', 0
k_obs db '"observations"', 0
k_query db '"query"', 0
k_names db '"names"', 0
k_search db '"search"', 0
k_from db '"from"', 0
k_to db '"to"', 0
k_entity db '"entity"', 0
k_prefix db '"prefix"', 0
k_signal db '"signal"', 0
k_kind db '"kind"', 0
k_path db '"path"', 0
k_x db '"x"', 0
k_y db '"y"', 0
k_target db '"target"', 0
k_xs db '"xs"', 0
k_ys db '"ys"', 0
k_targets db '"targets"', 0
k_steps db '"steps"', 0
k_lr db '"lr"', 0
k_hidden db '"hidden"', 0
k_seed db '"seed"', 0
k_activation db '"activation"', 0
v_useful db 'useful', 0
v_mislead db 'misleading', 0
v_fact db 'fact', 0
v_entity db 'entity', 0
v_obs db 'observation', 0
v_task db 'task', 0

m_init db 'initialize', 0
m_disc db 'server/discover', 0
m_ping db 'ping', 0
m_list db 'tools/list', 0
m_call db 'tools/call', 0
m_notif db 'notifications/', 0
t_think db 'sequential_thinking', 0
t_conc db 'conclusion', 0
t_hist db 'thought_history', 0
t_reset db 'thought_reset', 0
t_fread db 'read_fact', 0
t_fwrite db 'write_fact', 0
t_flist db 'list_facts', 0
t_mkentity db 'create_entities', 0
t_addobs db 'add_observations', 0
t_search db 'search_nodes', 0
t_open db 'open_nodes', 0
t_mktask db 'create_task_or_note', 0
t_query db 'query_tasks', 0
t_updtask db 'update_task', 0
t_mkrel db 'create_relations', 0
t_delete db 'delete_fact', 0
t_delprefix db 'delete_fact_prefix', 0
t_versions db 'read_fact_versions', 0
t_health db 'health', 0
t_feedback db 'feedback', 0
t_explain db 'explain_rank', 0
t_modinit db 'model_init', 0
t_modtrain db 'model_train', 0
t_modpredict db 'model_predict', 0
t_modsave db 'model_save', 0
t_modload db 'model_load', 0
t_modstatus db 'model_status', 0

c_parse db '-32700', 0
c_invalid db '-32600', 0
c_notfound db '-32601', 0
c_params db '-32602', 0
c_internal db '-32603', 0

m_parse db 'parse error', 0
m_toolong db 'line too long', 0
m_badid db 'bad id', 0
m_nomethod db 'method not found', 0
m_params db 'bad params', 0
m_notool db 'unknown tool', 0
m_unknown db 'unknown thought', 0
m_badname db 'bad name', 0
m_dup db 'duplicate key', 0
m_exists db 'already recorded', 0
m_nodb db 'db error', 0
m_dbfull db 'db full', 0
m_ascii db 'ascii only', 0
m_nofile db 'not found', 0
m_big db 'too large', 0
m_tomb db 'tombstoned', 0

dbexe db '/proc/self/exe', 0
dbfile db 'tinythink.db', 0
jmagic db 'TTJR', 0
m_table db 'table', 0
m_conct db 'conclusions', 0
t_facts_n db 'facts', 0
t_facts_sql db 'CREATE TABLE facts(name TEXT, body TEXT)', 0
t_facts_sqllen = $ - t_facts_sql - 1
t_ent_n db 'entities', 0
t_ent_sql db 'CREATE TABLE entities(name TEXT, type TEXT, project TEXT)', 0
t_ent_sqllen = $ - t_ent_sql - 1
t_obs_n db 'observations', 0
t_obs_sql db 'CREATE TABLE observations(entity TEXT, body TEXT)', 0
t_obs_sqllen = $ - t_obs_sql - 1
t_rel_n db 'relations', 0
t_rel_sql db 'CREATE TABLE relations(src TEXT, dst TEXT, type TEXT)', 0
t_rel_sqllen = $ - t_rel_sql - 1
t_task_n db 'tasks', 0
t_task_sql db 'CREATE TABLE tasks(title TEXT, body TEXT, status TEXT, project TEXT, priority TEXT)', 0
t_task_sqllen = $ - t_task_sql - 1
t_tomb_n db 'tombstones', 0
t_tomb_sql db 'CREATE TABLE tombstones(name TEXT)', 0
t_tomb_sqllen = $ - t_tomb_sql - 1
t_use_n db 'usage', 0
t_use_sql db 'CREATE TABLE usage(name TEXT, kind TEXT, access TEXT, pos TEXT, neg TEXT, last TEXT, conf TEXT, v TEXT)', 0
t_use_sqllen = $ - t_use_sql - 1

dbmagic db 'SQLite format 3', 0
dbsql db 'CREATE TABLE conclusions(reason TEXT, thought TEXT, conclusion TEXT, valid INTEGER)', 0
dbsql_len = $ - dbsql - 1

jc_rowid db '{"rowid":', 0
jc_reason db ',"reason":"', 0
jn_name db ',"name":"', 0
jn_body db ',"body":"', 0
jn_title db ',"title":"', 0
jn_status db ',"status":"', 0
jn_project db ',"project":"', 0
jn_priority db ',"priority":"', 0
jn_type db ',"type":"', 0
jn_id db '{"id":', 0
jn_kind db '{"kind":"', 0
jn_text db ',"text":"', 0
jn_entity db ',"entity":"', 0
jn_from db ',"from":"', 0
jn_to db ',"to":"', 0
jn_created db ',"created":', 0
jn_added db ',"added":', 0
jn_obs db ',"observations":[', 0
jn_rels db '],"relations":[', 0
jn_missing db '{"name":"', 0
jn_miss2 db '","missing":true}', 0
jn_results db '{"results":[', 0
jn_tasks db '{"tasks":[', 0
jn_nodes db '{"nodes":[', 0
jn_deleted db ',"deleted":', 0
jn_note db ',"note":"', 0
m_already db 'already tombstoned', 0
jn_prefix db '{"prefix":"', 0
jn_tombed db ',"tombstoned":', 0
jn_capped db ',"capped":', 0
jn_versions db '{"name":"', 0
jn_tombflag db ',"tombstoned":', 0
jn_recorded db ',"recorded":', 0
jn_signal db ',"signal":"', 0
jn_kindkey db ',"kind":', 0
jn_access db ',"access":', 0
jn_useful db ',"useful":', 0
jn_mislead db ',"misleading":', 0
jn_last db ',"last_tick":', 0
jn_now db ',"now_tick":', 0
jn_conf db ',"confidence":', 0
jn_score db ',"score":', 0
jn_weights db ',"weights":{"a":', 0
jn_wp db ',"p":', 0
jn_wn db ',"n":', 0
jn_wr db ',"r":', 0
jn_wc db ',"c":', 0
jn_window db ',"window":', 0
jn_versarr db ',"versions":[', 0
jn_current db ',"current":', 0
jn_tables db '{"tables":', 0
jn_pages db ',"pages":', 0
jn_journal db ',"journal":', 0
jn_cacheused db ',"cache_used":', 0
jn_tracked db ',"usage_tracked":', 0
jn_pending db ',"pending_flush":', 0
jc_thought db ',"thought":"', 0
jc_conc db ',"conclusion":"', 0
jc_valid db ',"valid":', 0

r_init db '{"protocolVersion":"2024-11-05","capabilities":{"tools":{}}'
       db ',"serverInfo":{"name":"tinythink","version":"0.1"}}', 0
r_empty db '{}', 0
r_listhead db '{"tools":', 0
r_listtail db '}', 0
r_disc db '{"protocolVersion":"2026-07-28","capabilities":{"tools":{}}'
       db ',"serverInfo":{"name":"tinythink","version":"0.1"},"tools":', 0
r_disctail db '}', 0
r_toolsarr db '[{"name":"sequential_thinking"'
       db ',"description":"Structured step-by-step thinking: record thoughts, revise, branch, track progress."'
       db ',"inputSchema":{"type":"object","properties":{"thought":{"type":"string"}'
       db ',"nextThoughtNeeded":{"type":"boolean"},"thoughtNumber":{"type":"integer"}'
       db ',"totalThoughts":{"type":"integer"},"isRevision":{"type":"boolean"}'
       db ',"revisesThought":{"type":"integer"},"branchFromThought":{"type":"integer"}'
       db ',"branchId":{"type":"string"},"needsMoreThoughts":{"type":"boolean"}}'
       db ',"required":["thought","nextThoughtNeeded","thoughtNumber","totalThoughts"]}}'
       db ',{"name":"conclusion"'
       db ',"description":"Record, read or invalidate a conclusion in tinythink.db."'
       db ',"inputSchema":{"type":"object","properties":{"reason":{"type":"string"}'
       db ',"thought":{"type":"string"},"conclusion":{"type":"string"}'
       db ',"valid":{"type":"boolean"}},"required":["reason"]}}'
       db ',{"name":"thought_history"'
       db ',"description":"Read recent thoughts from this connection history."'
       db ',"inputSchema":{"type":"object","properties":{"limit":{"type":"integer"}}}'
       db ',"required":[]}'
       db ',{"name":"thought_reset"'
       db ',"description":"Clear this connection thought history."'
       db ',"inputSchema":{"type":"object","properties":{"confirm":{"type":"boolean"}}}'
       db ',"required":["confirm"]}'
       db ',{"name":"read_fact"'
       db ',"description":"Read a fact by name from tinythink.db."'
       db ',"inputSchema":{"type":"object","properties":{"name":{"type":"string"}}}'
       db ',"required":["name"]}'
       db ',{"name":"write_fact"'
       db ',"description":"Write a fact (new version) to tinythink.db."'
       db ',"inputSchema":{"type":"object","properties":{"name":{"type":"string"}'
       db ',"text":{"type":"string"}},"required":["name","text"]}}'
       db ',{"name":"list_facts"'
       db ',"description":"List fact names in tinythink.db."'
       db ',"inputSchema":{"type":"object","properties":{}}}'
       db ',{"name":"create_entities"'
       db ',"description":"Create an entity, optionally with observations."'
       db ',"inputSchema":{"type":"object","properties":{"name":{"type":"string"}'
       db ',"type":{"type":"string"},"project":{"type":"string"}'
       db ',"observations":{"type":"array","items":{"type":"string"}}}'
       db ',"required":["name"]}}'
       db ',{"name":"add_observations"'
       db ',"description":"Append observations to an entity (auto-creates it)."'
       db ',"inputSchema":{"type":"object","properties":{"name":{"type":"string"}'
       db ',"observations":{"type":"array","items":{"type":"string"}}}'
       db ',"required":["name","observations"]}}'
       db ',{"name":"search_nodes"'
       db ',"description":"Substring search over entities, observations, facts."'
       db ',"inputSchema":{"type":"object","properties":{"query":{"type":"string"}'
       db ',"limit":{"type":"integer"}},"required":["query"]}}'
       db ',{"name":"open_nodes"'
       db ',"description":"Open entities with observations and relations."'
       db ',"inputSchema":{"type":"object","properties":{"names":{"type":"array"'
       db ',"items":{"type":"string"}}},"required":["names"]}}'
       db ',{"name":"create_task_or_note"'
       db ',"description":"Create a task in tinythink.db."'
       db ',"inputSchema":{"type":"object","properties":{"title":{"type":"string"}'
       db ',"body":{"type":"string"},"status":{"type":"string"}'
       db ',"project":{"type":"string"},"priority":{"type":"string"}}}'
       db ',"required":["title"]}'
       db ',{"name":"query_tasks"'
       db ',"description":"Query tasks newest-first with optional filters."'
       db ',"inputSchema":{"type":"object","properties":{"status":{"type":"string"}'
       db ',"project":{"type":"string"},"search":{"type":"string"}'
       db ',"limit":{"type":"integer"}}}'
       db ',"required":[]}'
       db ',{"name":"update_task"'
       db ',"description":"Update task fields (records a new version)."'
       db ',"inputSchema":{"type":"object","properties":{"id":{"type":"integer"}'
       db ',"title":{"type":"string"},"body":{"type":"string"}'
       db ',"status":{"type":"string"},"project":{"type":"string"}'
       db ',"priority":{"type":"string"}}}'
       db ',"required":["id"]}'
       db ',{"name":"create_relations"'
       db ',"description":"Link two entities with a typed relation."'
       db ',"inputSchema":{"type":"object","properties":{"from":{"type":"string"}'
       db ',"to":{"type":"string"},"type":{"type":"string"}}}'
       db ',"required":["from","to","type"]}'
       db ',{"name":"delete_fact"'
       db ',"description":"Tombstone a fact/entity name (hidden from reads; bytes remain on disk)."'
       db ',"inputSchema":{"type":"object","properties":{"name":{"type":"string"}}}'
       db ',"required":["name"]}'
       db ',{"name":"delete_fact_prefix"'
       db ',"description":"Tombstone all facts/entities whose name starts with prefix."'
       db ',"inputSchema":{"type":"object","properties":{"prefix":{"type":"string"}}}'
       db ',"required":["prefix"]}'
       db ',{"name":"read_fact_versions"'
       db ',"description":"All versions of a fact, newest first, with current flag."'
       db ',"inputSchema":{"type":"object","properties":{"name":{"type":"string"}'
       db ',"limit":{"type":"integer"}},"required":["name"]}}'
       db ',{"name":"health"'
       db ',"description":"Database diagnostics: tables, pages, journal, caches."'
       db ',"inputSchema":{"type":"object","properties":{}}'
       db ',"required":[]}'
       db ',{"name":"feedback"'
       db ',"description":"Teach ranking: mark a memory useful or misleading. Durable on return."'
       db ',"inputSchema":{"type":"object","properties":{"name":{"type":"string"}'
       db ',"signal":{"type":"string"},"kind":{"type":"string"}}}'
       db ',"required":["name","signal"]}'
        db ',{"name":"explain_rank"'
        db ',"description":"Why a memory ranks as it does: signals, score, weights."'
        db ',"inputSchema":{"type":"object","properties":{"name":{"type":"string"}'
        db ',"kind":{"type":"string"}}}'
        db ',"required":["name"]}'
        db ',{"name":"model_init"'
        db ',"description":"Initialise the on-board trainable model (2->H->1 leaky MLP, FP32, AVX2/FMA)."'
        db ',"inputSchema":{"type":"object","properties":{"hidden":{"type":"number"}'
        db ',"seed":{"type":"number"},"activation":{"type":"string"}}}}'
        db ',{"name":"model_train"'
        db ',"description":"Train the on-board model on examples (full-batch SGD+momentum, deterministic)."'
        db ',"inputSchema":{"type":"object","properties":{"xs":{"type":"array","items":{"type":"number"}}'
        db ',"ys":{"type":"array","items":{"type":"number"}}'
        db ',"targets":{"type":"array","items":{"type":"number"}}'
        db ',"lr":{"type":"number"},"steps":{"type":"number"}}}'
        db ',"required":["xs","ys","targets"]}'
        db ',{"name":"model_predict"'
        db ',"description":"Predict with the on-board model (FP32 forward)."'
        db ',"inputSchema":{"type":"object","properties":{"xs":{"type":"array","items":{"type":"number"}}'
        db ',"ys":{"type":"array","items":{"type":"number"}}}}'
        db ',"required":["xs","ys"]}'
        db ',{"name":"model_save"'
        db ',"description":"Save model weights, biases, optimiser state and step (crash-safe PBMD)."'
        db ',"inputSchema":{"type":"object","properties":{"path":{"type":"string"}}}}'
        db ',{"name":"model_load"'
        db ',"description":"Load a model checkpoint (validated; bad files rejected, current kept)."'
        db ',"inputSchema":{"type":"object","properties":{"path":{"type":"string"}}}}'
        db ',{"name":"model_status"'
        db ',"description":"Model dimensions, steps, loss, memory, compute backend."'
        db ',"inputSchema":{"type":"object","properties":{}}}]', 0

lp dq 0
ll dq 0
le dq 0
tmp dq 0
pp dq 0
ap dq 0
methodlen dq 0
toollen dq 0
idlen dq 0
outlen dq 0
outptr dq 0
innerlen dq 0
linelen dq 0
hcount dq 0
thlen dq 0
bidlen dq 0
gotmask dq 0
numval dq 0
cmask dq 0
rsnlen dq 0
cthlen dq 0
cclen dq 0
clen dq 0
slen dq 0
reclen dq 0
dblen dq 0
dbfd dq 0
dbpages dq 0
maxrowid dq 0
newrowid dq 0
curpg dq 0
fpage dq 0
frowid dq 0
fo_r dq 0
fl_r dq 0
fo_t dq 0
fl_t dq 0
fo_c dq 0
fl_c dq 0
fvoff dq 0
divkey dq 0
vlen dq 0
wcontent dq 0
wn dq 0
splitk dq 0
splitn dq 0
halfsz dq 0
lpg dq 0
qpg dq 0
tmprow dq 0
tmpvoff dq 0
rfsize dq 0
jfd dq 0
jn dq 0
jactive dq 0
jorig dq 0
cskip dq 0
cino dq 0
csize dq 0
cmtim dq 0, 0
ctick dq 0
cpg dq 16 dup (0)
cuse dq 16 dup (0)
sncol dq 0
stcoff dq 0
scurpg dq 0
sidx dq 0
nemit dq 0
udirty dq 0
uloaded dq 0
ulkey dq 0
ulhits dq 0
utick dq 0
uq_head dq 0
uq_tail dq 0
udropped dq 0
ulh2 dq 0
ulacc dq 0
ulpos dq 0
ulneg dq 0
ullast dq 0
ulconf dq 0
ulname dq 0
ulnamelen dq 0
ulkind dq 0
chsaven dq 0
uv2 db '2', 0
dbwmode dq 0
tombnm dq 0
tombnl dq 0
dpcap dq 0
sroot dq 0
smode dq 0
scount dq 0
stci dq 0
stn dq 0
stcell dq 0
obsarr dq 0
obadded dq 0
mcreated db 0
typelen dq 0
projlen dq 0
taskseq dq 0
mbodylen dq 0
titlelen dq 0
taskblen dq 0
stlen dq 0
prilen dq 0
qlen dq 0
rllen dq 0
oblen dq 0
slim dq 0
qtid dq 0
tmask dq 0
m_name dq 0
m_namelen dq 0
m_rootpg dq 0
m_sql dq 0
m_sqllen dq 0
m_rowid dq 0
mmaxrowid dq 0
ftname dq 0
ftlen dq 0
ts1 dq 0
ts2 dq 0
ts3 dq 0
ts3p dq 0
wroot dq 0
childn dq 0
et_root dq 0
obcount dq 0
relcount dq 0
fseenn dq 0
tseenn dq 0
mkey dq 0
mkeylen dq 0
growid dq 0
gcols dq 0
ncols dq 0
hlimit dq 0
hcur dq 0
hslot dq 0
splitroot dq 2
pagebase dq 0
f_root_facts dq 0
f_root_ent dq 0
f_root_obs dq 0
f_root_rel dq 0
f_root_tasks dq 0
f_root_use dq 0
f_root_tomb dq 0
hfirst db 0
v_num dq 0
v_total dq 0
v_rev dq 0
v_brfrom dq 0
v_next db 0
v_isrev db 0
v_more db 0
boolval db 0
idisstr db 0
discard db 0
cvalid db 0
fvalid db 0

bidtmp rb 40
methodbuf rb 32
toolbuf rb 32
idbuf rb 96
numtmp rb 32
jbuf2 rb 8
jpages rb 256
sbtmp rb 32
ukeybuf rb 24
uhitbuf rb 24
udec rb 24
unum0 rb 24
unum1 rb 24
unum2 rb 24
unum3 rb 24
unum4 rb 24
uqnum rb 24
ukind1 rb 8
svstate rb 288
recscratch rb 64
rsnbuf rb 128
sigbuf rb 16
siglen dq 0
rnbuf rb 128
rnlen dq 0
rnsave dq 0
rntarget dq 0
rnncell dq 0
fbkind dq 0
fbsig dq 0
fbobsid dq 0
exscore dq 0
exacc dq 0
expos dq 0
exneg dq 0
exlast dq 0
exnow dq 0
exconf dq 0
thbuf rb 512
ccbuf rb 512
dbstat rb 144
dstack rb 128
ddepth dq 0
ppg dq 0
; PeaBrain on-board model consts (initialized, before trailing BSS).
include 'model/md_consts.asm'
sob rb 128
ktab rb 768
stab rb 64
gfo rb 64
gfl rb 64
colp rb 64
coll rb 64
typebuf rb 32
projbuf rb 32
titlebuf rb 128
stbuf rb 16
pribuf rb 16
qbuf rb 128
relbuf rb 128

; ---- trailing BSS: all large zero-initialised buffers live here, AFTER
; the last initialised datum, so FASM emits them as NOBITS instead of
; file-backed zeros (a 1 MB rb before a dq costs 1 MB on disk; after
; costs ~0). Keep this group last: anything appended below uninitialised
; stays free, anything initialised re-inflates the file. Sizes are pure
; BSS (zero-filled at load, identical semantics to file zeros).
inbuf rb 4096
line rb 8192
outbuf rb 65536
jsontmp rb 65536
thtmp rb 2048
exebuf rb 1024
dbpath rb 1088
dbdirb rb 1088
jpath rb 1104
jbuf rb 4096
cdata rb 65536
utab rb 8388608
uqueue rb 1114112
sbuf rb 2048
pagebuf rb 4096
leafbuf rb 4096
ipage rb 4096
celltmp rb 2048
recbuf rb 2048
sizetab rb 8192
offstab rb 8192
childtab rb 524288
chsave rb 524288
rnpsave rb 4096
mbody rb 4096
taskbuf rb 1024
obsbuf rb 1024
fseen rb 16512
tseetab rb 4096
thslots rb 137216

; PeaBrain on-board model data (consts, then ALL rb trailing: NOBITS).
include 'model/md_data.asm'
