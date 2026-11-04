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
; SQLite subset (genuine file format, opens in real sqlite3):
;   page size 4096, UTF-8, single table + sqlite_master, rowid leaf pages,
;   size-ordered leaf splits, root interior once split, whole-db flock,
;   fsync per write txn. Limits: cell <= ~1100B, interior never splits
;   (~600 leaves, thousands of conclusions), no overflow pages, no journal.
; Assumes standard key order (method/id before params, name before arguments).

format ELF64 executable 3
entry start

segment readable executable

start:
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

; out_escaped(rsi=ptr, rdx=len)
out_escaped:
    test rdx, rdx
    jz oe_ret
    push rbx
    mov rbx, rsi
    add rdx, rsi
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

emit:
    mov eax, 1
    mov edi, 1
    lea rsi, [outbuf]
    mov rdx, [outlen]
    syscall
    ret

; ---------------- parsers ----------------
; find_val(rsi=start, rdi=key, rcx=keylen): rax=ptr after colon+ws, 0=no.
find_val:
    push rbx
    push r12
    push r13
    mov r12, rsi
    mov r13, rdi
    mov r10, rcx
fv_scan:
    mov rax, [le]
    sub rax, r12
    cmp rax, r10
    jb fv_no
    mov r8, r12
    mov r9, r13
    mov rax, r10
fv_cmp:
    test rax, rax
    jz fv_hit
    mov cl, [r8]
    mov dl, [r9]
    cmp cl, dl
    jne fv_next
    inc r8
    inc r9
    dec rax
    jmp fv_cmp
fv_hit:
    mov r12, r8
fv_colon:
    cmp r12, [le]
    jae fv_no
    cmp byte [r12], ':'
    je fv_ws0
    inc r12
    jmp fv_colon
fv_ws0:
    inc r12
fv_ws:
    cmp r12, [le]
    jae fv_no
    mov al, [r12]
    cmp al, ' '
    je fv_wsn
    cmp al, 9
    je fv_wsn
    cmp al, 13
    je fv_wsn
    cmp al, 10
    je fv_wsn
    mov rax, r12
    pop r13
    pop r12
    pop rbx
    ret
fv_wsn:
    inc r12
    jmp fv_ws
fv_next:
    inc r12
    jmp fv_scan
fv_no:
    xor eax, eax
    pop r13
    pop r12
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
    mov ecx, 64
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
    call db_open
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

; ascii_only(rsi, rdx=len): rax=0 ok, 1 bad. allows 9,10,13,32..126.
ascii_only:
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
pg_read:
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

; pg_write(rdi=pgno, rsi=buf): rax 0 ok / 1 err
pg_write:
    mov r10, rdi
    dec r10
    shl r10, 12
    mov rdi, [dbfd]
    mov edx, 4096
    mov eax, 18
    syscall
    cmp rax, 4096
    je pgw_ok
    mov eax, 1
    ret
pgw_ok:
    xor eax, eax
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
db_open:
    mov eax, 89                 ; readlink /proc/self/exe
    lea rdi, [dbexe]
    lea rsi, [exebuf]
    mov edx, 1024
    syscall
    cmp rax, 0
    jle do_cwd
    mov rcx, rax
do_sl:
    dec rcx
    js do_cwd
    cmp byte [exebuf + rcx], '/'
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
    jmp do_open
do_cwd:
    lea rsi, [dbfile]
    lea rdi, [dbpath]
    mov ecx, 12
    rep movsb
    mov byte [rdi], 0
    mov qword [dblen], 12
do_open:
    mov eax, 2
    lea rdi, [dbpath]
    mov esi, 66                 ; O_RDWR|O_CREAT
    mov edx, 420
    syscall
    test rax, rax
    js do_err
    mov [dbfd], rax
    mov eax, 73                 ; flock LOCK_EX
    mov rdi, [dbfd]
    mov esi, 2
    syscall
    test rax, rax
    js do_closeerr
    mov eax, 5                  ; fstat: st_size @ +48
    mov rdi, [dbfd]
    lea rsi, [dbstat]
    syscall
    test rax, rax
    js do_closeerr
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
    call scan_max
    xor eax, eax
    ret
do_create:
    call db_create
    test rax, rax
    jnz do_closeerr
    xor eax, eax
    ret
do_closeerr:
    push rax
    mov eax, 3
    mov rdi, [dbfd]
    syscall
    pop rax
    mov eax, 1
do_err:
    ret

; db_close: fsync, unlock, close. preserves rax.
db_close:
    push rax
    mov eax, 74
    mov rdi, [dbfd]
    syscall
    mov eax, 73
    mov rdi, [dbfd]
    mov esi, 8                  ; LOCK_UN
    syscall
    mov eax, 3
    mov rdi, [dbfd]
    syscall
    pop rax
    ret

; db_create: fresh header + master + empty leaf. rax 0/1.
db_create:
    lea rdi, [pagebuf]
    mov ecx, 4096
    xor eax, eax
    rep stosb
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
    xor eax, eax
    rep stosb
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
    xor eax, eax
    ret
dbc_err:
    mov eax, 1
    ret

; build_master_cell -> celltmp, [clen]. rax 0/1.
build_master_cell:
    push rbx
    ; serials: 'table'(5)->23, name(11)->35, tbl(11)->35, rootpage 2->1, sql->13+2n
    lea rdi, [recscratch]
    mov rax, 23
    call varint_put
    mov [slen], rcx
    lea rdi, [recscratch]
    add rdi, rcx
    mov rax, 35
    call varint_put
    add [slen], rcx
    lea rdi, [recscratch]
    add rdi, [slen]
    mov rax, 35
    call varint_put
    add [slen], rcx
    lea rdi, [recscratch]
    add rdi, [slen]
    mov rax, 1
    call varint_put
    add [slen], rcx
    mov rax, dbsql_len
    lea rbx, [rax + rax + 13]   ; serial for sql text
    lea rdi, [recscratch]
    add rdi, [slen]
    mov rax, rbx
    call varint_put
    add [slen], rcx
    ; record into recbuf: [hdrsize][serials][body]
    mov rax, [slen]
    inc rax                       ; hdrsize H (= 1 + S, serials counted once)
    mov [reclen], rax
    lea rdi, [recbuf]
    call varint_put               ; emit H
    lea rsi, [recscratch]
    mov rcx, [slen]
    rep movsb                     ; serials (already counted in H)
    lea rsi, [m_table]          ; 'table'
    mov ecx, 5
    add [reclen], rcx
    rep movsb
    lea rsi, [m_conct]          ; 'conclusions'
    mov ecx, 11
    add [reclen], rcx
    rep movsb
    lea rsi, [m_conct]
    mov ecx, 11
    add [reclen], rcx
    rep movsb
    mov al, 2                   ; rootpage
    stosb
    inc qword [reclen]
    lea rsi, [dbsql]
    mov rcx, dbsql_len
    add [reclen], rcx
    rep movsb
    ; cell: [payload=reclen][rowid=1][record]
    lea rdi, [celltmp]
    mov rax, [reclen]
    call varint_put
    mov [clen], rcx
    lea rdi, [celltmp]
    add rdi, rcx
    mov rax, 1
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

; scan_max: max cell rowid over leaf pages -> [maxrowid].
scan_max:
    push rbx
    push r12
    push r13
    mov qword [maxrowid], 0
    mov r12, 2
sm_page:
    mov rax, [dbpages]
    cmp r12, rax
    ja sm_done
    mov rdi, r12
    lea rsi, [pagebuf]
    call pg_read
    test rax, rax
    jnz sm_next
    cmp byte [pagebuf], 0x0D
    jne sm_next
    lea rsi, [pagebuf + 3]
    call be16_ld
    mov rbx, rax                ; n
    xor r13d, r13d              ; i (r13 survives varint_get)
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
    jz sm_next
    mov rsi, rcx
    call varint_get             ; rowid
    test rcx, rcx
    jz sm_next
    cmp rax, [maxrowid]
    jbe sm_inci
    mov [maxrowid], rax
sm_inci:
    inc r13
    jmp sm_cell
sm_next:
    inc r12
    jmp sm_page
sm_done:
    pop r13
    pop r12
    pop rbx
    ret

; rightmost_leaf: descend to rightmost leaf. [curpg]=pgno, pagebuf set. rax 0/1.
rightmost_leaf:
    mov rdi, 2
rl_loop:
    mov [curpg], rdi
    push rdi
    lea rsi, [pagebuf]
    call pg_read
    pop rdi
    test rax, rax
    jnz rl_err
    mov al, [pagebuf]
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

; insert_row: build assumed done? No: builds cell, inserts at right edge
; (uses [newrowid] + field bufs). rax 0 ok / 1 io / 2 full.
insert_row:
    push rbx
    push r12
    call build_data_cell
    call rightmost_leaf
    test rax, rax
    jnz ir_err
    ; free in pagebuf leaf (base 0)
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
    jb ir_split
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

; split_leaf: pagebuf=P full leaf, [curpg]=P, new cell in celltmp.
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
    cmp qword [curpg], 2
    je sp_rootcase
    ; ---- case B: parent is root interior (page 2) ----
    mov edi, 2
    lea rsi, [ipage]
    call pg_read
    test rax, rax
    jnz sp_err
    ; divider size check first (no writes yet on full)
    mov rax, [divkey]
    lea rdi, [recscratch]
    call varint_put             ; rcx = vlen
    mov [vlen], rcx
    lea rsi, [ipage + 3]
    call be16_ld                ; n2
    mov r14, rax
    lea rsi, [ipage + 5]
    call be16_ld                ; content2
    sub rax, 12
    mov rcx, r14
    shl rcx, 1
    sub rax, rcx                ; free2
    mov rcx, [vlen]
    add rcx, 6                  ; 4 child + vlen + 2 ptr
    cmp rax, rcx
    jb sp_full                  ; interior full: clean abort, nothing written
    mov rax, [dbpages]
    inc rax
    mov [dbpages], rax          ; Qno
    mov [qpg], rax
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
    mov rdi, [qpg]
    lea rsi, [leafbuf]
    call pg_write
    test rax, rax
    jnz sp_err
    ; append divider (child=P, key) to interior, rightmost=Q
    lea rsi, [ipage + 5]
    call be16_ld                ; content2
    mov rcx, [vlen]
    add rcx, 4
    sub rax, rcx                ; celloff
    mov [wcontent], rax
    lea rdi, [ipage]
    add rdi, rax
    mov rax, [curpg]
    call be32_st
    lea rdi, [ipage]
    add rdi, [wcontent]
    add rdi, 4
    mov rax, [divkey]
    call varint_put
    lea rsi, [ipage + 12]     ; interior ptrs start at +12
    mov rax, r14
    shl rax, 1
    add rsi, rax
    mov rax, [wcontent]
    mov rdi, rsi
    call be16_st
    lea rsi, [ipage + 3]
    mov rax, r14
    inc rax
    mov rdi, rsi
    call be16_st
    lea rsi, [ipage + 5]
    mov rax, [wcontent]
    mov rdi, rsi
    call be16_st
    mov rax, [qpg]
    lea rdi, [ipage + 8]
    call be32_st
    mov edi, 2
    lea rsi, [ipage]
    call pg_write
    test rax, rax
    jnz sp_err
    jmp sp_ok
sp_rootcase:
    ; ---- case A: P==2 root leaf -> reorg ----
    mov rax, [dbpages]
    inc rax
    mov [dbpages], rax          ; Lno
    mov [lpg], rax
    mov rax, [dbpages]
    inc rax
    mov [dbpages], rax          ; Qno
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
    mov edi, 2
    lea rsi, [pagebuf]
    call pg_write
    test rax, rax
    jnz sp_err
sp_ok:
    mov rax, [newrowid]
    mov [maxrowid], rax
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

; scan_reason: find rsnbuf/rsnlen in leaf pages.
; rax 0 notfound / 1 found / 2 corrupt. Found fills fpage/frowid/fo_*/fl_*/fvalid/fvoff.
scan_reason:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov r12, 2
sr_page:
    mov rax, [dbpages]
    cmp r12, rax
    ja sr_none
    mov rdi, r12
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
    mov rsi, rcx                ; rec
    call varint_get             ; hdrsize
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
    mov [fpage], r12
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
    ; totalThoughts (required int)
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
    mov [rdi + 2072], rax     ; flags low bit = nextNeeded
    movzx rax, byte [v_isrev]
    shl rax, 1
    or [rdi + 2072], rax
    movzx rax, byte [v_more]
    shl rax, 2
    or [rdi + 2072], rax
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

segment readable writeable

jnull db 'null', 0

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

b_true db 'true', 0
b_false db 'false', 0

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

m_init db 'initialize', 0
m_disc db 'server/discover', 0
m_ping db 'ping', 0
m_list db 'tools/list', 0
m_call db 'tools/call', 0
m_notif db 'notifications/', 0
t_think db 'sequential_thinking', 0
t_conc db 'conclusion', 0

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
m_exists db 'already recorded', 0
m_nodb db 'db error', 0
m_dbfull db 'db full', 0
m_ascii db 'ascii only', 0
m_nofile db 'not found', 0
m_big db 'too large', 0

dbexe db '/proc/self/exe', 0
dbfile db 'tinythink.db', 0
m_table db 'table', 0
m_conct db 'conclusions', 0

dbmagic db 'SQLite format 3', 0
dbsql db 'CREATE TABLE conclusions(reason TEXT, thought TEXT, conclusion TEXT, valid INTEGER)', 0
dbsql_len = $ - dbsql - 1

jc_rowid db '{"rowid":', 0
jc_reason db ',"reason":"', 0
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
       db ',"valid":{"type":"boolean"}},"required":["reason"]}}]', 0

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

inbuf rb 4096
line rb 8192
outbuf rb 16384
jsontmp rb 4096
thtmp rb 2048
bidtmp rb 40
methodbuf rb 32
toolbuf rb 32
idbuf rb 96
numtmp rb 32
exebuf rb 1024
dbpath rb 1088
pagebuf rb 4096
leafbuf rb 4096
ipage rb 4096
celltmp rb 2048
recbuf rb 2048
recscratch rb 64
rsnbuf rb 64
thbuf rb 512
ccbuf rb 512
dbstat rb 144
sizetab rb 4096
offstab rb 4096
thslots rb 137216
