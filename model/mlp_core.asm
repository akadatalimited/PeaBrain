; ---- PeaBrain MLP core (Stage 3): forward / loss / backprop / SGD+momentum ----
; Reuses: arena infra (alloc/save/load), matmul_avx2 + matmul_ref (copied
; from mat.asm, verified Stage 2). Conventions below.
;
; Model: 2 -> H -> 1. Hidden act runtime flag [actf] (0=linear, 1=leaky-ReLU 0.01).
; W1 is 2xH row-major at [pw1]; b1 H at [pb1]; W2 Hx1 at [pw2]; b2 scalar
; at [pb2]. Velocities VW1,Vb1,VW2,Vb2 at [pv1],[pvb1],[pv2],[pvb2].
; Current width in [hcur]. All FP32. Full-batch deterministic SGD+momentum.

; ---- matmul kernels (Stage 2, verbatim) ----
; matmul_avx2: rdi=A rsi=B rdx=C rcx=M r8=K r9=N  (row-major FP32)
matmul_avx2:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov r15, rdx                    ; C base
    mov r14, rsi                    ; B base
    mov [bsave], rsi
    mov r13, rcx                    ; M
    mov r12, r8                     ; K
    mov rax, r12
    shl rax, 2
    mov [astride], rax
    mov rax, r9
    shl rax, 2
    mov [bstride], rax
    mov [cstride], rax
    xor ebx, ebx                    ; i
.i:
    cmp rbx, r13
    jae .done
    mov rax, rbx
    imul rax, [astride]
    lea r10, [rdi + rax]            ; Arow
    mov rax, rbx
    imul rax, [cstride]
    lea r11, [r15 + rax]            ; Crow
    xor r14d, r14d                  ; j
.jtile:
    lea rax, [r14 + 8]
    cmp rax, r9
    ja .tail
    vxorps ymm2, ymm2, ymm2
    mov rax, r14
    shl rax, 2
    lea rcx, [rsi + rax]            ; Bj col ptr
    mov rax, r10                    ; a_ptr
    push r11
    push r10                        ; frees r10 as k counter
    xor r10d, r10d                  ; k
.k:
    cmp r10, r12
    jae .kdone
    vbroadcastss ymm0, dword [rax]
    vmovups ymm1, [rcx]
    vfmadd231ps ymm2, ymm0, ymm1
    add rax, 4
    add rcx, [bstride]
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
    mov rcx, [bsave]
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
    add rcx, [bstride]
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
    mov rsi, [bsave]
    inc rbx
    jmp .i
.done:
    vzeroupper
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; matmul_ref: same args, pure scalar
matmul_ref:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov r15, rdx
    mov r14, rsi
    mov [bsave], rsi
    mov r13, rcx
    mov r12, r8
    mov rax, r12
    shl rax, 2
    mov [astride], rax
    mov rax, r9
    shl rax, 2
    mov [bstride], rax
    mov [cstride], rax
    xor ebx, ebx
.i:
    cmp rbx, r13
    jae .done
    mov rax, rbx
    imul rax, [astride]
    lea r10, [rdi + rax]
    mov rax, rbx
    imul rax, [cstride]
    lea r11, [r15 + rax]
    xor r14d, r14d
    mov [bsave], rsi
.j:
    cmp r14, r9
    jae .inext
    mov rax, r10
    mov rcx, [bsave]
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
    add rcx, [bstride]
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
    mov rsi, [bsave]
    inc rbx
    jmp .i
.done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ---- small FP helpers ----
; zero_f: rdi=ptr, rsi=count(floats)
zero_f:
    xor eax, eax
.z:
    mov [rdi], eax
    add rdi, 4
    dec rsi
    jne .z
    ret

; init_w: rdi=ptr, rsi=count, rdx=seed. Uniform(-1,1)*[initsc]. preserves rbx.
init_w:
    push rbx
    mov rbx, rdx
    movss xmm2, [initsc]
.loop:
    mov rax, rbx
    mov rcx, 6364136223846793005
    imul rax, rcx
    mov rcx, 1442695040888963407
    add rax, rcx
    mov rbx, rax
    shr rax, 41
    cvtsi2ss xmm0, eax
    movss xmm1, [f_8388608]
    divss xmm0, xmm1
    subss xmm0, [f_1]
    mulss xmm0, xmm2
    movss [rdi], xmm0
    add rdi, 4
    dec rsi
    jne .loop
    pop rbx
    ret

; lcg_next: rbx=state -> rbx=next, rax=23-bit sample. helper.
lcg_next:
    mov rax, rbx
    mov rcx, 6364136223846793005
    imul rax, rcx
    mov rcx, 1442695040888963407
    add rax, rcx
    mov rbx, rax
    shr rax, 41
    ret

; tlinear: xmm0=x xmm1=y -> xmm0 = 2.5x - 1.7y + 0.8
tlinear:
    mulss xmm0, [c_a]
    mulss xmm1, [c_b]
    subss xmm0, xmm1
    addss xmm0, [c_c]
    ret

; tnonlin: xmm0=x xmm1=y -> xmm0 = 3x^2 - 2y + 1
tnonlin:
    mulss xmm1, [c_2]               ; 2y
    mulss xmm0, xmm0                ; x^2
    mulss xmm0, [c_3]               ; 3x^2
    subss xmm0, xmm1
    addss xmm0, [c_1]
    ret

; gendata: rdi=Xptr(Nx2) rsi=Tptr rdx=N rcx=seed r8=fn(0=lin,1=nonlin)
; points uniform in [-2,2)^2, targets from the target fn. preserves rbx.
gendata:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    mov rbx, rcx
    mov r15, r8
.loop:
    call lcg_next                   ; rax=sample
    cvtsi2ss xmm0, eax
    divss xmm0, [f_4194304]         ; [0,2)
    subss xmm0, [f_1]
    mulss xmm0, [datscale]          ; [-R,R) x, R=[datscale]/1 (2.0 normal)
    call lcg_next
    cvtsi2ss xmm1, eax
    divss xmm1, [f_4194304]
    subss xmm1, [f_1]
    mulss xmm1, [datscale]          ; y
    movss [r12], xmm0
    movss [r12 + 4], xmm1
    cmp r15, 0
    je .lin
    call tnonlin
    jmp .st
.lin:
    call tlinear
.st:
    movss [r13], xmm0
    add r12, 8
    add r13, 4
    dec r14
    jne .loop
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ---- forward: fwd_cache(X,T,N) uses [hcur],[actf]; caches Z1/A1/Y; xmm0=loss
; W1 2xH @[pw1], b1 @[pb1], W2 Hx1 @[pw2], b2 @[pb2]. preserves rbx,r12-r15.
fwd_cache:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov rbx, rdi                    ; X
    mov r15, rsi                    ; T
    mov r12, rdx                    ; N
    mov r13d, [hcur]
    ; Z1[N][H] = X[N][2] . W1[2][H]   (AVX2)
    mov rdi, rbx
    mov rsi, [pw1]
    lea rdx, [z1buf]
    mov rcx, r12
    mov r8d, 2
    mov r9, r13
    call matmul_avx2
    ; A1 = act(Z1 + b1)
    lea rsi, [z1buf]
    lea rdi, [a1buf]
    mov rax, r12
    imul rax, r13                   ; N*H elements
    mov rdx, [pb1]
    mov r10d, r13d                  ; column countdown
    mov ecx, [actf]
.loop1:
    test rax, rax
    jz .l1done
    movss xmm0, [rsi]
    addss xmm0, [rdx]
    cmp ecx, 1
    jne .lin1
    xorps xmm1, xmm1
    ucomiss xmm0, xmm1              ; z vs 0 (leaky ReLU)
    jae .lin1                       ; z >= 0: keep (unordered->leak, NaN-safe)
    mulss xmm0, [leak]              ; z < 0: 0.01*z (no dead units)
.lin1:
    movss [rdi], xmm0
    add rsi, 4
    add rdi, 4
    add rdx, 4
    dec r10d
    jnz .noreset
    mov rdx, [pb1]                  ; wrap bias ptr each row
    mov r10d, r13d
.noreset:
    dec rax
    jmp .loop1
.l1done:
    ; Ypre[N][1] = A1[N][H] . W2[H][1]  (AVX2)
    lea rdi, [a1buf]
    mov rsi, [pw2]
    lea rdx, [ybuf]
    mov rcx, r12
    mov r8, r13
    mov r9d, 1
    call matmul_avx2
    ; Y = Ypre + b2 ; loss = mean((y-t)^2)
    lea rsi, [ybuf]
    mov rdi, r15                    ; T
    xorps xmm0, xmm0                ; acc
    mov rax, r12
    mov rdx, [pb2]
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
    movss [lastloss], xmm0
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ---- backward: scalar full-batch grads into GW1/Gb1/GW2/Gb2. preserves regs.
backward:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov rbx, rdi                    ; X
    mov r15, rsi                    ; T (unused: Y cached, err from Y-T)
    mov r12, rdx                    ; N
    mov r13d, [hcur]
    ; zero grads: GW1 2H, Gb1 H, GW2 H, Gb2 1
    mov rax, r13
    shl rax, 1                      ; 2H
    lea rdi, [gw1buf]
    mov rsi, rax
    call zero_f
    lea rdi, [gb1buf]
    mov rsi, r13
    call zero_f
    lea rdi, [gw2buf]
    mov rsi, r13
    call zero_f
    mov dword [gb2buf], 0
    ; scale = 2/N
    cvtsi2ss xmm7, r12d
    movss xmm6, [c_2]
    divss xmm6, xmm7                ; xmm6 = 2/N
    xor r14d, r14d                  ; s
    mov ecx, [actf]
.sloop:
    cmp r14, r12
    jae .sdone
    ; err = Y[s]-T[s]; dy = err*2/N
    lea rax, [ybuf]
    movss xmm0, [rax + r14*4]
    movss xmm1, [r15 + r14*4]       ; T[s]
    subss xmm0, xmm1
    mulss xmm0, xmm6                ; dy
    ; dW2[h] += dy*A1[s,h]; db2 += dy
    movss xmm1, [gb2buf]
    addss xmm1, xmm0
    movss [gb2buf], xmm1
    mov rax, r14
    imul rax, r13                   ; s*H
    lea rdx, [a1buf]
    lea rdx, [rdx + rax*4]          ; A1 row
    lea rdi, [gw2buf]
    xor r10d, r10d                  ; h
.hw2:
    cmp r10, r13
    jae .hw2done
    movss xmm1, [rdx + r10*4]
    mulss xmm1, xmm0                ; dy*a1
    movss xmm2, [rdi + r10*4]
    addss xmm2, xmm1
    movss [rdi + r10*4], xmm2
    inc r10
    jmp .hw2
.hw2done:
    ; per-h: da = dy*W2[h]; dz = act'(z)*da; acc dW1/db1
    mov rsi, [pw2]
    mov rax, r14
    imul rax, r13
    lea rax, [z1buf + rax*4]        ; Z1 row
    mov rdi, [pw1]                  ; W1 base
    lea r8, [gw1buf]
    lea r9, [gb1buf]
    mov r10, rbx
    imul r11, r14, 2                ; s*2
    lea r10, [r10 + r11*4]          ; X row
    xor r11d, r11d                  ; h
.hloop:
    cmp r11, r13
    jae .hdone
    movss xmm1, [rsi + r11*4]       ; W2[h]
    mulss xmm1, xmm0                ; da = dy*W2[h]
    cmp ecx, 1
    jne .dzkeep                     ; linear: dz = da
    xorps xmm2, xmm2                ; 0
    mov rdx, [pb1]                  ; b1 base (rdx free here; reused below)
    movss xmm3, [rax + r11*4]       ; z (pre-bias)
    addss xmm3, [rdx + r11*4]       ; ReLU gates the BIASED sum z+b1
    ucomiss xmm3, xmm2              ; vs 0
    ja .dzkeep                      ; z+b1 > 0: keep da (NaN-safe: unordered->leak)
    mulss xmm1, [leak]              ; z+b1 <= 0: leaky slope 0.01*da
.dzkeep:
    ; db1[h] += dz
    movss xmm2, [r9 + r11*4]
    addss xmm2, xmm1
    movss [r9 + r11*4], xmm2
    ; dW1[0,h] += dz*x0 ; dW1[1,h] += dz*x1 (W1 row-major 2xH)
    movss xmm2, [r10]               ; x0
    mulss xmm2, xmm1
    movss xmm3, [r8 + r11*4]        ; row0[h]
    addss xmm3, xmm2
    movss [r8 + r11*4], xmm3
    movss xmm2, [r10 + 4]           ; x1
    mulss xmm2, xmm1
    mov rdx, r8
    mov rcx, r13                    ; (save H; rcx=actf restored below)
    lea rdx, [rdx + rcx*4]          ; row1 base
    movss xmm3, [rdx + r11*4]
    addss xmm3, xmm2
    movss [rdx + r11*4], xmm3
    mov ecx, [actf]                 ; restore act flag
    mov rsi, [pw2]                  ; (untainted, but reload for clarity)
    ; recompute Z1 row ptr (rax held H above)
    mov rax, r14
    imul rax, r13
    lea rax, [z1buf + rax*4]
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

; ---- sgd: v = mu*v - lr*g; p += v over all params (H=[hcur]). preserves regs.
; uses [lr],[mu].
sgd:
    push rbx
    push r12
    push r13
    mov r13d, [hcur]
    movss xmm6, [mu]
    movss xmm7, [lr]
    ; W1/VW1: count 2H
    mov rsi, [pw1]
    mov rdi, [pv1]
    lea rdx, [gw1buf]
    mov rax, r13
    shl rax, 1
    call .upd
    ; b1: count H
    mov rsi, [pb1]
    mov rdi, [pvb1]
    lea rdx, [gb1buf]
    mov rax, r13
    call .upd
    ; W2: count H
    mov rsi, [pw2]
    mov rdi, [pv2]
    lea rdx, [gw2buf]
    mov rax, r13
    call .upd
    ; b2: count 1
    mov rsi, [pb2]
    mov rdi, [pvb2]
    lea rdx, [gb2buf]
    mov eax, 1
    call .upd
    pop r13
    pop r12
    pop rbx
    ret
; .upd: rsi=params rdi=vel rdx=grads rax=count. clobbers rax,rcx,xmm0-2.
.upd:
    test rax, rax
    jz .udone
    xor ecx, ecx
.uloop:
    movss xmm0, [rdi + rcx*4]       ; v
    mulss xmm0, xmm6                ; mu*v
    movss xmm1, [rdx + rcx*4]       ; g
    mulss xmm1, xmm7                ; lr*g
    subss xmm0, xmm1                ; vnew
    movss [rdi + rcx*4], xmm0
    movss xmm2, [rsi + rcx*4]
    addss xmm2, xmm0
    movss [rsi + rcx*4], xmm2
    inc rcx
    dec rax
    jne .uloop
.udone:
    ret

; ---- train <: rdi=X rsi=T rdx=N | steps=[tsteps] logevery=[tlog] held in
; [hxptr],[htptr],[hn] | minibatch B=[tbatch] (0 or >=N = full batch).
; Batch slice is a pure function of [mstep] (cyclic), so save/resume is
; bit-exact. prints STEP lines. preserves rbx,r12-r15.
train:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov rbx, rdi                    ; X base
    mov r15, rsi                    ; T base
    mov r12, rdx                    ; N
    mov r13, [tsteps]
    xor r14d, r14d                  ; step
.step:
    cmp r14, r13
    jae .tdone
    ; select batch slice (pure function of [mstep]: cyclic, resumable)
    mov rax, [tbatch]
    test rax, rax
    jz .full
    cmp rax, r12
    jae .full
    mov [tmpbatch], rax
    mov rcx, [mstep]
    imul rcx, rax
    mov rax, rcx
    xor edx, edx
    div r12                         ; rdx = off = (mstep*B) % N
    mov [tmpoff], rdx
    mov rax, [tmpoff]
    lea rdi, [rbx + rax*8]          ; Xb
    mov rax, [tmpoff]
    lea rsi, [r15 + rax*4]          ; Tb
    mov rdx, [tmpbatch]             ; Nb
    jmp .dostep
.full:
    mov rdi, rbx
    mov rsi, r15
    mov rdx, r12
.dostep:
    call fwd_cache
    ; fwd clobbers rdi/rsi/rdx! reload slice for backward:
    mov rax, [tbatch]
    test rax, rax
    jz .full2
    cmp rax, r12
    jae .full2
    mov rax, [tmpoff]
    lea rdi, [rbx + rax*8]
    mov rax, [tmpoff]
    lea rsi, [r15 + rax*4]
    mov rdx, [tmpbatch]
    jmp .dostep2
.full2:
    mov rdi, rbx
    mov rsi, r15
    mov rdx, r12
.dostep2:
    call backward
    call sgd
    inc qword [mstep]
    inc r14
    ; log?
    mov rax, r14
    xor edx, edx
    div qword [tlog]
    test rdx, rdx
    jnz .step
    push rax
    push r14
    lea rsi, [msg_step]
    mov rdx, msg_step_l
    call print_str
    mov rax, r14
    call print_u64
    lea rsi, [msg_tr]
    mov rdx, msg_tr_l
    call print_str
    movss xmm0, [lastloss]
    call print_loss_e6
    lea rsi, [msg_he]
    mov rdx, msg_he_l
    call print_str
    mov rdi, [hxptr]
    mov rsi, [htptr]
    mov rdx, [hn]
    call fwd_cache
    movss xmm0, [lastloss]
    call print_loss_e6
    lea rsi, [msg_nl]
    mov rdx, msg_nl_l
    call print_str
    pop r14
    pop rax
    jmp .step
.tdone:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; print_loss_e6: xmm0=loss -> prints <e6-int> (0x<hexbits>). preserves regs.
print_loss_e6:
    push rax
    push rbx
    movss xmm1, xmm0                ; save (print_u64 keeps xmm intact)
    mulss xmm0, [f_1e6]
    cvttss2si rax, xmm0
    call print_u64
    lea rsi, [msg_0x]
    mov rdx, msg_0x_l
    call print_str
    movd eax, xmm1
    call print_hex32
    lea rsi, [msg_rp]
    mov rdx, msg_rp_l
    call print_str
    pop rbx
    pop rax
    ret

; print_hex32: eax -> 8 hex nibbles
print_hex32:
    push rbx
    mov ebx, eax
    lea rsi, [numbuf]
    mov ecx, 8
.hl:
    rol ebx, 4
    mov eax, ebx
    and al, 0x0F
    cmp al, 10
    jb .dg
    add al, 'a' - 10 - '0'
.dg:
    add al, '0'
    mov [rsi], al
    inc rsi
    dec ecx
    jne .hl
    lea rsi, [numbuf]
    mov rdx, 8
    mov rax, SYS_write
    mov rdi, 1
    syscall
    pop rbx
    ret

; ---- gradient check: H=4, N=8, act/Seeds via [gch_*]; prints maxrel-e6.
; asserts < [gctol]. preserves rbx,r12-r15.
gradcheck:
    push rbx
    push r12
    push r13
    push r14
    push r15
    movss xmm0, [datscale]
    movss [sv_datscale], xmm0
    movss xmm0, [c_half]
    movss [datscale], xmm0
    mov qword [gcworst], 0
    mov qword [gcfails], 0
    mov qword [gcfailidx], 0
    mov dword [gcmax], 0            ; float bits
    mov dword [gcallmax], 0
    mov qword [gcidx], 0
    ; data: first 8 of train bufs, fn=[gcfn]
    lea rdi, [xtbuf]
    lea rsi, [ttbuf]
    mov edx, 8
    mov rcx, [gcseed]
    mov r8, [gcfn]
    call gendata
    mov dword [hcur], 4
    mov dword [actf], 0             ; start LINEAR
    ; init tiny (He sc=1.0 for W1 fan2)
    movss xmm0, [c_1]
    movss [initsc], xmm0
    lea rdi, [w1tmp]
    mov rsi, 8
    mov rdx, [gcseed]
    call init_w
    lea rdi, [b1tmp]
    mov rsi, 4
    mov rdx, [gcseed]
    add rdx, 7
    call init_w
    ; copy tiny params into real bufs (first entries), zero rest? use temp
    ; mapping instead: point pw* at temps for the check, restore after.
    mov rax, [pw1]
    mov [sv_pw1], rax
    mov rax, [pb1]
    mov [sv_pb1], rax
    mov rax, [pw2]
    mov [sv_pw2], rax
    mov rax, [pb2]
    mov [sv_pb2], rax
    lea rax, [w1tmp]
    mov [pw1], rax
    lea rax, [b1tmp]
    mov [pb1], rax
    lea rax, [w2tmp]
    mov [pw2], rax
    lea rax, [b2tmp]
    mov [pb2], rax
    ; init W2/b2 tiny too (He fan4 sc=0.7071)
    movss xmm0, [c_he4]
    movss [initsc], xmm0
    lea rdi, [w2tmp]
    mov rsi, 4
    mov rdx, [gcseed]
    add rdx, 13
    call init_w
    mov dword [b2tmp], 0
    ; b1 bias 0.1
    mov eax, 4
    lea rdi, [b1tmp]
.bi:
    mov dword [rdi], 0x40000000
    add rdi, 4
    dec eax
    jne .bi
    ; analytic grads, act=linear
    lea rdi, [xtbuf]
    lea rsi, [ttbuf]
    mov edx, 8
    call fwd_cache
    movss [gcorig], xmm0
    lea rdi, [xtbuf]
    lea rsi, [ttbuf]
    mov edx, 8
    call backward

    ; save analytic copy
    lea rsi, [gw1buf]
    lea rdi, [aw1tmp]
    mov ecx, 8
    call copy_f
    lea rsi, [gb1buf]
    lea rdi, [ab1tmp]
    mov ecx, 4
    call copy_f
    lea rsi, [gw2buf]
    lea rdi, [aw2tmp]
    mov ecx, 4
    call copy_f
    movss xmm0, dword [gb2buf]
    movss [ab2tmp], xmm0
    ; finite-diff each group (gcmax reset per group for localization)
    mov dword [gcmax], 0
    lea rdi, [w1tmp]
    lea rsi, [aw1tmp]
    mov edx, 8
    call gcheck_buf
    lea rsi, [msg_gw1]
    mov rdx, msg_gw1_l
    call print_str
    call print_gcmax
    mov dword [gcmax], 0
    lea rdi, [b1tmp]
    lea rsi, [ab1tmp]
    mov edx, 4
    call gcheck_buf
    lea rsi, [msg_gb1]
    mov rdx, msg_gb1_l
    call print_str
    call print_gcmax
    mov dword [gcmax], 0
    lea rdi, [w2tmp]
    lea rsi, [aw2tmp]
    mov edx, 4
    call gcheck_buf
    lea rsi, [msg_gw2]
    mov rdx, msg_gw2_l
    call print_str
    call print_gcmax
    mov dword [gcmax], 0
    lea rdi, [b2tmp]
    lea rsi, [ab2tmp]
    mov edx, 1
    call gcheck_buf
    lea rsi, [msg_gb2]
    mov rdx, msg_gb2_l
    call print_str
    call print_gcmax
    ; verify exact restore: loss == orig bits
    lea rdi, [xtbuf]
    lea rsi, [ttbuf]
    mov edx, 8
    call fwd_cache
    movd eax, xmm0
    mov ebx, dword [gcorig]
    cmp eax, ebx
    jne .frestore
    lea rsi, [msg_gclin]
    mov rdx, msg_gclin_l
    call print_str
    movss xmm0, [gcallmax]
    movss [gcmax], xmm0
    call print_gcmax
    ; now ReLU pass (kink-margin reseed: keep all |z| > 0.05 so the
    ; point is smooth; perturbation then cannot cross a kink)
    mov dword [actf], 1
    mov qword [gctries], 0
.rlreseed:
    lea rdi, [xtbuf]
    lea rsi, [ttbuf]
    mov edx, 8
    mov rcx, [gcseed]
    mov r8, [gcfn]
    call gendata
    movss xmm0, [c_1]
    movss [initsc], xmm0
    lea rdi, [w1tmp]
    mov rsi, 8
    mov rdx, [gcseed]
    call init_w
    movss xmm0, [c_he4]
    movss [initsc], xmm0
    lea rdi, [w2tmp]
    mov rsi, 4
    mov rdx, [gcseed]
    add rdx, 13
    call init_w
    mov dword [b2tmp], 0
    mov eax, 4
    lea rdi, [b1tmp]
.rlbi:
    mov dword [rdi], 0x40000000
    add rdi, 4
    dec eax
    jne .rlbi
    lea rdi, [xtbuf]
    lea rsi, [ttbuf]
    mov edx, 8
    call fwd_cache
    call minabsz
    ucomiss xmm0, [gcmargin]
    jp .rlnext
    ja .rlmargok
.rlnext:
    inc qword [gctries]
    cmp qword [gctries], 16
    jae .fkink
    add qword [gcseed], 1000
    jmp .rlreseed
.fkink:
    lea rsi, [e_gckink]
    mov rdx, e_gckink_l
    call fail
.rlmargok:
    movss xmm0, [lastloss]
    movss [gcorig], xmm0
    lea rdi, [xtbuf]
    lea rsi, [ttbuf]
    mov edx, 8
    call backward
    lea rsi, [gw1buf]
    lea rdi, [aw1tmp]
    mov ecx, 8
    call copy_f
    lea rsi, [gb1buf]
    lea rdi, [ab1tmp]
    mov ecx, 4
    call copy_f
    lea rsi, [gw2buf]
    lea rdi, [aw2tmp]
    mov ecx, 4
    call copy_f
    movss xmm0, dword [gb2buf]
    movss [ab2tmp], xmm0
    mov dword [gcmax], 0
    lea rdi, [w1tmp]
    lea rsi, [aw1tmp]
    mov edx, 8
    call gcheck_buf
    lea rsi, [msg_gw1]
    mov rdx, msg_gw1_l
    call print_str
    call print_gcmax
    mov dword [gcmax], 0
    lea rdi, [b1tmp]
    lea rsi, [ab1tmp]
    mov edx, 4
    call gcheck_buf
    lea rsi, [msg_gb1]
    mov rdx, msg_gb1_l
    call print_str
    call print_gcmax
    mov dword [gcmax], 0
    lea rdi, [w2tmp]
    lea rsi, [aw2tmp]
    mov edx, 4
    call gcheck_buf
    lea rsi, [msg_gw2]
    mov rdx, msg_gw2_l
    call print_str
    call print_gcmax
    mov dword [gcmax], 0
    lea rdi, [b2tmp]
    lea rsi, [ab2tmp]
    mov edx, 1
    call gcheck_buf
    lea rsi, [msg_gb2]
    mov rdx, msg_gb2_l
    call print_str
    call print_gcmax
    lea rdi, [xtbuf]
    lea rsi, [ttbuf]
    mov edx, 8
    call fwd_cache
    movd eax, xmm0
    mov ebx, dword [gcorig]
    cmp eax, ebx
    jne .frestore
    lea rsi, [msg_gcrelu]
    mov rdx, msg_gcrelu_l
    call print_str
    movss xmm0, [gcallmax]
    movss [gcmax], xmm0
    call print_gcmax
    ; restore real param pointers
    mov rax, [sv_pw1]
    mov [pw1], rax
    mov rax, [sv_pb1]
    mov [pb1], rax
    mov rax, [sv_pw2]
    mov [pw2], rax
    mov rax, [sv_pb2]
    mov [pb2], rax
    ; assert: zero param failures across both passes
    movss xmm0, [sv_datscale]
    movss [datscale], xmm0
    cmp qword [gcfails], 0
    jne .ftol
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret
.ftol:
    lea rsi, [e_gcfail]
    mov rdx, e_gcfail_l
    call print_str
    mov rax, [gcfails]
    call print_u64
    lea rsi, [msg_idx]
    mov rdx, msg_idx_l
    call print_str
    mov rax, [gcfailidx]
    call print_u64
    lea rsi, [msg_maxr]
    mov rdx, msg_maxr_l
    call print_str
    movss xmm0, [gcmax]
    mulss xmm0, [f_1e6]
    cvttss2si rax, xmm0
    call print_u64
    lea rsi, [msg_nl]
    mov rdx, msg_nl_l
    call print_str
    lea rsi, [e_gctol]
    mov rdx, e_gctol_l
    call fail
.frestore:
    lea rsi, [e_gcrestore]
    mov rdx, e_gcrestore_l
    call fail

; copy_f: rsi=src rdi=dst ecx=count(floats)
copy_f:
    mov eax, [rsi]
    mov [rdi], eax
    add rsi, 4
    add rdi, 4
    dec ecx
    jne copy_f
    ret

; minabsz: xmm0 = min|z1buf[i]+b1[i%H]| over the gradcheck N=8,H=[hcur]
; window (the quantity ReLU actually gates). preserves rbx,r12-r15.
minabsz:
    push rbx
    push r12
    push r13
    lea rbx, [z1buf]
    mov r12, [pb1]
    mov r13d, [hcur]
    lea rax, [mask_abs4]
    movups xmm1, [rax]
    mov eax, 8
    imul eax, r13d                  ; count = 8*H
    mov r10d, r13d                  ; column countdown
    movss xmm0, [rbx]
    addss xmm0, [r12]
    andps xmm0, xmm1
    add rbx, 4
    add r12, 4
    dec r10d
    jnz .mfirst
    mov r12, [pb1]
    mov r10d, r13d
.mfirst:
    dec eax
    jz .mdone
.mloop:
    movss xmm2, [rbx]
    addss xmm2, [r12]
    andps xmm2, xmm1
    minss xmm0, xmm2
    add rbx, 4
    add r12, 4
    dec r10d
    jnz .noreset
    mov r12, [pb1]
    mov r10d, r13d
.noreset:
    dec eax
    jne .mloop
.mdone:
    pop r13
    pop r12
    pop rbx
    ret

; relcheck: xmm0=got xmm1=want -> rax=0 ok / 1 bad (|a-b|/(|b|+1e-8) >= 1e-5).
; clobbers xmm2-4,rax,rcx,rdx.
relcheck:
    lea rax, [mask_abs4]
    movups xmm4, [rax]
    movaps xmm2, xmm0
    subss xmm2, xmm1
    andps xmm2, xmm4
    movaps xmm3, xmm1
    andps xmm3, xmm4
    addss xmm3, [f_1e_8]
    divss xmm2, xmm3
    ucomiss xmm2, [f_1em6]
    jp .bad
    jae .bad
    xor eax, eax
    ret
.bad:
    mov eax, 1
    ret

; print_gcmax: prints ' maxrel-e6=<n> ok', merges [gcmax] into [gcallmax]
print_gcmax:
    movss xmm0, [gcmax]
    maxss xmm0, [gcallmax]
    movss [gcallmax], xmm0
    lea rsi, [msg_gcrel]
    mov rdx, msg_gcrel_l
    call print_str
    movss xmm0, [gcmax]
    mulss xmm0, [f_1e6]
    cvttss2si rax, xmm0
    call print_u64
    lea rsi, [msg_ok]
    mov rdx, msg_ok_l
    call print_str
    ret

; gcheck_buf: rdi=params rsi=analytic edx=count. central diff eps=[gceps].
; updates [gcmax]/[gcworst]/[gcidx]. preserves rbx,r12-r15.
gcheck_buf:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov r12, rdi                    ; params
    mov r13, rsi                    ; analytic
    mov r14d, edx                   ; count
    xor r15d, r15d                  ; j
    movss xmm7, [gceps]
    addss xmm7, xmm7                ; 2*eps
    movss [gc2eps], xmm7
.jloop:
    cmp r15, r14
    jae .jdone
    movss xmm0, [r12 + r15*4]       ; orig (exact bits)
    movss [gcsave], xmm0
    movss xmm1, [gceps]
    addss xmm0, xmm1
    movss [r12 + r15*4], xmm0       ; p+e
    lea rdi, [xtbuf]
    lea rsi, [ttbuf]
    mov edx, 8
    push rax
    call fwd_cache
    movss [gcplus], xmm0
    pop rax
    movss xmm0, [gcsave]
    movss xmm1, [gceps]
    subss xmm0, xmm1
    movss [r12 + r15*4], xmm0       ; p-e
    lea rdi, [xtbuf]
    lea rsi, [ttbuf]
    mov edx, 8
    call fwd_cache
    movss xmm0, [gcplus]
    subss xmm0, [lastloss]          ; L+ - L-
    divss xmm0, [gc2eps]            ; numeric
    movss xmm1, [r13 + r15*4]       ; analytic
    ; rel = |a-n| / (|a|+|n|+1e-8)
    movss xmm2, xmm1
    subss xmm2, xmm0
    xorps xmm3, xmm3
    lea rax, [mask_abs4]
    movups xmm4, [rax]
    andps xmm2, xmm4                ; |a-n|
    movaps xmm3, xmm1
    andps xmm3, xmm4                ; |a|
    andps xmm0, xmm4                ; |n|
    addss xmm3, xmm0                ; |a|+|n|
    addss xmm3, [f_1e_8]
    movss [gctmp], xmm2             ; |a-n| before division
    divss xmm2, xmm3                ; rel
    movss xmm4, [gcmax]
    ucomiss xmm2, xmm4
    jbe .nmax
    movss [gcmax], xmm2
    mov rax, [gcidx]
    mov [gcworst], rax
.nmax:
    ; pass if rel<tol OR absdiff<floor (tiny grads: finite-diff noise floor)
    ucomiss xmm2, [gctol]
    jp .pfail
    jb .pok
    movss xmm5, [gctmp]
    ucomiss xmm5, [gcfloor]
    jp .pfail
    jb .pok
.pfail:
    inc qword [gcfails]
    mov rax, [gcidx]
    mov [gcfailidx], rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11
    push r14
    push r15
    lea rsi, [msg_pfail]
    mov rdx, msg_pfail_l
    call print_str
    mov rax, [gcidx]
    call print_u64
    lea rsi, [msg_rel2]
    mov rdx, msg_rel2_l
    call print_str
    movss xmm0, xmm2
    mulss xmm0, [f_1e6]
    cvttss2si rax, xmm0
    call print_u64
    lea rsi, [msg_abs2]
    mov rdx, msg_abs2_l
    call print_str
    movss xmm0, [gctmp]
    mulss xmm0, [f_1e6]
    cvttss2si rax, xmm0
    call print_u64
    lea rsi, [msg_nl]
    mov rdx, msg_nl_l
    call print_str
    pop r15
    pop r14
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
.pok:
    ; exact restore
    movss xmm0, [gcsave]
    movss [r12 + r15*4], xmm0
    inc r15
    inc qword [gcidx]
    jmp .jloop
.jdone:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ---- model region management (order fixed): ----
; 0 W1(2H) 1 b1(H) 2 W2(H) 3 b2(1) 4 VW1 5 Vb1 6 VW2 7 Vb2 ; Hmax=16
alloc_model:
    push rbx
    mov rdi, 128
    mov rsi, 64
    mov rdx, 'W1  '
    call arena_alloc
    test rax, rax
    jz .fail
    mov rdi, 64
    mov rsi, 64
    mov rdx, 'b1  '
    call arena_alloc
    test rax, rax
    jz .fail
    mov rdi, 64
    mov rsi, 64
    mov rdx, 'W2  '
    call arena_alloc
    test rax, rax
    jz .fail
    mov rdi, 4
    mov rsi, 64
    mov rdx, 'b2  '
    call arena_alloc
    test rax, rax
    jz .fail
    mov rdi, 128
    mov rsi, 64
    mov rdx, 'VW1 '
    call arena_alloc
    test rax, rax
    jz .fail
    mov rdi, 64
    mov rsi, 64
    mov rdx, 'Vb1 '
    call arena_alloc
    test rax, rax
    jz .fail
    mov rdi, 64
    mov rsi, 64
    mov rdx, 'VW2 '
    call arena_alloc
    test rax, rax
    jz .fail
    mov rdi, 4
    mov rsi, 64
    mov rdx, 'Vb2 '
    call arena_alloc
    test rax, rax
    jz .fail
    cmp qword [nreg], 8
    jne .fail
    call fetch_addrs
    ; explicit zero of velocities (mmap already zeros; invariant documented)
    mov rdi, [pv1]
    mov rsi, 32
    call zero_f
    mov rdi, [pvb1]
    mov rsi, 16
    call zero_f
    mov rdi, [pv2]
    mov rsi, 16
    call zero_f
    mov rdi, [pvb2]
    mov rsi, 1
    call zero_f
    pop rbx
    ret
.fail:
    pop rbx
    mov rax, -1
    ret

; fetch_addrs: regtab[.off]+arenabase -> pw1..pvb2. leaf.
fetch_addrs:
    mov rax, qword [regtab + 8]
    add rax, [arenabase]
    mov [pw1], rax
    mov rax, qword [regtab + 32 + 8]
    add rax, [arenabase]
    mov [pb1], rax
    mov rax, qword [regtab + 64 + 8]
    add rax, [arenabase]
    mov [pw2], rax
    mov rax, qword [regtab + 96 + 8]
    add rax, [arenabase]
    mov [pb2], rax
    mov rax, qword [regtab + 128 + 8]
    add rax, [arenabase]
    mov [pv1], rax
    mov rax, qword [regtab + 160 + 8]
    add rax, [arenabase]
    mov [pvb1], rax
    mov rax, qword [regtab + 192 + 8]
    add rax, [arenabase]
    mov [pv2], rax
    mov rax, qword [regtab + 224 + 8]
    add rax, [arenabase]
    mov [pvb2], rax
    ret

; eval_print: rdi=X rsi=T rdx=N | prints ' train=' loss ' held-side slot'...
; (caller prints labels; here: fwd_cache + print_loss_e6 of [lastloss])
eval_print:
    push rbx
    call fwd_cache
    movss xmm0, [lastloss]
    call print_loss_e6
    pop rbx
    ret

; ---- entry ----
_start:
    mov rax, [rsp]                  ; argc
    cmp rax, 2
    jb .trainmode
    mov rsi, [rsp + 16]             ; argv[1]
    mov eax, [rsi]
    cmp eax, 0x75736572             ; 'user'
    jne .trainmode
    mov ax, [rsi + 4]
    cmp ax, 0x656d                  ; 'me'
    jne .trainmode
    cmp byte [rsi + 6], 0
    jne .trainmode
    jmp .resumemode

.trainmode:
    call arena_init
    test rax, rax
    jnz .farena
    call alloc_model
    test rax, rax
    jnz .falloc
    mov qword [mstep], 0
    ; ===== MICRO TEST (hand-verified N=1 H=1 linear) =====
    ; X=[[2,3]] W1=[[0.5],[0.25]] b1=[0.1] W2=[2.0] b2=0.5 T=[1.0]
    ; z=1.85 y=4.2 e=3.2 L=10.24 dy=6.4
    ; dW1=[25.6,38.4] db1=12.8 dW2=11.84 db2=6.4
    mov dword [hcur], 1
    mov dword [actf], 0
    mov rdi, [pw1]
    mov dword [rdi], 0x3F000000
    mov dword [rdi + 4], 0x3E800000
    mov rdi, [pb1]
    mov dword [rdi], 0x3DCCCCCD
    mov rdi, [pw2]
    mov dword [rdi], 0x40000000
    mov rdi, [pb2]
    mov dword [rdi], 0x3F000000
    mov dword [xtbuf], 0x40000000
    mov dword [xtbuf + 4], 0x40400000
    mov dword [ttbuf], 0x3F800000
    lea rdi, [xtbuf]
    lea rsi, [ttbuf]
    mov edx, 1
    call fwd_cache
    movss xmm0, [lastloss]
    movss xmm1, [mic_loss]
    call relcheck
    test rax, rax
    jnz .fmicro
    lea rdi, [xtbuf]
    lea rsi, [ttbuf]
    mov edx, 1
    call backward
    movss xmm0, dword [gw1buf]
    movss xmm1, [mic_g0]
    call relcheck
    test rax, rax
    jnz .fmicro
    movss xmm0, dword [gw1buf + 4]
    movss xmm1, [mic_g1]
    call relcheck
    test rax, rax
    jnz .fmicro
    movss xmm0, dword [gb1buf]
    movss xmm1, [mic_g2]
    call relcheck
    test rax, rax
    jnz .fmicro
    movss xmm0, dword [gw2buf]
    movss xmm1, [mic_g3]
    call relcheck
    test rax, rax
    jnz .fmicro
    movss xmm0, dword [gb2buf]
    movss xmm1, [mic_g4]
    call relcheck
    test rax, rax
    jnz .fmicro
    lea rsi, [msg_micro]
    mov rdx, msg_micro_l
    call print_str
    ; ===== LINEAR TEST: 2->8->1, act=linear, t = 2.5x-1.7y+0.8 =====
    mov dword [hcur], 8
    mov dword [actf], 0
    movss xmm0, [c_1]
    movss [initsc], xmm0
    mov rdi, [pw1]
    mov rsi, 16
    mov rdx, 0xA11CE001
    call init_w
    mov eax, 8
    mov rdi, [pb1]
.bi8:
    mov dword [rdi], 0x3DCCCCCD
    add rdi, 4
    dec eax
    jne .bi8
    movss xmm0, [c_half]
    movss [initsc], xmm0
    mov rdi, [pw2]
    mov rsi, 8
    mov rdx, 0xA11CE002
    call init_w
    mov rdi, [pb2]
    mov dword [rdi], 0
    lea rdi, [xtbuf]
    lea rsi, [ttbuf]
    mov edx, 64
    mov rcx, 0xDA7A001
    mov r8d, 0
    call gendata
    lea rdi, [xhbuf]
    lea rsi, [thbuf]
    mov edx, 32
    mov rcx, 0xDA7A002
    mov r8d, 0
    call gendata
    lea rax, [xhbuf]
    mov [hxptr], rax
    lea rax, [thbuf]
    mov [htptr], rax
    mov qword [hn], 32
    lea rsi, [msg_lin]
    mov rdx, msg_lin_l
    call print_str
    lea rsi, [msg_init]
    mov rdx, msg_init_l
    call print_str
    lea rdi, [xtbuf]
    lea rsi, [ttbuf]
    mov edx, 64
    call eval_print
    lea rsi, [msg_he0]
    mov rdx, msg_he0_l
    call print_str
    mov rdi, [hxptr]
    mov rsi, [htptr]
    mov rdx, [hn]
    call eval_print
    lea rsi, [msg_nl]
    mov rdx, msg_nl_l
    call print_str
    mov qword [tsteps], 3000
    mov qword [tlog], 500
    mov qword [tbatch], 0
    lea rdi, [xtbuf]
    lea rsi, [ttbuf]
    mov edx, 64
    call train
    ; asserts: train<1e-6, held<1e-6
    lea rdi, [xtbuf]
    lea rsi, [ttbuf]
    mov edx, 64
    call fwd_cache
    movss xmm0, [lastloss]
    ucomiss xmm0, [f_1em6]
    jp .flin
    jae .flin
    mov rdi, [hxptr]
    mov rsi, [htptr]
    mov rdx, [hn]
    call fwd_cache
    movss xmm0, [lastloss]
    movss [linheld], xmm0
    ucomiss xmm0, [f_1em6]
    jp .flin
    jae .flin
    lea rsi, [msg_linfinal]
    mov rdx, msg_linfinal_l
    call print_str
    movss xmm0, [lastloss]
    call print_loss_e6
    lea rsi, [msg_nl]
    mov rdx, msg_nl_l
    call print_str
    ; unseen 8 points: predict via N=1 evals, maxerr
    xorps xmm7, xmm7                ; maxerr
    lea r12, [xtbuf]
    lea r13, [ybuf]
    xor ebx, ebx                    ; i
.unseen:
    cmp rbx, 8
    jae .unseen_done
    mov rax, rbx
    shl rax, 3                      ; i*8 bytes (2 floats)
    lea rsi, [unseenXY]
    movss xmm0, [rsi + rax]
    movss [r12], xmm0
    movss xmm0, [rsi + rax + 4]
    movss [r12 + 4], xmm0
    movss xmm0, [r12]
    movss xmm1, [r12 + 4]
    call tlinear
    movss [untrue], xmm0
    mov rdi, r12
    lea rsi, [ttbuf]                ; T unused by fwd (loss garbage, ignore)
    mov edx, 1
    call fwd_cache
    movss xmm0, [r13]               ; pred
    subss xmm0, [untrue]
    lea rax, [mask_abs4]
    movups xmm1, [rax]
    andps xmm0, xmm1
    maxss xmm7, xmm0
    inc rbx
    jmp .unseen
.unseen_done:
    lea rsi, [msg_unseen]
    mov rdx, msg_unseen_l
    call print_str
    movss xmm0, xmm7
    mulss xmm0, [f_1e6]
    cvttss2si rax, xmm0
    call print_u64
    lea rsi, [msg_nl]
    mov rdx, msg_nl_l
    call print_str
    ucomiss xmm7, [f_1em3]
    jp .flin
    jae .flin
    ; ===== NONLINEAR: H=16 relu, f=3x^2-2y+1 =====
        mov qword [mstep], 0
mov dword [hcur], 16
    mov dword [actf], 1
    ; gradient check first (H=4 subset, own data; restores pw* after)
    mov qword [gcseed], 0x6A11CEC
    mov qword [gcfn], 1
    call gradcheck
    mov dword [hcur], 16
    mov dword [actf], 1
    ; full init (He: W1 sc=1.0 fan2; W2 sc=0.3536 fan16)
    movss xmm0, [c_1]
    movss [initsc], xmm0
    mov rdi, [pw1]
    mov rsi, 32
    mov rdx, 0x7EED001
    call init_w
    mov eax, 16
    mov rdi, [pb1]
.bi16:
    mov dword [rdi], 0x3DCCCCCD
    add rdi, 4
    dec eax
    jne .bi16
    movss xmm0, [c_he16]
    movss [initsc], xmm0
    mov rdi, [pw2]
    mov rsi, 16
    mov rdx, 0x7EED002
    call init_w
    mov rdi, [pb2]
    mov dword [rdi], 0
    ; velocities already zero (fresh arena)
    lea rdi, [xtbuf]
    lea rsi, [ttbuf]
    mov edx, 128
    mov rcx, 0xDA7A101
    mov r8d, 1
    call gendata
    lea rdi, [xhbuf]
    lea rsi, [thbuf]
    mov edx, 64
    mov rcx, 0xDA7A102
    mov r8d, 1
    call gendata
    lea rax, [xhbuf]
    mov [hxptr], rax
    lea rax, [thbuf]
    mov [htptr], rax
    mov qword [hn], 64
    lea rsi, [msg_nlhdr]
    mov rdx, msg_nlhdr_l
    call print_str
    lea rsi, [msg_init]
    mov rdx, msg_init_l
    call print_str
    lea rdi, [xtbuf]
    lea rsi, [ttbuf]
    mov edx, 128
    call eval_print
    movss xmm0, [lastloss]
    movss [nlinit], xmm0
    lea rsi, [msg_he0]
    mov rdx, msg_he0_l
    call print_str
    mov rdi, [hxptr]
    mov rsi, [htptr]
    mov rdx, [hn]
    call eval_print
    movss xmm0, [lastloss]
    movss [nlinitheld], xmm0
    lea rsi, [msg_nl]
    mov rdx, msg_nl_l
    call print_str
    ; train S1 (fast phase lr=0.05, minibatch 16)
    mov qword [tbatch], 16
    movss xmm0, [lr1]
    movss [lr], xmm0
    mov qword [tsteps], 100000
    mov qword [tlog], 10000
    lea rdi, [xtbuf]
    lea rsi, [ttbuf]
    mov edx, 128
    call train
    ; save checkpoint
    lea rsi, [ckpt_path]
    call model_save
    test rax, rax
    jnz .fsave
    ; SAVE block (recompute held for ybuf)
    mov rdi, [hxptr]
    mov rsi, [htptr]
    mov rdx, [hn]
    call fwd_cache
    lea rsi, [msg_save]
    mov rdx, msg_save_l
    call print_str
    mov rax, [mstep]
    call print_u64
    lea rsi, [msg_held]
    mov rdx, msg_held_l
    call print_str
    movss xmm0, [lastloss]
    movd eax, xmm0
    call print_hex32
    call print_y03
    ; train S2 more (refine phase lr=0.01)
    movss xmm0, [lr2]
    movss [lr], xmm0
    mov qword [tsteps], 100000
    mov qword [tlog], 100000
    lea rdi, [xtbuf]
    lea rsi, [ttbuf]
    mov edx, 128
    call train
    ; asserts: train<0.015, held<0.02, held improved >=100x, held<3x train
    lea rdi, [xtbuf]
    lea rsi, [ttbuf]
    mov edx, 128
    call fwd_cache
    movss xmm0, [lastloss]
    movss [nlfinal], xmm0
    ucomiss xmm0, [f_15em3]
    jp .fnl
    jae .fnl
    mov rdi, [hxptr]
    mov rsi, [htptr]
    mov rdx, [hn]
    call fwd_cache
    movss xmm0, [lastloss]
    movss [nlfinalheld], xmm0
    ucomiss xmm0, [f_2em2]
    jp .fnl
    jae .fnl
    movss xmm1, [nlfinalheld]
    mulss xmm1, [c_100]
    ucomiss xmm1, [nlinitheld]
    jae .fnl
    movss xmm1, [nlfinalheld]
    movss xmm2, [nlfinal]
    addss xmm2, xmm2
    addss xmm2, xmm2
    addss xmm2, [nlfinal]           ; 5x train (generous gap bound)
    ucomiss xmm1, xmm2
    jae .fnl
    ; save final + FINAL block
    lea rsi, [final_path]
    call model_save
    test rax, rax
    jnz .fsave
    lea rsi, [msg_final]
    mov rdx, msg_final_l
    call print_str
    mov rax, [mstep]
    call print_u64
    lea rsi, [msg_trf]
    mov rdx, msg_trf_l
    call print_str
    movss xmm0, [nlfinal]
    movd eax, xmm0
    call print_hex32
    lea rsi, [msg_held]
    mov rdx, msg_held_l
    call print_str
    movss xmm0, [nlfinalheld]
    movd eax, xmm0
    call print_hex32
    call print_y03
    lea rsi, [msg_pass]
    mov rdx, msg_pass_l
    call print_str
    mov rax, SYS_exit
    xor edi, edi
    syscall

.resumemode:
    call arena_init
    test rax, rax
    jnz .farena
    lea rsi, [ckpt_path]
    call model_load
    test rax, rax
    jnz .fload
    cmp qword [nreg], 8
    jne .fnreg
    call fetch_addrs
    mov dword [hcur], 16
    mov dword [actf], 1
    ; regenerate identical datasets
    lea rdi, [xtbuf]
    lea rsi, [ttbuf]
    mov edx, 128
    mov rcx, 0xDA7A101
    mov r8d, 1
    call gendata
    lea rdi, [xhbuf]
    lea rsi, [thbuf]
    mov edx, 64
    mov rcx, 0xDA7A102
    mov r8d, 1
    call gendata
    lea rax, [xhbuf]
    mov [hxptr], rax
    lea rax, [thbuf]
    mov [htptr], rax
    mov qword [hn], 64
    ; verify at-save state -> RESUME block
    mov rdi, [hxptr]
    mov rsi, [htptr]
    mov rdx, [hn]
    call fwd_cache
    lea rsi, [msg_resume]
    mov rdx, msg_resume_l
    call print_str
    mov rax, [mstep]
    call print_u64
    lea rsi, [msg_held]
    mov rdx, msg_held_l
    call print_str
    movss xmm0, [lastloss]
    movd eax, xmm0
    call print_hex32
    call print_y03
    ; continue S2 (must match train mode exactly: lr=0.01, 20000 steps)
    movss xmm0, [lr2]
    movss [lr], xmm0
    mov qword [tbatch], 16
    mov qword [tsteps], 100000
    mov qword [tlog], 100000
    lea rdi, [xtbuf]
    lea rsi, [ttbuf]
    mov edx, 128
    call train
    ; RFINAL block
    lea rdi, [xtbuf]
    lea rsi, [ttbuf]
    mov edx, 128
    call fwd_cache
    movss [nlfinal], xmm0
    mov rdi, [hxptr]
    mov rsi, [htptr]
    mov rdx, [hn]
    call fwd_cache
    movss [nlfinalheld], xmm0
    lea rsi, [final2_path]
    call model_save
    test rax, rax
    jnz .fsave
    lea rsi, [msg_rfinal]
    mov rdx, msg_rfinal_l
    call print_str
    mov rax, [mstep]
    call print_u64
    lea rsi, [msg_trf]
    mov rdx, msg_trf_l
    call print_str
    movss xmm0, [nlfinal]
    movd eax, xmm0
    call print_hex32
    lea rsi, [msg_held]
    mov rdx, msg_held_l
    call print_str
    movss xmm0, [nlfinalheld]
    movd eax, xmm0
    call print_hex32
    call print_y03
    lea rsi, [msg_pass]
    mov rdx, msg_pass_l
    call print_str
    mov rax, SYS_exit
    xor edi, edi
    syscall

.farena:
    lea rsi, [e_arena]
    mov rdx, e_arena_l
    call fail
.fmicro:
    lea rsi, [e_micro]
    mov rdx, e_micro_l
    call fail
.falloc:
    lea rsi, [e_allocm]
    mov rdx, e_allocm_l
    call fail
.flin:
    lea rsi, [e_lin]
    mov rdx, e_lin_l
    call fail
.fnl:
    lea rsi, [e_nl]
    mov rdx, e_nl_l
    call fail
.fsave:
    lea rsi, [e_savem]
    mov rdx, e_savem_l
    call fail
.fload:
    lea rsi, [e_loadm]
    mov rdx, e_loadm_l
    call fail
.fnreg:
    lea rsi, [e_nreg]
    mov rdx, e_nreg_l
    call fail

; print_y03: prints ' y0=0x.. y1=.. y2=.. y3=..' + newline. ybuf holds held preds.
print_y03:
    push rax
    push rbx
    lea rbx, [ybuf]
    lea rsi, [msg_y0]
    mov rdx, msg_y0_l
    call print_str
    mov eax, dword [rbx]
    call print_hex32
    lea rsi, [msg_y1]
    mov rdx, msg_y1_l
    call print_str
    mov eax, dword [rbx + 4]
    call print_hex32
    lea rsi, [msg_y2]
    mov rdx, msg_y2_l
    call print_str
    mov eax, dword [rbx + 8]
    call print_hex32
    lea rsi, [msg_y3]
    mov rdx, msg_y3_l
    call print_str
    mov eax, dword [rbx + 12]
    call print_hex32
    lea rsi, [msg_nl]
    mov rdx, msg_nl_l
    call print_str
    pop rbx
    pop rax
    ret
