; think.asm - ultra tiny sequential-thinking MCP server, FASM ELF64, no libc.
;
; Mimics @modelcontextprotocol/server-sequential-thinking.
; Transport: newline-delimited JSON-RPC 2.0 on stdin/stdout (MCP stdio).
; Serves both eras: 2026-07-28 clients (server/discover, no handshake) and
; 2025-era clients (initialize). Thought history lives in RAM for as long as
; the client's connection (one process = one connection).
; Methods: initialize, server/discover, ping, tools/list, tools/call.
; No-id => notification, no reply. Tool: sequential_thinking.
; Required: thought(string 1..2048), nextThoughtNeeded(bool),
;   thoughtNumber(int), totalThoughts(int).
; Optional: isRevision(bool), revisesThought(int), branchFromThought(int),
;   branchId(string 0..40), needsMoreThoughts(bool).
; Ring buffer: 64 thoughts; history length counts all recorded.
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
    lea rdi, [c_params]
    lea rsi, [m_notool]
    jmp err_id
dc_params:
    lea rdi, [c_params]
    lea rsi, [m_params]
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

m_init db 'initialize', 0
m_disc db 'server/discover', 0
m_ping db 'ping', 0
m_list db 'tools/list', 0
m_call db 'tools/call', 0
m_notif db 'notifications/', 0
t_think db 'sequential_thinking', 0

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
       db ',"required":["thought","nextThoughtNeeded","thoughtNumber","totalThoughts"]}}]', 0

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
thslots rb 137216
