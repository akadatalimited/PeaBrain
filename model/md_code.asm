; PeaBrain on-board trainable model: FP32 MLP + MCP tools (Stages 1-3 proven).
; Included into tinythink.asm executable segment (before segment gnustack).
; All globals md-prefixed; preserves rbx,r12-r15 across calls (host ABI).
; Uses host: pp, ap, find_val, parse_str, cmp_name, dc_params, err_id,
; c_params, oc_envelope, jsontmp, outptr, outlen, out_reset, out_cstr,
; out_uint, out_byte, b_true, b_false, jnull, le.

; ================= A. float/array utils =================
; md_parse_f32: rsi=text rdx=endbound -> xmm0=value rax=0 ok (rsi=after)
;   / rax=1 bad. [+-]? (digits [.digits] | .digits) ([eE][+-]?digits)?.
;   Mantissa capped at 1e9 (extra digits fold into exp); value=mant*10^exp.
;   Rejects: empty, no digits, dangling dot/e, exp beyond +-350.
;   Exact for <=7 significant digits, ~2ulp beyond. Preserves rbx,r12-r15.
md_parse_f32:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov r12, rsi
    mov r13, rdx
    cmp r12, r13
    jae .bad
    xor r14d, r14d                  ; sign
    mov al, [r12]
    cmp al, '+'
    je .sgn
    cmp al, '-'
    jne .dig
    mov r14d, 1
.sgn:
    inc r12
    cmp r12, r13
    jae .bad
.dig:
    xor ebx, ebx                    ; mantissa u64
    xor r15d, r15d                  ; ndig
    xor r10d, r10d                  ; anydig
    xor r11d, r11d                  ; exp10 (s32 in r11d; range small)
.intlp:
    cmp r12, r13
    jae .intdone
    mov al, [r12]
    sub al, '0'
    cmp al, 9
    ja .intdone
    movzx eax, al
    mov r10d, 1
    cmp r15d, 9
    jae .intexp
    imul rbx, rbx, 10
    add rbx, rax
    inc r15d
    jmp .intnext
.intexp:
    inc r11d
.intnext:
    inc r12
    jmp .intlp
.intdone:
    cmp r12, r13
    jae .expchk
    cmp byte [r12], '.'
    jne .expchk
    inc r12
    xor r10d, r10d                  ; frac needs own digit (strict trailing dot)
    mov r10d, 1                     ; (reuse: require >=1 below via r8d)
    xor r8d, r8d                    ; fracdig flag
.frlp:
    cmp r12, r13
    jae .frdone
    mov al, [r12]
    sub al, '0'
    cmp al, 9
    ja .frdone
    movzx eax, al
    mov r8d, 1
    cmp r15d, 9
    jae .frnext
    imul rbx, rbx, 10
    add rbx, rax
    inc r15d
    dec r11d
    jmp .frnext2
.frnext:
    ; extra frac digit dropped (documented precision note)
.frnext2:
    inc r10d                        ; (anydig already set if int had digits)
    inc r12
    jmp .frlp
.frdone:
    test r8d, r8d
    jz .bad
    mov r10d, 1
.expchk:
    test r10d, r10d
    jz .bad
    cmp r12, r13
    jae .done
    mov al, [r12]
    cmp al, 'e'
    je .hasexp
    cmp al, 'E'
    jne .done
.hasexp:
    inc r12
    cmp r12, r13
    jae .bad
    xor ecx, ecx                    ; esign 0/1
    mov al, [r12]
    cmp al, '+'
    je .esign
    cmp al, '-'
    jne .edigits
    mov ecx, 1
.esign:
    inc r12
    cmp r12, r13
    jae .bad
.edigits:
    xor r9d, r9d                    ; anyedig
    xor eax, eax                    ; exval
.eld:
    cmp r12, r13
    jae .edone
    mov dl, [r12]
    sub dl, '0'
    cmp dl, 9
    ja .edone
    movzx edx, dl
    imul eax, eax, 10
    add eax, edx
    cmp eax, 400
    ja .bad                         ; exp magnitude guard
    mov r9d, 1
    inc r12
    jmp .eld
.edone:
    test r9d, r9d
    jz .bad
    test ecx, ecx
    jz .epos
    neg eax
.epos:
    add r11d, eax
.done:
    ; range check total exp
    cmp r11d, 38
    jg .bad
    cmp r11d, -50
    jl .under
    cvtsi2ss xmm0, rbx
    movss xmm1, [md_f10]
    test r11d, r11d
    jz .sgnapp
    jg .mulp
.divlp:
    divss xmm0, xmm1
    inc r11d
    jnz .divlp
    jmp .sgnapp
.mulp:
    mulss xmm0, xmm1
    dec r11d
    jnz .mulp
.sgnapp:
    test r14d, r14d
    jz .ret
    xorps xmm1, xmm1
    subss xmm1, xmm0
    movaps xmm0, xmm1
.ret:
    mov rsi, r12
    xor eax, eax
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret
.under:
    xorps xmm0, xmm0
    test r14d, r14d
    jz .ret2
    movss xmm0, [md_fneg0]          ; -0.0
.ret2:
    mov rsi, r12
    xor eax, eax
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret
.bad:
    mov eax, 1
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; md_skip_ws: rsi=ptr rdx=end -> rsi past spaces/tabs/CR/LF.
md_skip_ws:
.sw:
    cmp rsi, rdx
    jae .done
    mov al, [rsi]
    cmp al, ' '
    je .adv
    cmp al, 9
    je .adv
    cmp al, 13
    je .adv
    cmp al, 10
    jne .done
.adv:
    inc rsi
    jmp .sw
.done:
    ret

; md_out_f32e6: xmm0=value -> JSON number (6 decimals) or null (NaN/|v|>=1e12).
; Uses out_uint/out_byte. Preserves rbx,r12-r15.
md_out_f32e6:
    push rbx
    push r12
    ucomiss xmm0, xmm0
    jp .null
    lea rax, [md_absmask]
    movups xmm2, [rax]
    movaps xmm1, xmm0
    andps xmm1, xmm2
    ucomiss xmm1, [md_f1e12]
    jae .null
    xorps xmm2, xmm2
    ucomiss xmm0, xmm2
    jae .pos
    mov al, '-'
    call out_byte
    xorps xmm2, xmm2
    subss xmm2, xmm0
    movaps xmm0, xmm2
.pos:
    cvttss2si rax, xmm0
    push rax
    call out_uint
    mov al, '.'
    call out_byte
    pop rax
    cvtsi2ss xmm1, rax
    subss xmm0, xmm1
    mulss xmm0, [md_f1e6]
    cvttss2si rax, xmm0             ; 0..999999
    ; emit 6 digits, leading zeros
    lea rsi, [md_numbuf + 16]
    mov rcx, 6
    mov rbx, 10
.dig:
    xor edx, edx
    div rbx
    add dl, '0'
    dec rsi
    mov [rsi], dl
    dec rcx
    jne .dig
    mov rdx, 6
    call out_bytes
    pop r12
    pop rbx
    ret
.null:
    lea rsi, [jnull]
    call out_cstr
    pop r12
    pop rbx
    ret

; md_parse_farray: rsi='['ptr rdx=end rdi=dstfloats rcx=maxcount
; -> rax=0 ok (rdx=count, rsi=after-']') / rax=1 bad. preserves rbx,r12-r15.
md_parse_farray:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov r14, rsi                    ; (keep original bound in rdx)
    mov r15, rdx                    ; end
    mov r12, rdi                    ; dst
    mov r13, rcx                    ; max
    mov rsi, r14
    mov rdx, r15
    call md_skip_ws
    cmp rsi, rdx
    jae .bad
    cmp byte [rsi], '['
    jne .bad
    inc rsi
    xor ebx, ebx                    ; count
.elem:
    mov rdx, r15
    call md_skip_ws
    cmp rsi, rdx
    jae .bad
    cmp byte [rsi], ']'
    jne .dofloat
    jmp .bad                        ; empty [] and trailing comma rejected
.dofloat:
    call md_parse_f32               ; xmm0=val, rsi=after
    test rax, rax
    jnz .bad
    cmp rbx, r13
    jae .bad                        ; over maxcount
    movss [r12 + rbx*4], xmm0
    inc rbx
    mov rdx, r15
    call md_skip_ws
    cmp rsi, rdx
    jae .bad
    mov al, [rsi]
    cmp al, ','
    je .next
    cmp al, ']'
    jne .bad
    inc rsi
    jmp .fin
.next:
    inc rsi
    jmp .elem
.fin:
    test rbx, rbx
    jz .bad
    mov rdx, rbx                    ; count
    xor eax, eax
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret
.bad:
    mov eax, 1
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ================= B. arena + PBMD v2 =================
; 4GiB mmap arena (NORESERVE), page-aligned bump allocator, 8 model regions.
; PBMD v2 header (64B LE): magic 'PBMD', ver, arch=1, flags, count,
; H u32 @20, step u64 @24, payload_bytes @32, table_hash @40, payload_hash
; @48, act u64 @56. v1 files load with documented defaults (H=16, leaky).
; Save: tmp sibling + fsync + atomic rename + dirsync; failures unlink tmp.
; Load: stages from a saved mark, rolls back on any failure (live model
; survives bad checkpoints).
MD_ARENA_SIZE = 0x100000000
MD_MAXREG     = 8
MD_REGENT_SZ  = 32
MD_PAGE       = 4096
MD_MINCORE_CHUNK = 0x10000000
MD_VEC_SZ        = 65536
MD_FNV_OFF = 0xcbf29ce484222325
MD_FNV_PRM = 0x100000001b3
MD_PBMD_MAGIC = 0x444D4250
MD_PBMD_VER   = 2
MD_PBMD_ARCH  = 1
MD_AT_FDCWD   = -100
MD_O_RDONLY   = 0
MD_O_RDWR     = 2
MD_O_CREAT    = 64
MD_O_EXCL     = 128
MD_O_DIRECTORY = 65536
MD_MAP_PRIVATE   = 2
MD_MAP_ANONYMOUS = 32
MD_MAP_NORESERVE = 16384

; md_fnv64: rsi=ptr rdx=len -> rax=FNV-1a-64 hash (NOT a CRC).
md_fnv64:
    mov rax, MD_FNV_OFF
    test rdx, rdx
    jz .done
.loop:
    movzx ecx, byte [rsi]
    xor rax, rcx
    mov rcx, MD_FNV_PRM
    imul rax, rcx
    inc rsi
    dec rdx
    jne .loop
.done:
    ret

; md_write_all: rdi=fd rsi=ptr rdx=len -> rax=0 ok / -1 fail.
md_write_all:
    push rbx
    push r12
    mov rbx, rsi
    mov r12, rdx
.loop:
    test r12, r12
    jz .ok
    mov rax, 1
    mov rsi, rbx
    mov rdx, r12
    syscall
    cmp rax, -4
    je .loop
    cmp rax, 0
    jle .fail
    add rbx, rax
    sub r12, rax
    jmp .loop
.ok:
    xor eax, eax
    pop r12
    pop rbx
    ret
.fail:
    mov rax, -1
    pop r12
    pop rbx
    ret

; md_read_all: rdi=fd rsi=ptr rdx=len -> rax=0 ok / -1 fail/short.
md_read_all:
    push rbx
    push r12
    mov rbx, rsi
    mov r12, rdx
.loop:
    test r12, r12
    jz .ok
    mov rax, 0
    mov rsi, rbx
    mov rdx, r12
    syscall
    cmp rax, -4
    je .loop
    cmp rax, 0
    jle .fail
    add rbx, rax
    sub r12, rax
    jmp .loop
.ok:
    xor eax, eax
    pop r12
    pop rbx
    ret
.fail:
    mov rax, -1
    pop r12
    pop rbx
    ret

; md_close_fd: rdi=fd.
md_close_fd:
    mov rax, 3
    syscall
    ret

; md_arena_init -> rax=0 ok / -1 fail. Maps once; later calls reuse.
md_arena_init:
    cmp qword [md_arenabase], 0
    jne .ok
    mov rax, 9
    xor edi, edi
    mov rsi, MD_ARENA_SIZE
    mov edx, 3
    mov r10d, MD_MAP_PRIVATE + MD_MAP_ANONYMOUS + MD_MAP_NORESERVE
    mov r8, -1
    xor r9d, r9d
    syscall
    cmp rax, -4095
    jae .err
    mov [md_arenabase], rax
.ok:
    xor eax, eax
    ret
.err:
    mov rax, -1
    ret

; md_arena_reset: drop all regions (arena holds model regions only).
md_arena_reset:
    mov qword [md_acur], 0
    mov qword [md_nreg], 0
    ret

; md_arena_alloc: rdi=size rsi=align(min 64, forced >=4096) rdx=tag
; -> rax=addr or 0. preserves rbx,r12-r15.
md_arena_alloc:
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    cmp r12, MD_PAGE
    jae .alok
    mov r12, MD_PAGE
.alok:
    mov rax, [md_acur]
    lea rcx, [r12 - 1]
    add rax, rcx
    not rcx
    and rax, rcx
    mov rdx, rax
    add rdx, rbx
    jc .fail
    mov r10, MD_ARENA_SIZE
    cmp rdx, r10
    ja .fail
    mov rcx, [md_nreg]
    cmp rcx, MD_MAXREG
    jae .fail
    mov [md_acur], rdx
    lea r10, [md_regtab]
    mov rdx, rcx
    shl rdx, 5
    add r10, rdx
    mov [r10], r13
    mov [r10 + 8], rax
    mov [r10 + 16], rbx
    mov [r10 + 24], r12
    inc qword [md_nreg]
    add rax, [md_arenabase]
    pop r13
    pop r12
    pop rbx
    ret
.fail:
    xor eax, eax
    pop r13
    pop r12
    pop rbx
    ret

; md_committed -> rax=resident bytes over live regions (mincore), -1 on err.
md_committed:
    push rbx
    push r12
    push r13
    push r14
    push r15
    xor r15d, r15d
    xor r12d, r12d
    mov r13, [md_nreg]
    test r13, r13
    jz .done
.regloop:
    mov rax, r12
    shl rax, 5
    lea rbx, [md_regtab]
    add rbx, rax
    mov r14, [rbx + 8]
    add r14, [md_arenabase]
    mov rax, [rbx + 16]
    add rax, MD_PAGE - 1
    and rax, -MD_PAGE
.pageloop:
    test rax, rax
    jz .nextreg
    mov rdx, MD_MINCORE_CHUNK
    cmp rax, rdx
    jae .chunk
    mov rdx, rax
.chunk:
    mov r10, rdx
    shr r10, 12
    push rax
    push r14
    mov rax, 27
    mov rdi, r14
    mov rsi, rdx
    lea rdx, [md_minvec]
    syscall
    mov r11, rax
    pop r14
    pop rax
    test r11, r11
    js .err
    push rax
    lea rbx, [md_minvec]
    xor ecx, ecx
.cnt:
    cmp rcx, r10
    jae .cntdone
    movzx edi, byte [rbx + rcx]
    test dil, 1
    jz .cnext
    inc r15
.cnext:
    inc rcx
    jmp .cnt
.cntdone:
    pop rax
    mov rdx, MD_MINCORE_CHUNK
    cmp rax, rdx
    jae .advfull
    mov rdx, rax
.advfull:
    add r14, rdx
    sub rax, rdx
    jmp .pageloop
.nextreg:
    inc r12
    cmp r12, r13
    jb .regloop
.done:
    mov rax, r15
    shl rax, 12
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret
.err:
    mov rax, -1
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; md_save: rsi=NUL-term target path -> rax=0 ok / -1 fail.
md_save:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov r15, rsi
    lea rdi, [md_tmpname]
    mov rbx, rdi
    xor ecx, ecx
.cp:
    mov al, [r15 + rcx]
    mov [rbx + rcx], al
    test al, al
    jz .cpdone
    inc rcx
    cmp rcx, 200
    jae .fail
    jmp .cp
.cpdone:
    lea rbx, [rbx + rcx]
    mov dword [rbx], '.tmp'
    add rbx, 4
    mov rax, 39
    syscall
    mov r13, rax
    lea r12, [md_numbuf + 31]
    mov byte [r12], 0
    mov rax, r13
    mov r14d, 10
.pidloop:
    xor edx, edx
    div r14
    add dl, '0'
    dec r12
    mov [r12], dl
    test rax, rax
    jne .pidloop
.pcp:
    mov al, [r12]
    test al, al
    jz .pcpdone
    mov [rbx], al
    inc rbx
    inc r12
    jmp .pcp
.pcpdone:
    mov byte [rbx], 0
    xor r12d, r12d
    mov r13, [md_nreg]
    test r13, r13
    jz .pass1done
.pass1:
    mov rax, r12
    shl rax, 5
    lea rbx, [md_regtab]
    add rbx, rax
    mov rsi, [rbx + 8]
    add rsi, [md_arenabase]
    mov rdx, [rbx + 16]
    call md_fnv64
    lea rdx, [md_crcbuf]
    mov [rdx + r12*8], rax
    inc r12
    cmp r12, r13
    jb .pass1
.pass1done:
    mov rax, MD_FNV_OFF
    mov [md_payloadhash], rax
    xor r12d, r12d
    test r13, r13
    jz .pass1bdone
.pass1b:
    mov rax, r12
    shl rax, 5
    lea rbx, [md_regtab]
    add rbx, rax
    mov rsi, [rbx + 8]
    add rsi, [md_arenabase]
    mov rdx, [rbx + 16]
    mov rax, [md_payloadhash]
    test rdx, rdx
    jz .bnext
.bloop:
    movzx ecx, byte [rsi]
    xor rax, rcx
    mov rcx, MD_FNV_PRM
    imul rax, rcx
    inc rsi
    dec rdx
    jne .bloop
.bnext:
    mov [md_payloadhash], rax
    inc r12
    cmp r12, r13
    jb .pass1b
.pass1bdone:
    xor r12d, r12d
    test r13, r13
    jz .tabbuilt
.tabbuild:
    mov rax, r12
    shl rax, 5
    lea rsi, [md_regtab]
    add rsi, rax
    lea rdi, [md_tabbuf]
    add rdi, rax
    mov rdx, [rsi]
    mov [rdi], rdx
    mov rdx, [rsi + 8]
    mov [rdi + 8], rdx
    mov rdx, [rsi + 16]
    mov [rdi + 16], rdx
    lea rbx, [md_crcbuf]
    mov rdx, [rbx + r12*8]
    mov [rdi + 24], rdx
    inc r12
    cmp r12, r13
    jb .tabbuild
.tabbuilt:
    mov rax, r13
    shl rax, 5
    lea rsi, [md_tabbuf]
    mov rdx, rax
    call md_fnv64
    mov [md_tablehash], rax
    mov rax, 257
    mov rdi, MD_AT_FDCWD
    lea rsi, [md_tmpname]
    mov edx, MD_O_RDWR + MD_O_CREAT + MD_O_EXCL
    mov r10d, 384
    syscall
    cmp rax, -4095
    jae .fail
    mov r14, rax
    mov dword [md_hdrbuf], MD_PBMD_MAGIC
    mov dword [md_hdrbuf + 4], MD_PBMD_VER
    mov dword [md_hdrbuf + 8], MD_PBMD_ARCH
    mov dword [md_hdrbuf + 12], 0
    mov eax, dword [md_nreg]
    mov dword [md_hdrbuf + 16], eax
    mov eax, dword [md_hcur]
    mov dword [md_hdrbuf + 20], eax
    mov rax, [md_step]
    mov qword [md_hdrbuf + 24], rax
    xor ebx, ebx
    xor r12d, r12d
    test r13, r13
    jz .sumdone
.sum:
    mov rax, r12
    shl rax, 5
    lea rdx, [md_regtab]
    add rbx, qword [rdx + rax + 16]
    inc r12
    cmp r12, r13
    jb .sum
.sumdone:
    mov qword [md_hdrbuf + 32], rbx
    mov rax, [md_tablehash]
    mov qword [md_hdrbuf + 40], rax
    mov rax, [md_payloadhash]
    mov qword [md_hdrbuf + 48], rax
    mov eax, dword [md_actf]
    mov dword [md_hdrbuf + 56], eax
    mov dword [md_hdrbuf + 60], 0
    mov rdi, r14
    lea rsi, [md_hdrbuf]
    mov edx, 64
    call md_write_all
    test rax, rax
    jnz .failclose
    ; NOTE: r10 holds the openat mode across the syscall above, so the
    ; table length is recomputed here from r13 (syscalls/clobbers safe).
    mov rax, r13
    shl rax, 5
    test rax, rax
    jz .nopayloadtab
    mov rdi, r14
    lea rsi, [md_tabbuf]
    mov rdx, rax
    call md_write_all
    test rax, rax
    jnz .failclose
.nopayloadtab:
    xor r12d, r12d
    test r13, r13
    jz .paydone
.pay:
    mov rax, r12
    shl rax, 5
    lea rbx, [md_regtab]
    add rbx, rax
    mov rdi, r14
    mov rsi, [rbx + 8]
    add rsi, [md_arenabase]
    mov rdx, [rbx + 16]
    call md_write_all
    test rax, rax
    jnz .failclose
    inc r12
    cmp r12, r13
    jb .pay
.paydone:
    mov rax, 74
    mov rdi, r14
    syscall
    test rax, rax
    js .failclose
    mov rdi, r14
    call md_close_fd
    mov rax, 264
    mov rdi, MD_AT_FDCWD
    lea rsi, [md_tmpname]
    mov rdx, MD_AT_FDCWD
    mov r10, r15
    syscall
    test rax, rax
    js .failunlink
    ; dirsync the tmp's directory (derived: truncate tmpname after last '/';
    ; no slash -> "."). rename already done so tmpname is reusable scratch.
    lea rsi, [md_tmpname]
.findend:
    cmp byte [rsi], 0
    je .foundend
    inc rsi
    jmp .findend
.foundend:
    lea rdx, [md_tmpname]
.scanback:
    cmp rsi, rdx
    je .nodir
    dec rsi
    cmp byte [rsi], '/'
    jne .scanback
    mov byte [rsi + 1], 0
    lea rsi, [md_tmpname]
    jmp .opend
.nodir:
    lea rsi, [md_dot]
.opend:
    mov rax, 257
    mov rdi, MD_AT_FDCWD
    mov edx, MD_O_RDONLY + MD_O_DIRECTORY
    xor r10d, r10d
    syscall
    cmp rax, -4095
    jae .oknodir
    mov rdi, rax
    mov rbx, rax
    mov rax, 74
    syscall
    mov rdi, rbx
    call md_close_fd
.oknodir:
    xor eax, eax
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret
.failclose:
    mov rdi, r14
    call md_close_fd
.failunlink:
    mov rax, 263
    mov rdi, MD_AT_FDCWD
    lea rsi, [md_tmpname]
    xor edx, edx
    syscall
.fail:
    mov rax, -1
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; md_load: rsi=NUL-term path -> rax=0 ok / -1 fail (current model preserved).
md_load:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov r15, rsi
    mov rax, 257
    mov rdi, MD_AT_FDCWD
    mov edx, MD_O_RDONLY
    xor r10d, r10d
    syscall
    cmp rax, -4095
    jae .fail
    mov r14, rax
    mov rax, 5
    mov rdi, r14
    lea rsi, [md_statbuf]
    syscall
    test rax, rax
    js .failclose
    mov r13, qword [md_statbuf + 48]
    mov rdi, r14
    lea rsi, [md_hdrbuf]
    mov edx, 64
    call md_read_all
    test rax, rax
    jnz .failclose
    cmp dword [md_hdrbuf], MD_PBMD_MAGIC
    jne .failclose
    cmp dword [md_hdrbuf + 8], MD_PBMD_ARCH
    jne .failclose
    mov eax, dword [md_hdrbuf + 4]
    cmp eax, 1
    je .v1
    cmp eax, MD_PBMD_VER
    jne .failclose
    mov eax, dword [md_hdrbuf + 20]   ; H
    cmp eax, 1
    jb .failclose
    cmp eax, 16
    ja .failclose
    mov [md_ldh], eax
    mov eax, dword [md_hdrbuf + 56]
    cmp eax, 1
    ja .failclose
    mov [md_ldact], eax
    jmp .vok
.v1:
    mov dword [md_ldh], 16
    mov dword [md_ldact], 1
.vok:
    mov r12d, dword [md_hdrbuf + 16]
    cmp r12d, MD_MAXREG
    ja .failclose
    mov rax, r12
    shl rax, 5
    add rax, 64
    add rax, qword [md_hdrbuf + 32]
    cmp rax, r13
    jne .failclose
    mov rax, r12
    shl rax, 5
    test rax, rax
    jz .tabok
    mov rdi, r14
    lea rsi, [md_tabbuf]
    mov rdx, rax
    call md_read_all
    test rax, rax
    jnz .failclose
.tabok:
    mov rax, r12
    shl rax, 5
    lea rsi, [md_tabbuf]
    mov rdx, rax
    call md_fnv64
    cmp rax, qword [md_hdrbuf + 40]
    jne .failclose
    mov rax, [md_acur]
    mov [md_savemark], rax
    mov rax, [md_nreg]
    mov [md_savenreg], rax
    xor ebx, ebx
    test r12d, r12d
    jz .allstaged
.stage:
    mov rax, rbx
    shl rax, 5
    lea r10, [md_tabbuf]
    add r10, rax
    mov rdi, [r10 + 16]
    mov rsi, MD_PAGE
    mov rdx, [r10]
    push r10
    push rbx
    call md_arena_alloc
    pop rbx
    pop r10
    test rax, rax
    jz .rollback
    mov rdi, r14
    mov rsi, rax
    mov rdx, [r10 + 16]
    push rax
    push r10
    push rbx
    call md_read_all
    pop rbx
    pop r10
    pop r11
    test rax, rax
    jnz .rollback
    mov rsi, r11
    mov rdx, [r10 + 16]
    push r10
    push rbx
    call md_fnv64
    pop rbx
    pop r10
    cmp rax, qword [r10 + 24]
    jne .rollback
    inc rbx
    cmp ebx, r12d
    jb .stage
.allstaged:
    mov rax, MD_FNV_OFF
    mov [md_tmpcrc], rax
    mov rax, [md_savenreg]
    mov r11, [md_nreg]
.stcrc:
    cmp rax, r11
    jae .stcrcdone
    push rax
    mov rdx, rax
    shl rdx, 5
    lea r10, [md_regtab]
    add r10, rdx
    mov rsi, [r10 + 8]
    add rsi, [md_arenabase]
    mov rdx, [r10 + 16]
    mov rax, [md_tmpcrc]
    test rdx, rdx
    jz .stnext
.stloop:
    movzx ecx, byte [rsi]
    xor rax, rcx
    mov rcx, MD_FNV_PRM
    imul rax, rcx
    inc rsi
    dec rdx
    jne .stloop
.stnext:
    mov [md_tmpcrc], rax
    pop rax
    inc rax
    jmp .stcrc
.stcrcdone:
    mov rax, [md_tmpcrc]
    cmp rax, qword [md_hdrbuf + 48]
    jne .rollbackfull
    mov rax, qword [md_hdrbuf + 24]
    mov [md_step], rax
    mov eax, [md_ldh]
    mov [md_hcur], eax
    mov eax, [md_ldact]
    mov [md_actf], eax
    mov rdi, r14
    call md_close_fd
    xor eax, eax
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret
.rollback:
    jmp .rollbackfull
.rollbackfull:
    mov rax, [md_savemark]
    mov [md_acur], rax
    mov rax, [md_savenreg]
    mov [md_nreg], rax
    mov rdi, r14
    call md_close_fd
.failclose:
    mov rdi, r14
    call md_close_fd
.fail:
    mov rax, -1
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ================= C. math: matmul + MLP (H<=16, batch<=128) =================
; matmul_avx2: rdi=A rsi=B rdx=C rcx=M r8=K r9=N (row-major FP32).
; Scalar build (USE_SCALAR) uses matmul_ref instead (selected at call sites).
matmul_avx2:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov r15, rdx
    mov r14, rsi
    mov [md_bsave], rsi
    mov r13, rcx
    mov r12, r8
    mov rax, r12
    shl rax, 2
    mov [md_astride], rax
    mov rax, r9
    shl rax, 2
    mov [md_bstride], rax
    mov [md_cstride], rax
    xor ebx, ebx
.i:
    cmp rbx, r13
    jae .done
    mov rax, rbx
    imul rax, [md_astride]
    lea r10, [rdi + rax]
    mov rax, rbx
    imul rax, [md_cstride]
    lea r11, [r15 + rax]
    xor r14d, r14d
.jtile:
    lea rax, [r14 + 8]
    cmp rax, r9
    ja .tail
    vxorps ymm2, ymm2, ymm2
    mov rax, r14
    shl rax, 2
    lea rcx, [rsi + rax]
    mov rax, r10
    push r11
    push r10
    xor r10d, r10d
.k:
    cmp r10, r12
    jae .kdone
    vbroadcastss ymm0, dword [rax]
    vmovups ymm1, [rcx]
    vfmadd231ps ymm2, ymm0, ymm1
    add rax, 4
    add rcx, [md_bstride]
    inc r10
    jmp .k
.kdone:
    pop r10
    pop r11
    lea rax, [r14*4]
    vmovups [r11 + rax], ymm2
    add r14, 8
    jmp .jtile
.tail:
    cmp r14, r9
    jae .inext
    mov rax, r10
    mov rcx, [md_bsave]
    lea rcx, [rcx + r14*4]
    xorps xmm2, xmm2
    push r11
    push r10
    xor r10d, r10d
.sk:
    cmp r10, r12
    jae .skdone
    movss xmm0, [rax]
    movss xmm1, [rcx]
    mulss xmm0, xmm1
    addss xmm2, xmm0
    add rax, 4
    add rcx, [md_bstride]
    inc r10
    jmp .sk
.skdone:
    pop r10
    pop r11
    lea rax, [r14*4]
    movss [r11 + rax], xmm2
    inc r14
    jmp .tail
.inext:
    mov rsi, [md_bsave]
    inc rbx
    jmp .i
.done:
if defined USE_SCALAR
else
    vzeroupper
end if
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; matmul_ref: same args, pure scalar (reference + USE_SCALAR backend).
matmul_ref:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov r15, rdx
    mov r14, rsi
    mov [md_bsave], rsi
    mov r13, rcx
    mov r12, r8
    mov rax, r12
    shl rax, 2
    mov [md_astride], rax
    mov rax, r9
    shl rax, 2
    mov [md_bstride], rax
    mov [md_cstride], rax
    xor ebx, ebx
.i:
    cmp rbx, r13
    jae .done
    mov rax, rbx
    imul rax, [md_astride]
    lea r10, [rdi + rax]
    mov rax, rbx
    imul rax, [md_cstride]
    lea r11, [r15 + rax]
    xor r14d, r14d
    mov [md_bsave], rsi
.j:
    cmp r14, r9
    jae .inext
    mov rax, r10
    mov rcx, [md_bsave]
    lea rcx, [rcx + r14*4]
    xorps xmm2, xmm2
    push r11
    push r10
    xor r10d, r10d
.k:
    cmp r10, r12
    jae .kdone
    movss xmm0, [rax]
    movss xmm1, [rcx]
    mulss xmm0, xmm1
    addss xmm2, xmm0
    add rax, 4
    add rcx, [md_bstride]
    inc r10
    jmp .k
.kdone:
    pop r10
    pop r11
    lea rax, [r14*4]
    movss [r11 + rax], xmm2
    inc r14
    jmp .j
.inext:
    mov rsi, [md_bsave]
    inc rbx
    jmp .i
.done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

if defined USE_SCALAR
md_gemm equ matmul_ref
else
md_gemm equ matmul_avx2
end if

; md_fwd: rdi=X(Nx2) rsi=T(N) rdx=N. Uses [md_hcur],[md_actf].
; Caches Z1/A1/Y. xmm0=loss, [md_lastloss]=loss. preserves rbx,r12-r15.
md_fwd:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov rbx, rdi
    mov r15, rsi
    mov r12, rdx
    mov r13d, [md_hcur]
    mov rdi, rbx
    mov rsi, [md_pw1]
    lea rdx, [md_Z1]
    mov rcx, r12
    mov r8d, 2
    mov r9, r13
    call md_gemm
    lea rsi, [md_Z1]
    lea rdi, [md_A1]
    mov rax, r12
    imul rax, r13
    mov rdx, [md_pb1]
    mov r10d, r13d
    mov ecx, [md_actf]
.loop1:
    test rax, rax
    jz .l1done
    movss xmm0, [rsi]
    addss xmm0, [rdx]
    cmp ecx, 1
    jne .lin1
    xorps xmm1, xmm1
    ucomiss xmm0, xmm1
    jae .lin1
    mulss xmm0, [md_leak]
.lin1:
    movss [rdi], xmm0
    add rsi, 4
    add rdi, 4
    add rdx, 4
    dec r10d
    jnz .noreset
    mov rdx, [md_pb1]
    mov r10d, r13d
.noreset:
    dec rax
    jmp .loop1
.l1done:
    lea rdi, [md_A1]
    mov rsi, [md_pw2]
    lea rdx, [md_Y]
    mov rcx, r12
    mov r8, r13
    mov r9d, 1
    call md_gemm
    lea rsi, [md_Y]
    mov rdi, r15
    xorps xmm0, xmm0
    mov rax, r12
    mov rdx, [md_pb2]
    movss xmm2, [rdx]
.loss:
    test rax, rax
    jz .ldone
    movss xmm1, [rsi]
    addss xmm1, xmm2
    movss [rsi], xmm1
    subss xmm1, [rdi]
    mulss xmm1, xmm1
    addss xmm0, xmm1
    add rsi, 4
    add rdi, 4
    dec rax
    jne .loss
.ldone:
    cvtsi2ss xmm1, r12d
    divss xmm0, xmm1
    movss [md_lastloss], xmm0
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; md_backward: rdi=X rsi=T rdx=N. Full-batch grads. preserves rbx,r12-r15.
md_backward:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov rbx, rdi
    mov r15, rsi
    mov r12, rdx
    mov r13d, [md_hcur]
    mov rax, r13
    shl rax, 1
    lea rdi, [md_GW1]
    mov rsi, rax
    call md_zero_f
    lea rdi, [md_Gb1]
    mov rsi, r13
    call md_zero_f
    lea rdi, [md_GW2]
    mov rsi, r13
    call md_zero_f
    mov dword [md_Gb2], 0
    cvtsi2ss xmm7, r12d
    movss xmm6, [md_f2]
    divss xmm6, xmm7
    xor r14d, r14d
    mov ecx, [md_actf]
.sloop:
    cmp r14, r12
    jae .sdone
    lea rax, [md_Y]
    movss xmm0, [rax + r14*4]
    movss xmm1, [r15 + r14*4]
    subss xmm0, xmm1
    mulss xmm0, xmm6
    movss xmm1, [md_Gb2]
    addss xmm1, xmm0
    movss [md_Gb2], xmm1
    mov rax, r14
    imul rax, r13
    lea rdx, [md_A1]
    lea rdx, [rdx + rax*4]
    lea rdi, [md_GW2]
    xor r10d, r10d
.hw2:
    cmp r10, r13
    jae .hw2done
    movss xmm1, [rdx + r10*4]
    mulss xmm1, xmm0
    movss xmm2, [rdi + r10*4]
    addss xmm2, xmm1
    movss [rdi + r10*4], xmm2
    inc r10
    jmp .hw2
.hw2done:
    mov rsi, [md_pw2]
    mov rax, r14
    imul rax, r13
    lea rdx, [md_Z1]
    lea rax, [rdx + rax*4]
    mov rdi, [md_pw1]
    lea r8, [md_GW1]
    lea r9, [md_Gb1]
    mov r10, rbx
    imul r11, r14, 2
    lea r10, [r10 + r11*4]
    xor r11d, r11d
.hloop:
    cmp r11, r13
    jae .hdone
    movss xmm1, [rsi + r11*4]
    mulss xmm1, xmm0
    cmp ecx, 1
    jne .dzkeep
    xorps xmm2, xmm2
    mov rdx, [md_pb1]
    movss xmm3, [rax + r11*4]
    addss xmm3, [rdx + r11*4]
    ucomiss xmm3, xmm2
    ja .dzkeep
    mulss xmm1, [md_leak]
.dzkeep:
    movss xmm2, [r9 + r11*4]
    addss xmm2, xmm1
    movss [r9 + r11*4], xmm2
    movss xmm2, [r10]
    mulss xmm2, xmm1
    movss xmm3, [r8 + r11*4]
    addss xmm3, xmm2
    movss [r8 + r11*4], xmm3
    movss xmm2, [r10 + 4]
    mulss xmm2, xmm1
    mov rdx, r8
    mov rcx, r13
    lea rdx, [rdx + rcx*4]
    movss xmm3, [rdx + r11*4]
    addss xmm3, xmm2
    movss [rdx + r11*4], xmm3
    mov ecx, [md_actf]
    mov rsi, [md_pw2]
    mov rax, r14
    imul rax, r13
    lea rdx, [md_Z1]
    lea rax, [rdx + rax*4]
    inc r11
    jmp .hloop
.hdone:
    inc r14
    jmp .sloop
.sdone:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; md_zero_f: rdi=ptr, rsi=count(floats).
md_zero_f:
    xor eax, eax
.z:
    mov [rdi], eax
    add rdi, 4
    dec rsi
    jne .z
    ret

; md_sgd: momentum update over all params (H=[md_hcur]). preserves rbx,r12-r13.
md_sgd:
    push rbx
    push r12
    push r13
    mov r13d, [md_hcur]
    movss xmm6, [md_mu0]
    movss xmm7, [md_lr]
    mov rsi, [md_pw1]
    mov rdi, [md_pv1]
    lea rdx, [md_GW1]
    mov rax, r13
    shl rax, 1
    call .upd
    mov rsi, [md_pb1]
    mov rdi, [md_pvb1]
    lea rdx, [md_Gb1]
    mov rax, r13
    call .upd
    mov rsi, [md_pw2]
    mov rdi, [md_pv2]
    lea rdx, [md_GW2]
    mov rax, r13
    call .upd
    mov rsi, [md_pb2]
    mov rdi, [md_pvb2]
    lea rdx, [md_Gb2]
    mov eax, 1
    call .upd
    pop r13
    pop r12
    pop rbx
    ret
.upd:
    test rax, rax
    jz .udone
    xor ecx, ecx
.uloop:
    movss xmm0, [rdi + rcx*4]
    mulss xmm0, xmm6
    movss xmm1, [rdx + rcx*4]
    mulss xmm1, xmm7
    subss xmm0, xmm1
    movss [rdi + rcx*4], xmm0
    movss xmm2, [rsi + rcx*4]
    addss xmm2, xmm0
    movss [rsi + rcx*4], xmm2
    inc rcx
    dec rax
    jne .uloop
.udone:
    ret

; md_init_w: rdi=ptr rsi=count rdx=seed. Uniform(-1,1)*[md_initsc]. preserves rbx.
md_init_w:
    push rbx
    mov rbx, rdx
    movss xmm2, [md_initsc]
.loop:
    mov rax, rbx
    mov rcx, 6364136223846793005
    imul rax, rcx
    mov rcx, 1442695040888963407
    add rax, rcx
    mov rbx, rax
    shr rax, 41
    cvtsi2ss xmm0, eax
    movss xmm1, [md_f8388608]
    divss xmm0, xmm1
    subss xmm0, [md_f1]
    mulss xmm0, xmm2
    movss [rdi], xmm0
    add rdi, 4
    dec rsi
    jne .loop
    pop rbx
    ret

; md_fetch_addrs: regtab[.off]+arenabase -> md_pw1..pvb2. leaf.
md_fetch_addrs:
    mov rax, qword [md_regtab + 8]
    add rax, [md_arenabase]
    mov [md_pw1], rax
    mov rax, qword [md_regtab + 32 + 8]
    add rax, [md_arenabase]
    mov [md_pb1], rax
    mov rax, qword [md_regtab + 64 + 8]
    add rax, [md_arenabase]
    mov [md_pw2], rax
    mov rax, qword [md_regtab + 96 + 8]
    add rax, [md_arenabase]
    mov [md_pb2], rax
    mov rax, qword [md_regtab + 128 + 8]
    add rax, [md_arenabase]
    mov [md_pv1], rax
    mov rax, qword [md_regtab + 160 + 8]
    add rax, [md_arenabase]
    mov [md_pvb1], rax
    mov rax, qword [md_regtab + 192 + 8]
    add rax, [md_arenabase]
    mov [md_pv2], rax
    mov rax, qword [md_regtab + 224 + 8]
    add rax, [md_arenabase]
    mov [md_pvb2], rax
    ret

; md_alloc_regions -> rax=0 ok / -1 fail. 8 fixed max-size regions + zero vels.
md_alloc_regions:
    push rbx
    mov rdi, 128
    mov rsi, 64
    mov rdx, 'W1  '
    call md_arena_alloc
    test rax, rax
    jz .fail
    mov rdi, 64
    mov rsi, 64
    mov rdx, 'b1  '
    call md_arena_alloc
    test rax, rax
    jz .fail
    mov rdi, 64
    mov rsi, 64
    mov rdx, 'W2  '
    call md_arena_alloc
    test rax, rax
    jz .fail
    mov rdi, 4
    mov rsi, 64
    mov rdx, 'b2  '
    call md_arena_alloc
    test rax, rax
    jz .fail
    mov rdi, 128
    mov rsi, 64
    mov rdx, 'VW1 '
    call md_arena_alloc
    test rax, rax
    jz .fail
    mov rdi, 64
    mov rsi, 64
    mov rdx, 'Vb1 '
    call md_arena_alloc
    test rax, rax
    jz .fail
    mov rdi, 64
    mov rsi, 64
    mov rdx, 'VW2 '
    call md_arena_alloc
    test rax, rax
    jz .fail
    mov rdi, 4
    mov rsi, 64
    mov rdx, 'Vb2 '
    call md_arena_alloc
    test rax, rax
    jz .fail
    cmp qword [md_nreg], 8
    jne .fail
    call md_fetch_addrs
    mov rdi, [md_pv1]
    mov rsi, 32
    call md_zero_f
    mov rdi, [md_pvb1]
    mov rsi, 16
    call md_zero_f
    mov rdi, [md_pv2]
    mov rsi, 16
    call md_zero_f
    mov rdi, [md_pvb2]
    mov rsi, 1
    call md_zero_f
    pop rbx
    xor eax, eax
    ret
.fail:
    pop rbx
    mov rax, -1
    ret

; ================= D. model ops engine + MCP handlers =================
; md_opt_f64arg: rsi=argsptr rdi=key rcx=keylen, xmm1=default
; -> xmm0=value (or default if missing), rax=0 ok / 1 bad.
md_opt_f64arg:
    push rbx
    push r12
    push r13
    movss [md_tmpf], xmm1
    call find_val
    test rax, rax
    jz .usedef
    mov rsi, rax
    mov rdx, [le]
    call md_parse_f32
    test rax, rax
    jnz .bad
    movss [md_tmpf], xmm0
    mov rdx, [le]
    call md_skip_ws
    cmp rsi, rdx
    jae .bad
    mov al, [rsi]
    cmp al, ','
    je .ok
    cmp al, '}'
    jne .bad
.ok:
    movss xmm0, [md_tmpf]
    xor eax, eax
    pop r13
    pop r12
    pop rbx
    ret
.usedef:
    movss xmm0, [md_tmpf]
    xor eax, eax
    pop r13
    pop r12
    pop rbx
    ret
.bad:
    mov eax, 1
    pop r13
    pop r12
    pop rbx
    ret

; md_valid_path: rsi=ptr rdx=len -> rax=0 ok / 1 bad.
; [A-Za-z0-9._/-]{1,256}, no ".." anywhere (blocks traversal).
md_valid_path:
    cmp rdx, 1
    jb .bad
    cmp rdx, 256
    ja .bad
    push rbx
    push r12
    mov rbx, rsi
    lea r12, [rsi + rdx]
    xor ecx, ecx
.loop:
    cmp rbx, r12
    jae .ok
    mov al, [rbx]
    cmp al, 'A'
    jb .sym
    cmp al, 'Z'
    jbe .next
    cmp al, 'a'
    jb .sym
    cmp al, 'z'
    jbe .next
    jmp .bad
.sym:
    cmp al, '0'
    jb .punct
    cmp al, '9'
    jbe .next
    jmp .bad
.punct:
    cmp al, '.'
    je .dot
    cmp al, '_'
    je .next
    cmp al, '/'
    je .next
    cmp al, '-'
    jne .bad
    jmp .next
.dot:
    test ecx, ecx
    jnz .bad
    mov ecx, 1
    jmp .adv
.next:
    xor ecx, ecx
.adv:
    inc rbx
    jmp .loop
.ok:
    xor eax, eax
    pop r12
    pop rbx
    ret
.bad:
    mov eax, 1
    pop r12
    pop rbx
    ret

; md_resolve_path: optional k_path in [ap] -> rsi=NUL-term path in md_pathbuf.
; Missing -> default. rax=0 ok / 1 bad. (rsi=path on success.)
md_resolve_path:
    push rbx
    mov rsi, [ap]
    lea rdi, [k_path]
    mov ecx, 6
    call find_val
    test rax, rax
    jz .def
    mov rsi, rax
    lea rdi, [md_pathbuf]
    mov ecx, 256
    call parse_str
    test rax, rax
    jz .bad
    test rdx, rdx
    jz .bad
    lea rax, [md_pathbuf]
    mov byte [rax + rdx], 0
    lea rsi, [md_pathbuf]
    call md_valid_path
    test rax, rax
    jnz .bad
    lea rsi, [md_pathbuf]
    pop rbx
    xor eax, eax
    ret
.def:
    lea rsi, [md_defpath]
    pop rbx
    xor eax, eax
    ret
.bad:
    pop rbx
    mov eax, 1
    ret

; md_model_init: rcx=H(1..16) rdx=seed r8d=act(0/1) -> rax=0 ok / -1 mem-fail.
md_model_init:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov r12, rcx
    mov r13, rdx
    mov r14d, r8d
    call md_arena_init
    test rax, rax
    jnz .fail
    call md_arena_reset
    call md_alloc_regions
    test rax, rax
    jnz .fail
    mov rax, r12
    mov [md_hcur], eax
    mov [md_actf], r14d
    mov qword [md_step], 0
    mov dword [md_hasloss], 0
    movss xmm0, [md_f1]
    movss [md_initsc], xmm0
    mov rdi, [md_pw1]
    mov rsi, 32
    mov rdx, r13
    call md_init_w
    mov eax, 16
    mov rdi, [md_pb1]
.bi:
    mov dword [rdi], 0x3DCCCCCD
    add rdi, 4
    dec eax
    jne .bi
    mov rax, r12
    dec rax
    shl rax, 2
    lea rdx, [md_he_sc]
    movss xmm0, [rdx + rax]
    movss [md_initsc], xmm0
    mov rdi, [md_pw2]
    mov rsi, 16
    mov rdx, r13
    mov rax, 0x9E3779B9
    add rdx, rax
    call md_init_w
    mov rdi, [md_pb2]
    mov dword [rdi], 0
    mov qword [md_ready], 1
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    xor eax, eax
    ret
.fail:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    mov rax, -1
    ret

; op_modinit: {hidden?, seed?, activation?}
op_modinit:
    mov rsi, [pp]
    lea rdi, [k_args]
    mov ecx, 11
    call find_val
    test rax, rax
    jz dc_params
    mov [ap], rax
    mov rsi, [ap]
    lea rdi, [k_hidden]
    mov ecx, 8
    movss xmm1, [md_f16]
    call md_opt_f64arg
    test rax, rax
    jnz dc_params
    cvttss2si rax, xmm0
    cmp rax, 1
    jb dc_params
    cmp rax, 16
    ja dc_params
    mov [md_th], rax
    mov rsi, [ap]
    lea rdi, [k_seed]
    mov ecx, 6
    movss xmm1, [md_fseed0]
    call md_opt_f64arg
    test rax, rax
    jnz dc_params
    cvttss2si rax, xmm0
    mov [md_tseed], rax
    mov dword [md_tact], 1
    mov rsi, [ap]
    lea rdi, [k_activation]
    mov ecx, 12
    call find_val
    test rax, rax
    jz .doinit
    mov rsi, rax
    lea rdi, [md_actbuf]
    mov ecx, 16
    call parse_str
    test rax, rax
    jz dc_params
    test rdx, rdx
    jz dc_params
    mov [md_actlen], rdx
    lea rsi, [md_actbuf]
    mov rdx, [md_actlen]
    lea rdi, [md_v_leaky]
    call cmp_name
    test rax, rax
    jnz .isact
    lea rsi, [md_actbuf]
    mov rdx, [md_actlen]
    lea rdi, [md_v_linear]
    call cmp_name
    test rax, rax
    jnz .islin
    jmp dc_params
.isact:
    mov dword [md_tact], 1
    jmp .doinit
.islin:
    mov dword [md_tact], 0
.doinit:
    mov rcx, [md_th]
    mov rdx, [md_tseed]
    mov r8d, [md_tact]
    call md_model_init
    test rax, rax
    jnz .modmem
    lea rax, [jsontmp]
    mov [outptr], rax
    mov qword [outlen], 0
    lea rsi, [md_jn_init]
    call out_cstr
    mov rax, [md_th]
    call out_uint
    lea rsi, [md_jn_act]
    call out_cstr
    cmp dword [md_tact], 1
    je .leaky
    lea rsi, [md_v_linear]
    call out_cstr
    jmp .step
.leaky:
    lea rsi, [md_v_leaky]
    call out_cstr
.step:
    lea rsi, [md_jn_step0]
    call out_cstr
    jmp oc_envelope
.modmem:
    lea rdi, [c_params]
    lea rsi, [md_m_modmem]
    jmp err_id

; md_checkmag: rsi=floats rcx=count -> rax=0 all |v|<=1e6 else 1.
md_checkmag:
    push rbx
    lea rax, [md_absmask]
    movups xmm1, [rax]
    movss xmm2, [md_f1e6]
.cmploop:
    test rcx, rcx
    jz .ok
    movss xmm0, [rsi]
    andps xmm0, xmm1
    ucomiss xmm0, xmm2
    jae .bad
    add rsi, 4
    dec rcx
    jmp .cmploop
.ok:
    xor eax, eax
    pop rbx
    ret
.bad:
    mov eax, 1
    pop rbx
    ret

; op_modtrain: {xs[], ys[], targets[], lr?, steps?} full-batch SGD.
op_modtrain:
    cmp qword [md_ready], 1
    jne .nomodel
    mov rsi, [pp]
    lea rdi, [k_args]
    mov ecx, 11
    call find_val
    test rax, rax
    jz dc_params
    mov [ap], rax
    mov rsi, [ap]
    lea rdi, [k_xs]
    mov ecx, 4
    call find_val
    test rax, rax
    jz dc_params
    mov rsi, rax
    mov rdx, [le]
    lea rdi, [md_tmpA]
    mov rcx, 128
    call md_parse_farray
    test rax, rax
    jnz dc_params
    mov [md_tn], rdx
    mov rsi, [ap]
    lea rdi, [k_ys]
    mov ecx, 4
    call find_val
    test rax, rax
    jz dc_params
    mov rsi, rax
    mov rdx, [le]
    lea rdi, [md_tmpB]
    mov rcx, 128
    call md_parse_farray
    test rax, rax
    jnz dc_params
    cmp rdx, [md_tn]
    jne dc_params
    mov rsi, [ap]
    lea rdi, [k_targets]
    mov ecx, 9
    call find_val
    test rax, rax
    jz dc_params
    mov rsi, rax
    mov rdx, [le]
    lea rdi, [md_Tbuf]
    mov rcx, 128
    call md_parse_farray
    test rax, rax
    jnz dc_params
    cmp rdx, [md_tn]
    jne dc_params
    test rdx, rdx
    jz dc_params
    mov rcx, [md_tn]
    lea rsi, [md_tmpA]
    call md_checkmag
    test rax, rax
    jnz dc_params
    mov rcx, [md_tn]
    lea rsi, [md_tmpB]
    call md_checkmag
    test rax, rax
    jnz dc_params
    mov rcx, [md_tn]
    lea rsi, [md_Tbuf]
    call md_checkmag
    test rax, rax
    jnz dc_params
    mov rcx, [md_tn]
    lea rsi, [md_tmpA]
    lea rdi, [md_tmpB]
    lea rdx, [md_Xbuf]
.il:
    test rcx, rcx
    jz .ildone
    mov eax, [rsi]
    mov [rdx], eax
    mov eax, [rdi]
    mov [rdx + 4], eax
    add rsi, 4
    add rdi, 4
    add rdx, 8
    dec rcx
    jne .il
.ildone:
    mov rsi, [ap]
    lea rdi, [k_lr]
    mov ecx, 4
    movss xmm1, [md_f01]
    call md_opt_f64arg
    test rax, rax
    jnz dc_params
    xorps xmm1, xmm1
    ucomiss xmm0, xmm1
    jbe dc_params
    movss xmm1, [md_f1]
    ucomiss xmm0, xmm1
    ja dc_params
    movss [md_lr], xmm0
    mov rsi, [ap]
    lea rdi, [k_steps]
    mov ecx, 7
    movss xmm1, [md_f1]
    call md_opt_f64arg
    test rax, rax
    jnz dc_params
    cvttss2si rax, xmm0
    cmp rax, 1
    jb dc_params
    cmp rax, 10000
    ja dc_params
    mov [md_tsteps], rax
.trloop:
    cmp qword [md_tsteps], 0
    je .trdone
    lea rdi, [md_Xbuf]
    lea rsi, [md_Tbuf]
    mov rdx, [md_tn]
    call md_fwd
    lea rdi, [md_Xbuf]
    lea rsi, [md_Tbuf]
    mov rdx, [md_tn]
    call md_backward
    call md_sgd
    inc qword [md_step]
    dec qword [md_tsteps]
    jmp .trloop
.trdone:
    mov dword [md_hasloss], 1
    lea rax, [jsontmp]
    mov [outptr], rax
    mov qword [outlen], 0
    lea rsi, [md_jn_train]
    call out_cstr
    mov rax, [md_step]
    call out_uint
    lea rsi, [md_jn_loss]
    call out_cstr
    movss xmm0, [md_lastloss]
    call md_out_f32e6
    mov al, '}'
    call out_byte
    jmp oc_envelope
.nomodel:
    lea rdi, [c_params]
    lea rsi, [md_m_modnone]
    jmp err_id

; op_modpredict: {xs[], ys[]} -> {values:[...]}.
op_modpredict:
    cmp qword [md_ready], 1
    jne .nomodel
    mov rsi, [pp]
    lea rdi, [k_args]
    mov ecx, 11
    call find_val
    test rax, rax
    jz dc_params
    mov [ap], rax
    mov rsi, [ap]
    lea rdi, [k_xs]
    mov ecx, 4
    call find_val
    test rax, rax
    jz dc_params
    mov rsi, rax
    mov rdx, [le]
    lea rdi, [md_tmpA]
    mov rcx, 128
    call md_parse_farray
    test rax, rax
    jnz dc_params
    mov [md_tn], rdx
    mov rsi, [ap]
    lea rdi, [k_ys]
    mov ecx, 4
    call find_val
    test rax, rax
    jz dc_params
    mov rsi, rax
    mov rdx, [le]
    lea rdi, [md_tmpB]
    mov rcx, 128
    call md_parse_farray
    test rax, rax
    jnz dc_params
    cmp rdx, [md_tn]
    jne dc_params
    test rdx, rdx
    jz dc_params
    mov rcx, [md_tn]
    lea rsi, [md_tmpA]
    call md_checkmag
    test rax, rax
    jnz dc_params
    mov rcx, [md_tn]
    lea rsi, [md_tmpB]
    call md_checkmag
    test rax, rax
    jnz dc_params
    mov rcx, [md_tn]
    lea rsi, [md_tmpA]
    lea rdi, [md_tmpB]
    lea rdx, [md_Xbuf]
.pl:
    test rcx, rcx
    jz .pldone
    mov eax, [rsi]
    mov [rdx], eax
    mov eax, [rdi]
    mov [rdx + 4], eax
    add rsi, 4
    add rdi, 4
    add rdx, 8
    dec rcx
    jne .pl
.pldone:
    movss xmm0, [md_lastloss]
    movss [md_tmpf], xmm0
    lea rdi, [md_Xbuf]
    lea rsi, [md_Tbuf]
    mov rdx, [md_tn]
    call md_fwd
    movss xmm0, [md_tmpf]
    movss [md_lastloss], xmm0
    lea rax, [jsontmp]
    mov [outptr], rax
    mov qword [outlen], 0
    lea rsi, [md_jn_pred]
    call out_cstr
    mov r15, [md_tn]
    lea r14, [md_Y]
    test r15, r15
    jz .parrfin
.peloop:
    movss xmm0, [r14]
    call md_out_f32e6
    add r14, 4
    dec r15
    jz .parrfin
    mov al, ','
    call out_byte
    jmp .peloop
.parrfin:
    mov al, ']'
    call out_byte
    mov al, '}'
    call out_byte
    jmp oc_envelope
.nomodel:
    lea rdi, [c_params]
    lea rsi, [md_m_modnone]
    jmp err_id

; op_modsave: {path?} -> {ok,step}.
op_modsave:
    cmp qword [md_ready], 1
    jne .nomodel
    mov rsi, [pp]
    lea rdi, [k_args]
    mov ecx, 11
    call find_val
    test rax, rax
    jz dc_params
    mov [ap], rax
    call md_resolve_path
    test rax, rax
    jnz dc_params
    call md_save
    test rax, rax
    jnz .iofail
    lea rax, [jsontmp]
    mov [outptr], rax
    mov qword [outlen], 0
    lea rsi, [md_jn_save]
    call out_cstr
    mov rax, [md_step]
    call out_uint
    mov al, '}'
    call out_byte
    jmp oc_envelope
.iofail:
    lea rdi, [c_params]
    lea rsi, [md_m_modio]
    jmp err_id
.nomodel:
    lea rdi, [c_params]
    lea rsi, [md_m_modnone]
    jmp err_id

; op_modload: {path?} -> {ok,step,regions}. Bad files rejected, model kept.
op_modload:
    mov rsi, [pp]
    lea rdi, [k_args]
    mov ecx, 11
    call find_val
    test rax, rax
    jz dc_params
    mov [ap], rax
    call md_resolve_path
    test rax, rax
    jnz dc_params
    call md_arena_init
    test rax, rax
    jnz .modmem
    ; NOTE: md_arena_init runs the mmap syscall, which clobbers rsi.
    ; Re-resolve (pure: re-derives the same static path from [ap]).
    call md_resolve_path
    test rax, rax
    jnz .iofail
    call md_load
    test rax, rax
    jnz .iofail
    cmp qword [md_nreg], 8
    jne .iofail
    call md_fetch_addrs
    mov qword [md_ready], 1
    mov dword [md_hasloss], 0
    lea rax, [jsontmp]
    mov [outptr], rax
    mov qword [outlen], 0
    lea rsi, [md_jn_load]
    call out_cstr
    mov rax, [md_step]
    call out_uint
    lea rsi, [md_jn_regions]
    call out_cstr
    mov rax, [md_nreg]
    call out_uint
    mov al, '}'
    call out_byte
    jmp oc_envelope
.iofail:
    lea rdi, [c_params]
    lea rsi, [md_m_modio]
    jmp err_id
.modmem:
    lea rdi, [c_params]
    lea rsi, [md_m_modmem]
    jmp err_id

; op_modstatus -> full status object (works with no model loaded).
op_modstatus:
    mov rsi, [pp]
    lea rdi, [k_args]
    mov ecx, 11
    call find_val
    test rax, rax
    jz dc_params
    mov [ap], rax
    lea rax, [jsontmp]
    mov [outptr], rax
    mov qword [outlen], 0
    lea rsi, [md_jn_status]
    call out_cstr
    cmp qword [md_ready], 1
    je .ready
    lea rsi, [b_false]
    call out_cstr
    jmp .hid0
.ready:
    lea rsi, [b_true]
    call out_cstr
.hid0:
    lea rsi, [md_jn_hidden]
    call out_cstr
    mov eax, [md_hcur]
    call out_uint
    lea rsi, [md_jn_act2]
    call out_cstr
    cmp qword [md_ready], 1
    jne .noact
    cmp dword [md_actf], 1
    je .lky
    lea rsi, [md_v_linear]
    call out_cstr
    jmp .step
.lky:
    lea rsi, [md_v_leaky]
    call out_cstr
    jmp .step
.noact:
    lea rsi, [md_v_none]
    call out_cstr
.step:
    lea rsi, [md_jn_step]
    call out_cstr
    mov rax, [md_step]
    call out_uint
    lea rsi, [md_jn_lastloss]
    call out_cstr
    cmp dword [md_hasloss], 1
    jne .noloss
    movss xmm0, [md_lastloss]
    call md_out_f32e6
    jmp .alloc
.noloss:
    lea rsi, [jnull]
    call out_cstr
.alloc:
    lea rsi, [md_jn_alloc]
    call out_cstr
    mov rax, [md_acur]
    call out_uint
    lea rsi, [md_jn_commit]
    call out_cstr
    call md_committed
    cmp rax, 0
    jl .commit0
    call out_uint
    jmp .backend
.commit0:
    xor eax, eax
    call out_uint
.backend:
    lea rsi, [md_jn_backend]
    call out_cstr
if defined USE_SCALAR
    lea rsi, [md_v_ref]
else
    lea rsi, [md_v_avx]
end if
    call out_cstr
    lea rsi, [md_jn_gpu]
    call out_cstr
    mov al, '}'
    call out_byte
    jmp oc_envelope
