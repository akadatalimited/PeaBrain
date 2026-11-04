; PeaBrain quantised inference prototype — Stage 4 (CPU only, no GPU).
; INT8 affine inference for a 2->16->1 leaky-ReLU MLP + VNNI acceleration.
;
; Math (per layer Y = X.W + b, X_q uint8, W_q int8):
;   X_q = clamp(round(X/sx) + zx) ; W_q = clamp(round(W/sw)) (symmetric, zp=0)
;   acc = sum_k X_q[k]*W_q[k,h]                (int32; VNNI vpdpbusd or scalar)
;   Y[h] = sx*sw*(acc - zx*colsum[h]) + b[h]   (colsum[h] = sum_k W_q[k,h])
; Hidden A1 requantised (calibrated sa/za); output stays FP32. Bias FP32.
; K padded to a multiple of 4 (pad A=zx, W=0: contributes exactly 0).
; int32 cannot overflow here: |acc| <= K*255*127 (K<=256 -> 8.3M << 2^31).
;
; Tests: (1) VNNI acc == scalar acc BIT-EXACT (intermediates + predictions);
; (2) INT8 vs independent FP32-scalar reference: maxabs/meanabs + tolerance;
; (3) 256^3 bench: scalar-INT8 vs VNNI (exactness) and FP32-AVX2 (throughput).
; CPUID: AVX_VNNI = leaf7/subleaf1 EAX bit4 (VEX vpdpbusd). Absent -> scalar
; INT8 still proves the quant math; backend reported either way.
;
; Pure FASM, raw syscalls, no libc. Standalone: fasm quant.asm quant && ./quant
format ELF64 executable 3
entry _start

SYS_write = 1
SYS_exit  = 60
SYS_clock = 228
CLOCK_MONO = 1

; VEX.128.66.0F38 vpdpbusd xmm2,xmm0,xmm1 (FASM emits EVEX here, which this
; CPU lacks; VEX map byte is 0xE2 (0F38), NOT 0xE3 (0F3A)). Fixed form:
; all VNNI sites use dest=xmm2, unsigned-src=xmm0, signed-src=xmm1.
macro vdpbd { db 0xC4, 0xE2, 0x79, 0x50, 0xD1 }

segment readable executable

print_str:
    mov rax, SYS_write
    mov rdi, 1
    syscall
    ret

print_u64:
    push rbx
    lea rsi, [numbuf + 31]
    mov rbx, 10
    cmp rax, 0
    jne .loop
    dec rsi
    mov byte [rsi], '0'
    jmp .done0
.loop:
    xor rdx, rdx
    div rbx
    add dl, '0'
    dec rsi
    mov [rsi], dl
    test rax, rax
    jne .loop
.done0:
    lea rdx, [numbuf + 31]
    sub rdx, rsi
    mov rax, SYS_write
    mov rdi, 1
    syscall
    pop rbx
    ret

fail:
    mov rax, SYS_write
    mov rdi, 1
    syscall
    mov rax, SYS_exit
    mov rdi, 1
    syscall

; cpuid_vnni -> rax=1 if AVX2+FMA+OSXSAVE and VEX AVX_VNNI present.
; (AVX-512 masses detect-and-skip: absent on this box, never required.)
cpuid_vnni:
    push rbx
    mov eax, 1
    cpuid
    mov r10d, ecx
    and r10d, (1 shl 12) + (1 shl 28)
    cmp r10d, (1 shl 12) + (1 shl 28)
    jne .no
    mov eax, 7
    xor ecx, ecx
    cpuid
    test ebx, (1 shl 5)             ; AVX2
    jz .no
    mov eax, 7
    mov ecx, 1
    cpuid
    test eax, (1 shl 4)             ; AVX_VNNI (VEX vpdpbusd)
    jz .no
    xor ecx, ecx
    xgetbv
    and eax, 0x6
    cmp eax, 0x6
    jne .no
    mov eax, 1
    pop rbx
    ret
.no:
    xor eax, eax
    pop rbx
    ret

; clock_ms -> rax=ms. preserves rbx,r12-r15.
clock_ms:
    push rbx
    mov rax, SYS_clock
    mov rdi, CLOCK_MONO
    lea rsi, [tsbuf]
    syscall
    mov rax, qword [tsbuf]
    mov rcx, 1000
    imul rax, rcx
    push rax
    mov eax, dword [tsbuf + 8]
    mov ecx, 1000000
    xor edx, edx
    div ecx
    mov ecx, eax
    pop rax
    add rax, rcx
    pop rbx
    ret

; lcg64: rbx=state -> rax=next>>11 (53 bits). preserves rcx? uses rax,rcx,rdx.
lcg64:
    mov rax, rbx
    mov rcx, 6364136223846793005
    imul rax, rcx
    mov rcx, 1442695040888963407
    add rax, rcx
    mov rbx, rax
    shr rax, 11
    ret

; gen_f32: rdi=ptr rsi=count rdx=seed -> uniform [-2,2). preserves rbx.
gen_f32:
    push rbx
    mov rbx, rdx
.loop:
    call lcg64                         ; rax = 53-bit sample
    shr rax, 30                        ; 23 bits
    cvtsi2ss xmm0, eax
    movss xmm1, [f_8388608]
    divss xmm0, xmm1                    ; [0,1)
    subss xmm0, [f_half]                ; [-0.5,0.5)
    mulss xmm0, [f_4]                   ; [-2,2)
    movss [rdi], xmm0
    add rdi, 4
    dec rsi
    jne .loop
    pop rbx
    ret

; minmax_f32: rdi=ptr rcx=count -> xmm0=min xmm1=max. preserves rbx.
minmax_f32:
    movss xmm0, [rdi]
    movss xmm1, [rdi]
    add rdi, 4
    dec rcx
    jz .done
.loop:
    movss xmm2, [rdi]
    minss xmm0, xmm2
    maxss xmm1, xmm2
    add rdi, 4
    dec rcx
    jne .loop
.done:
    ret

; maxabs_f32: rdi=ptr rcx=count -> xmm0=max|x|. preserves rbx.
maxabs_f32:
    xorps xmm0, xmm0
    lea rax, [mask_abs4]
    movups xmm1, [rax]
.loop:
    movss xmm2, [rdi]
    andps xmm2, xmm1
    maxss xmm0, xmm2
    add rdi, 4
    dec rcx
    jne .loop
    ret

; ---- FP32 scalar reference: 2->16->1 leaky (independent of Stages 2/3) ----
; fp32_fwd: uses [qW1],[qb1],[qW2],[qb2] (FP32), X=[qX], N=[qN] -> pred_fp.
; tracks A1 min/max into [qa1min],[qa1max]. preserves rbx,r12-r15.
fp32_fwd:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov rbx, [qX]
    mov r12, [qN]                   ; N
    mov r13, [qW1]
    mov r14, [qb1]
    xor r15d, r15d                  ; s
    mov dword [qa1min], 0x7F800000  ; +inf
    mov dword [qa1max], 0xFF800000  ; -inf
.sloop:
    cmp r15, r12
    jae .sdone
    mov rax, r15
    shl rax, 3                      ; s*8 bytes X offset
    lea r10, [rbx + rax]            ; X row
    movss xmm7, [r10]               ; x0
    movss xmm6, [r10 + 4]           ; x1
    xor r11d, r11d                  ; h
    lea rdx, [a1row]
.hloop:
    cmp r11, 16
    jae .hdone
    mov rax, r11
    movss xmm0, [r13 + rax*4]       ; W1[0,h]
    mulss xmm0, xmm7
    lea rcx, [r13 + 16*4]           ; W1 row1 base (row stride 16 floats)
    movss xmm1, [rcx + r11*4]       ; W1[1,h]
    mulss xmm1, xmm6
    addss xmm0, xmm1
    addss xmm0, [r14 + r11*4]       ; + b1[h]
    xorps xmm1, xmm1
    ucomiss xmm0, xmm1
    jae .keep
    mulss xmm0, [leak]              ; leaky
.keep:
    movss [rdx + r11*4], xmm0
    ; A1 min/max
    movss xmm1, [qa1min]
    minss xmm1, xmm0
    movss [qa1min], xmm1
    movss xmm1, [qa1max]
    maxss xmm1, xmm0
    movss [qa1max], xmm1
    inc r11
    jmp .hloop
.hdone:
    ; spill A1 row to calibration store a1cal[s*64]
    mov rax, r15
    shl rax, 6
    mov rdx, [qa1cal]
    lea rdx, [rdx + rax]
    lea rsi, [a1row]
    mov ecx, 16
.spill:
    mov eax, [rsi]
    mov [rdx], eax
    add rsi, 4
    add rdx, 4
    dec ecx
    jne .spill
    ; y = A1.W2 + b2  (reread A1 row: rdx was advanced by the spill loop)
    mov rax, [qW2]
    lea rdx, [a1row]
    xorps xmm0, xmm0
    xor r11d, r11d
.yloop:
    cmp r11, 16
    jae .ydone
    movss xmm1, [rdx + r11*4]
    mulss xmm1, [rax + r11*4]
    addss xmm0, xmm1
    inc r11
    jmp .yloop
.ydone:
    addss xmm0, [qb2v]
    lea rax, [pred_fp]
    movss [rax + r15*4], xmm0
    inc r15
    jmp .sloop
.sdone:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ---- quantize helpers ----
; qparam_sym: rdi=srcFP rsi=dstS8 rcx=count -> xmm0=scale (maxabs/127).
; guards maxabs=0 -> scale=1. preserves rbx,r12.
qparam_sym:
    push rbx
    push r12
    mov r12, rsi                    ; dst (preserved across maxabs)
    push rdi
    push rcx
    call maxabs_f32
    pop rcx
    pop rdi                         ; base restored
    ucomiss xmm0, [f_zero]
    jp .z
    je .z
    movss xmm1, [f_127]
    divss xmm0, xmm1                ; scale
    jmp .have
.z:
    movss xmm0, [f_1]
.have:
    movss xmm1, [f_1]
    divss xmm1, xmm0                ; invscale
    movss [tmpinv], xmm1
    movss [tmpscale], xmm0
.qloop:
    test rcx, rcx
    jz .qdone
    movss xmm1, [rdi]
    mulss xmm1, [tmpinv]
    cvtss2si eax, xmm1
    cmp eax, 127
    jg .hi
    cmp eax, -128
    jl .lo
    jmp .st
.hi:
    mov eax, 127
    jmp .st
.lo:
    mov eax, -128
.st:
    mov [r12], al
    add rdi, 4
    inc r12
    dec rcx
    jmp .qloop
.qdone:
    movss xmm0, [tmpscale]
    pop r12
    pop rbx
    ret

; qparam_aff: rdi=srcFP rsi=dstU8 rcx=count xmm0=min xmm1=max.
; scale=(max-min)/255 (guard: max<=min -> scale=1,zp=0). zp=round(-min/scale).
; stores scale->[tmpascale], zp->[tmpazp]. returns scale in xmm0. preserves rbx,r12.
qparam_aff:
    push rbx
    push r12
    push r13
    mov r12, rsi                    ; dst
    mov r13, rcx                    ; count
    movss [tmpmin], xmm0
    movss [tmpmax], xmm1
    subss xmm1, xmm0                ; range
    ucomiss xmm1, [f_zero]
    jp .flat
    jbe .flat
    movss xmm2, [f_255]
    divss xmm1, xmm2                ; scale
    movss [tmpascale], xmm1
    movss xmm2, [tmpmin]
    xorps xmm3, xmm3
    subss xmm3, xmm2                ; -min
    divss xmm3, xmm1                ; -min/scale
    cvtss2si eax, xmm3
    cmp eax, 0
    jl .z0
    cmp eax, 255
    jg .z255
    jmp .zhave
.z0:
    xor eax, eax
    jmp .zhave
.z255:
    mov eax, 255
    jmp .zhave
.flat:
    movss xmm1, [f_1]
    movss [tmpascale], xmm1
    xor eax, eax
.zhave:
    mov [tmpazp], rax
    movss xmm2, [tmpascale]
    movss xmm3, [f_1]
    divss xmm3, xmm2                ; invscale
    mov rbx, rax                    ; zp
.qloop:
    test r13, r13
    jz .qdone
    movss xmm1, [rdi]
    mulss xmm1, xmm3
    cvtss2si eax, xmm1
    add eax, ebx
    cmp eax, 0
    jl .c0
    cmp eax, 255
    jg .c255
    jmp .cst
.c0:
    xor eax, eax
    jmp .cst
.c255:
    mov eax, 255
.cst:
    mov [r12], al
    add rdi, 4
    inc r12
    dec r13
    jmp .qloop
.qdone:
    movss xmm0, [tmpascale]
    pop r13
    pop r12
    pop rbx
    ret

; colsum_s8: rdi=baseS8 rsi=dstS32 ecx=cols r8d=rows r9d=stride_bytes.
; dst[c] = sum_r (int8)base[r*stride+c]. preserves rbx,r12-r15.
colsum_s8:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov rbx, rdi
    mov r14, rsi
    mov r15d, ecx                   ; cols
    mov r13d, r8d                   ; rows
    xor r12d, r12d                  ; c
.cloop:
    cmp r12, r15
    jae .cdone
    xor eax, eax
    xor r10d, r10d                  ; r
.rloop:
    cmp r10, r13
    jae .rddone
    mov rdx, r10
    imul rdx, r9
    add rdx, rbx
    movsx edi, byte [rdx + r12]
    add eax, edi
    inc r10
    jmp .rloop
.rddone:
    mov [r14 + r12*4], eax
    inc r12
    jmp .cloop
.cdone:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ---- shared per-lane/per-output finishers (IDENTICAL ops in both INT8 paths
; ---- so scalar-vs-VNNI bit-exactness holds by construction) ----
; lane_out: eax=acc_raw ecx=h rdx=A1qrow -> stores requantised A1q byte.
; out = acc*qsc1 - corr1[h] + b1[h]; leaky; q=clamp(round(out*inva)+za).
; clobbers rax,rcx,rdx,xmm0-2. preserves rbx,r12-r15,r8-r11,r14.
lane_out:
    cvtsi2ss xmm0, eax
    mulss xmm0, [qsc1]
    lea rax, [corr1buf]             ; (rax free: acc already in xmm0;
    movss xmm2, [rax + rcx*4]       ;  rdx must survive: it is the A1q row!)
    subss xmm0, xmm2
    mov rax, [qb1]
    addss xmm0, [rax + rcx*4]
    xorps xmm1, xmm1
    ucomiss xmm0, xmm1
    jae .k
    mulss xmm0, [leak]
.k:
    mulss xmm0, [qinva]
    cvtss2si eax, xmm0
    add eax, [qza]
    cmp eax, 0
    jl .c0
    cmp eax, 255
    jg .c255
    jmp .st
.c0:
    xor eax, eax
    jmp .st
.c255:
    mov eax, 255
.st:
    mov [rdx + rcx], al
    ret

; out2_finish: eax=acc_raw -> xmm0=pred (acc*qsc2 - corr2v + b2v).
; clobbers rax,xmm0-1.
out2_finish:
    cvtsi2ss xmm0, eax
    mulss xmm0, [qsc2]
    subss xmm0, [corr2v]
    addss xmm0, [qb2v]
    ret

; ---- INT8 scalar reference forward (exact integer math, corr form) ----
i8_fwd_scalar:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov rbx, [qXq]
    mov r12, [qN]
    mov r13, [qW1q]
    xor r15d, r15d                  ; s
.sloop:
    cmp r15, r12
    jae .sdone
    mov rax, r15
    shl rax, 1
    lea r10, [rbx + rax]            ; Xq row
    mov rax, r15
    shl rax, 4
    mov rdx, [qA1dst]
    lea r11, [rdx + rax]            ; A1q row (r11 survives: no calls below
    xor r14d, r14d                  ; h      except lane_out (r11-safe))
.hloop:
    cmp r14, 16
    jae .hdone
    movzx eax, byte [r10]
    movsx edx, byte [r13 + r14]     ; W1q[0,h]
    imul eax, edx
    movzx edx, byte [r10 + 1]
    movsx r8d, byte [r13 + 16 + r14] ; W1q[1,h]
    imul edx, r8d
    add eax, edx                    ; acc_raw
    mov ecx, r14d                   ; h
    mov rdx, r11                    ; A1q row
    call lane_out
    inc r14
    jmp .hloop
.hdone:
    ; layer2: acc_raw = sum_h A1q[h]*W2q[h]
    mov rax, [qW2q]
    mov rdx, rax                    ; (W2q base; rdx dead after)
    xor eax, eax
    xor r14d, r14d
.yloop:
    cmp r14, 16
    jae .ydone
    movzx ecx, byte [r11 + r14]
    movsx r8d, byte [rdx + r14]
    imul ecx, r8d
    add eax, ecx
    inc r14
    jmp .yloop
.ydone:
    call out2_finish                ; xmm0=pred
    mov rax, [qpredir]
    movss [rax + r15*4], xmm0
    inc r15
    jmp .sloop
.sdone:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ---- INT8 VNNI forward (identical out-formulas; acc via vpdpbusd) ----
i8_fwd_vnni:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov rbx, [qXq]
    mov r12, [qN]
    mov r9, [qw1t]                  ; W1t base (16x4 transposed+padded)
    mov r8, [qw2pad]                ; W2pad base (4x16B)
    xor r15d, r15d                  ; s
.sloop:
    cmp r15, r12
    jae .sdone
    ; build tmpavec = [x0,x1,zx,zx]
    mov rax, r15
    shl rax, 1
    lea r10, [rbx + rax]            ; Xq row
    mov ax, [r10]
    mov word [tmpavec], ax
    mov eax, [qzxp]
    mov byte [tmpavec + 2], al
    mov byte [tmpavec + 3], al
    ; A1q row -> r10 (survives lane_out: untouched there)
    mov rax, r15
    shl rax, 4
    mov rdx, [qA1dst]
    lea r10, [rdx + rax]
    xor r14d, r14d                  ; t (tile of 4)
.tile:
    cmp r14, 4
    jae .tiledone
    lea rax, [tmpavec]
    vpbroadcastd xmm0, dword [rax]
    mov rax, r14
    shl rax, 4
    vmovups xmm1, [r9 + rax]        ; W1t[t] 16B
    vpxor xmm2, xmm2, xmm2
    vdpbd
    lea rax, [tmpacc]
    vmovups [rax], xmm2
    xor r11d, r11d                  ; m (lane)
.lane:
    cmp r11, 4
    jae .lanedone
    mov eax, dword [tmpacc + r11*4]
    mov ecx, r14d
    shl ecx, 2
    add ecx, r11d                   ; h = t*4+m
    mov rdx, r10                    ; A1q row
    call lane_out
    inc r11
    jmp .lane
.lanedone:
    inc r14
    jmp .tile
.tiledone:
    ; layer2: 4 groups accumulate into xmm2
    vpxor xmm2, xmm2, xmm2
    vpxor xmm0, xmm0, xmm0
    lea rax, [tmpavec16]
    vmovups [rax], xmm0       ; zero 16B once
    xor r14d, r14d                  ; g
.gloop:
    cmp r14, 4
    jae .gdone
    mov rax, r14
    shl rax, 2                      ; g*4
    mov edx, [r10 + rax]            ; A1q 4B (r10=A1q row; edx scratch here)
    lea rax, [tmpavec16]
    mov [rax], edx
    lea rax, [tmpavec16]
    vmovups xmm0, [rax]
    mov rax, r14
    shl rax, 4                      ; g*16
    vmovups xmm1, [r8 + rax]        ; W2pad[g]
    vdpbd
    inc r14
    jmp .gloop
.gdone:
    lea rax, [tmpacc]
    vmovups [rax], xmm2
    mov eax, dword [tmpacc]               ; lane 0
    call out2_finish
    mov rax, [qpredvn]
    movss [rax + r15*4], xmm0
    inc r15
    jmp .sloop
.sdone:
    vzeroupper
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ---- agreement + bench ----
; cmp_bytes: rdi=P rsi=Q rcx=count -> rax=mismatches. preserves rbx.
cmp_bytes:
    push rbx
    xor eax, eax
.loop:
    test rcx, rcx
    jz .done
    mov bl, [rdi]
    cmp bl, [rsi]
    je .same
    inc rax
.same:
    inc rdi
    inc rsi
    dec rcx
    jmp .loop
.done:
    pop rbx
    ret

; cmp_dwords: rdi=P rsi=Q rcx=count(dwords) -> rax=mismatches. preserves rbx.
cmp_dwords:
    push rbx
    xor eax, eax
.loop:
    test rcx, rcx
    jz .done
    mov ebx, [rdi]
    cmp ebx, [rsi]
    je .same
    inc rax
.same:
    add rdi, 4
    add rsi, 4
    dec rcx
    jmp .loop
.done:
    pop rbx
    ret

; diff_stats: rdi=P(fp) rsi=Q(fp) rcx=count -> xmm0=maxabs xmm1=meanabs.
; preserves rbx,r12.
diff_stats:
    push rbx
    push r12
    mov r12, rcx
    xorps xmm0, xmm0
    xorps xmm1, xmm1
    lea rax, [mask_abs4]
    movups xmm2, [rax]
.loop:
    test r12, r12
    jz .done
    movss xmm3, [rdi]
    subss xmm3, [rsi]
    movaps xmm4, xmm3
    andps xmm4, xmm2
    maxss xmm0, xmm4
    addss xmm1, xmm4
    add rdi, 4
    add rsi, 4
    dec r12
    jmp .loop
.done:
    mov rax, [qN]
    cvtsi2ss xmm2, eax
    divss xmm1, xmm2
    pop r12
    pop rbx
    ret

; ---- 256^3 bench kernels (M=K=N=256) ----
; bench_scalar: rdi=Au8 rsi=Bs8 rdx=Cdst(s32).
bench_scalar:
    push rbx
    push r12
    push r13
    push r14
    push r15
    xor ebx, ebx                    ; i
.iloop:
    cmp rbx, 256
    jae .done
    xor r14d, r14d                  ; j
.jloop:
    cmp r14, 256
    jae .jdone
    xor eax, eax                    ; acc
    xor r15d, r15d                  ; k
.kloop:
    cmp r15, 256
    jae .kdone
    mov rcx, rbx
    shl rcx, 8                      ; i*256
    add rcx, r15                    ; +k
    movzx r10d, byte [rdi + rcx]
    mov rcx, r15
    shl rcx, 8
    add rcx, r14
    movsx r11d, byte [rsi + rcx]
    imul r10d, r11d
    add eax, r10d
    inc r15
    jmp .kloop
.kdone:
    mov rcx, rbx
    shl rcx, 8
    add rcx, r14
    mov [rdx + rcx*4], eax
    inc r14
    jmp .jloop
.jdone:
    inc rbx
    jmp .iloop
.done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; pack_b: rdi=Bs8(256x256) rsi=Bpdst. Bp[g][jt][4] layout: 16B per (g,jt),
; lane m = B[4g..4g+3][4jt+m] (4 strided bytes). preserves rbx,r12-r15.
pack_b:
    push rbx
    push r12
    push r13
    push r14
    push r15
    xor r15d, r15d                  ; g 0..63
.gloop:
    cmp r15, 64
    jae .done
    xor r14d, r14d                  ; jt 0..63
.jloop:
    cmp r14, 64
    jae .jdone
    ; dst = Bp + (g*64+jt)*16
    mov rax, r15
    shl rax, 6
    add rax, r14
    shl rax, 4
    lea r13, [rsi + rax]
    xor r12d, r12d                  ; m 0..3 (lane)
.mloop:
    cmp r12, 4
    jae .mdone
    ; lane m bytes: B[(4g+r)*256 + 4jt+m] for r=0..3
    xor ebx, ebx                    ; r
.rloop:
    cmp rbx, 4
    jae .rdone
    mov rax, r15
    shl rax, 2
    add rax, rbx                    ; 4g+r
    shl rax, 8                      ; *256
    mov rcx, r14
    shl rcx, 2
    add rcx, r12                    ; 4jt+m
    add rax, rcx
    mov cl, [rdi + rax]
    mov rax, r12
    shl rax, 2
    add rax, rbx                    ; m*4+r
    mov [r13 + rax], cl
    inc rbx
    jmp .rloop
.rdone:
    inc r12
    jmp .mloop
.mdone:
    inc r14
    jmp .jloop
.jdone:
    inc r15
    jmp .gloop
.done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; bench_vnni: rdi=Au8 rsi=Bp rdx=Cdst(s32). 256^3 via xmm vpdpbusd.
bench_vnni:
    push rbx
    push r12
    push r13
    push r14
    push r15
    xor ebx, ebx                    ; i
.iloop:
    cmp rbx, 256
    jae .done
    xor r14d, r14d                  ; jt 0..63
.jloop:
    cmp r14, 64
    jae .jdone
    vpxor xmm2, xmm2, xmm2
    xor r15d, r15d                  ; g 0..63
.gloop:
    cmp r15, 64
    jae .gdone
    ; A dword = Au8[i*256 + 4g ..]
    mov rax, rbx
    shl rax, 8
    mov rcx, r15
    shl rcx, 2
    add rax, rcx
    vpbroadcastd xmm0, dword [rdi + rax]
    ; Bp block (g*64+jt)*16
    mov rax, r15
    shl rax, 6
    add rax, r14
    shl rax, 4
    vmovups xmm1, [rsi + rax]
    vdpbd
    inc r15
    jmp .gloop
.gdone:
    ; store 4 dwords to C[i*256 + 4jt ..]
    mov rax, rbx
    shl rax, 8
    mov rcx, r14
    shl rcx, 2
    add rax, rcx
    vmovups [rdx + rax*4], xmm2
    inc r14
    jmp .jloop
.jdone:
    inc rbx
    jmp .iloop
.done:
    vzeroupper
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; matmul_avx2 (Stage-2 kernel, verbatim) for the FP32 throughput baseline.
; rdi=A rsi=B rdx=C rcx=M r8=K r9=N (row-major FP32).
matmul_avx2:
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

; ---- entry ----
_start:
    call cpuid_vnni
    mov [use_vnni], rax
    cmp rax, 1
    je .havev
    lea rsi, [msg_be_scalar]
    mov rdx, msg_be_scalar_l
    call print_str
    jmp .gen
.havev:
    lea rsi, [msg_be_vnni]
    mov rdx, msg_be_vnni_l
    call print_str
.gen:
    ; fixed test net 2->16->1 leaky (fresh LCG weights, NOT a checkpoint)
    lea rdi, [Xf]
    mov rsi, 128
    mov rdx, 0x9A17ED01
    call gen_f32
    lea rdi, [Xf]
    mov rcx, 128
    call minmax_f32
    movss [qxmin], xmm0
    movss [qxmax], xmm1
    lea rdi, [W1f]
    mov rsi, 32
    mov rdx, 0x9A17ED02
    call gen_f32
    ; He-scale W1 to [-1,1) (fan-in 2: sqrt(2/2)=1.0; gen gives [-2,2))
    lea rdi, [W1f]
    movss xmm1, [f_half]
    mov ecx, 32
.scalew1:
    movss xmm0, [rdi]
    mulss xmm0, xmm1
    movss [rdi], xmm0
    add rdi, 4
    dec ecx
    jne .scalew1
    ; b1 = 0.1 const (He-style, keeps units alive)
    lea rdi, [b1f]
    mov ecx, 16
.setb1:
    mov dword [rdi], 0x3DCCCCCD
    add rdi, 4
    dec ecx
    jne .setb1
    lea rdi, [W2f]
    mov rsi, 16
    mov rdx, 0x9A17ED04
    call gen_f32
    ; He-scale W2 to +-0.3536 (fan-in 16: sqrt(2/16))
    lea rdi, [W2f]
    movss xmm1, [c_w2sc]
    mov ecx, 16
.scalew2:
    movss xmm0, [rdi]
    mulss xmm0, xmm1
    movss [rdi], xmm0
    add rdi, 4
    dec ecx
    jne .scalew2
    mov dword [b2f], 0x3F000000     ; 0.5
    ; wire FP32 globals + run reference (also calibrates A1)
    lea rax, [Xf]
    mov [qX], rax
    mov qword [qN], 64
    lea rax, [W1f]
    mov [qW1], rax
    lea rax, [b1f]
    mov [qb1], rax
    lea rax, [W2f]
    mov [qW2], rax
    lea rax, [a1cal]
    mov [qa1cal], rax
    lea rax, [b2f]
    movss xmm0, [rax]
    movss [qb2v], xmm0              ; b2 VALUE (fp32_fwd adds [qb2v] directly)
    call fp32_fwd
    lea rsi, [msg_fp32]
    mov rdx, msg_fp32_l
    call print_str
    ; quantize X (affine)
    lea rdi, [Xf]
    lea rsi, [Xq]
    mov rcx, 128
    movss xmm0, [qxmin]
    movss xmm1, [qxmax]
    call qparam_aff
    movss [qsx], xmm0
    mov rax, [tmpazp]
    mov [qzxp], eax
    lea rsi, [msg_sx]
    mov rdx, msg_sx_l
    call print_str
    movss xmm0, [qsx]
    mulss xmm0, [f_1e6]
    cvttss2si rax, xmm0
    call print_u64
    lea rsi, [msg_zp]
    mov rdx, msg_zp_l
    call print_str
    mov eax, [qzxp]
    call print_u64
    lea rsi, [msg_nl]
    mov rdx, msg_nl_l
    call print_str
    ; quantize W1 (symmetric) + transpose+pad to W1t + colsum1
    lea rdi, [W1f]
    lea rsi, [W1q]
    mov rcx, 32
    call qparam_sym
    movss [qsw1], xmm0
    lea rdi, [W1q]
    lea rsi, [cs1buf]
    mov ecx, 16
    mov r8d, 2
    mov r9d, 16
    call colsum_s8
    ; W1t[h][k] = (k<2) ? W1q[k*16+h] : 0
    xor r10d, r10d                  ; h
.tw1:
    cmp r10, 16
    jae .tw1done
    lea rdx, [W1q]
    mov al, [rdx + r10]
    lea rdx, [w1t]
    mov [rdx + r10*4], al
    mov rax, r10
    add rax, 16
    lea rdx, [W1q]
    mov al, [rdx + rax]
    lea rdx, [w1t]
    mov [rdx + r10*4 + 1], al
    mov byte [w1t + r10*4 + 2], 0
    mov byte [w1t + r10*4 + 3], 0
    inc r10
    jmp .tw1
.tw1done:
    ; qsc1 = sx*sw1 ; corr1[h] = zx*colsum1[h]*qsc1
    movss xmm0, [qsx]
    mulss xmm0, [qsw1]
    movss [qsc1], xmm0
    mov eax, [qzxp]
    cvtsi2ss xmm1, eax
    xor r10d, r10d
.corr1:
    cmp r10, 16
    jae .corr1done
    lea rdx, [cs1buf]
    mov eax, [rdx + r10*4]
    cvtsi2ss xmm2, eax
    mulss xmm2, xmm1
    mulss xmm2, xmm0
    lea rdx, [corr1buf]
    movss [rdx + r10*4], xmm2
    inc r10
    jmp .corr1
.corr1done:
    ; A1 scale/zp from calibration store (inline: no quantize needed here;
    ; the INT8 forwards requant their own computed A1 on the fly)
    lea rdi, [a1cal]
    mov rcx, 1024
    call minmax_f32                 ; xmm0=min xmm1=max
    movss [qsamin], xmm0
    movss [qsamax], xmm1
    subss xmm1, xmm0                ; range
    ucomiss xmm1, [f_zero]
    jp .saflat
    jbe .saflat
    movss xmm2, [f_255]
    divss xmm1, xmm2                ; sa
    movss [qsa], xmm1
    movss xmm2, [qsamin]
    xorps xmm3, xmm3
    subss xmm3, xmm2                ; -min
    divss xmm3, xmm1                ; -min/sa
    cvtss2si eax, xmm3
    cmp eax, 0
    jl .saz0
    cmp eax, 255
    jg .saz255
    jmp .sahave
.saz0:
    xor eax, eax
    jmp .sahave
.saz255:
    mov eax, 255
    jmp .sahave
.saflat:
    movss xmm1, [f_1]
    movss [qsa], xmm1
    xor eax, eax
.sahave:
    mov [qza], eax
    lea rsi, [msg_sa]
    mov rdx, msg_sa_l
    call print_str
    movss xmm0, [qsa]
    mulss xmm0, [f_1e6]
    cvttss2si rax, xmm0
    call print_u64
    lea rsi, [msg_zp]
    mov rdx, msg_zp_l
    call print_str
    mov eax, [qza]
    call print_u64
    lea rsi, [msg_nl]
    mov rdx, msg_nl_l
    call print_str
    ; qsc2 = sa*sw2 (computed after W2 quant); qinva = 1/sa
    movss xmm0, [f_1]
    divss xmm0, [qsa]
    movss [qinva], xmm0
    ; quantize W2 (symmetric) + colsum2 + W2pad + qsc2 + corr2
    lea rdi, [W2f]
    lea rsi, [W2q]
    mov rcx, 16
    call qparam_sym
    movss [qsw2], xmm0
    lea rdi, [W2q]
    lea rsi, [cs2buf]
    mov ecx, 1
    mov r8d, 16
    mov r9d, 1
    call colsum_s8
    ; W2pad[g] = 16B: W2q[4g..4g+3] low, rest 0
    vpxor xmm0, xmm0, xmm0
    lea rax, [w2pad]
    vmovups [rax], xmm0
    vmovups [rax + 16], xmm0
    vmovups [rax + 32], xmm0
    vmovups [rax + 48], xmm0
    xor r10d, r10d                  ; g
.pw2:
    cmp r10, 4
    jae .pw2done
    lea rdx, [W2q]
    mov eax, [rdx + r10*4]
    mov rdx, r10
    shl rdx, 4
    lea rcx, [w2pad]
    mov [rcx + rdx], eax
    inc r10
    jmp .pw2
.pw2done:
    vzeroupper
    movss xmm0, [qsa]
    mulss xmm0, [qsw2]
    movss [qsc2], xmm0
    lea rax, [cs2buf]
    mov eax, [rax]
    cvtsi2ss xmm1, eax               ; colsum2
    mov eax, [qza]
    cvtsi2ss xmm2, eax               ; za
    mulss xmm1, xmm2
    mulss xmm1, xmm0                 ; za*colsum2*qsc2
    movss [corr2v], xmm1
    ; wire INT8 globals
    lea rax, [Xq]
    mov [qXq], rax
    lea rax, [W1q]
    mov [qW1q], rax
    lea rax, [W2q]
    mov [qW2q], rax
    lea rax, [w1t]
    mov [qw1t], rax
    lea rax, [w2pad]
    mov [qw2pad], rax
    lea rax, [pred_ir]
    mov [qpredir], rax
    lea rax, [pred_iv]
    mov [qpredvn], rax
    lea rax, [A1q]
    mov [qA1dst], rax
    ; scalar INT8 forward
    call i8_fwd_scalar
    lea rsi, [msg_i8s]
    mov rdx, msg_i8s_l
    call print_str
    ; VNNI INT8 forward (if available)
    cmp qword [use_vnni], 1
    jne .noivn
    lea rax, [A1qv]
    mov [qA1dst], rax
    call i8_fwd_vnni
    lea rsi, [msg_i8v]
    mov rdx, msg_i8v_l
    call print_str
.noivn:
    ; agreement 1: A1q scalar vs VNNI bit-exact
    cmp qword [use_vnni], 1
    jne .noag1
    lea rdi, [A1q]
    lea rsi, [A1qv]
    mov rcx, 1024
    call cmp_bytes
    test rax, rax
    jnz .fa1
    lea rsi, [msg_a1ok]
    mov rdx, msg_a1ok_l
    call print_str
.noag1:
    ; agreement 2: pred scalar vs VNNI bit-exact (64 dwords)
    cmp qword [use_vnni], 1
    jne .noag2
    lea rdi, [pred_ir]
    lea rsi, [pred_iv]
    mov rcx, 64
    call cmp_dwords
    test rax, rax
    jnz .fpr
    lea rsi, [msg_prok]
    mov rdx, msg_prok_l
    call print_str
.noag2:
    lea rdi, [pred_ir]
    lea rsi, [pred_fp]
    mov rcx, 64
    call diff_stats                 ; xmm0=maxabs xmm1=meanabs
    movss [qmaxabs], xmm0
    movss [qmeanabs], xmm1
    lea rsi, [msg_agree]
    mov rdx, msg_agree_l
    call print_str
    mulss xmm0, [f_1e6]
    cvttss2si rax, xmm0
    call print_u64
    lea rsi, [msg_mean]
    mov rdx, msg_mean_l
    call print_str
    movss xmm0, [qmeanabs]
    mulss xmm0, [f_1e6]
    cvttss2si rax, xmm0
    call print_u64
    lea rsi, [msg_nl]
    mov rdx, msg_nl_l
    call print_str
    movss xmm0, [qmaxabs]
    ucomiss xmm0, [qtol]
    jp .ftol
    jae .ftol
    lea rsi, [msg_tolok]
    mov rdx, msg_tolok_l
    call print_str
    ; ---- 256^3 bench ----
    ; gen full-range bytes + float twins
    lea rdi, [bAu8]
    mov rsi, 65536
    mov rdx, 0x8EAC4001
    call gen_bytes
    lea rdi, [bBs8]
    mov rsi, 65536
    mov rdx, 0x8EAC4002
    call gen_bytes
    lea rdi, [bAu8]
    lea rsi, [bAf]
    mov rcx, 65536
    call u8_to_f32
    lea rdi, [bBs8]
    lea rsi, [bBf]
    mov rcx, 65536
    call s8_to_f32
    lea rdi, [bBs8]
    lea rsi, [bBp]
    call pack_b
    lea rsi, [msg_bpack]
    mov rdx, msg_bpack_l
    call print_str
    ; scalar INT8
    call clock_ms
    mov [t0], rax
    lea rdi, [bAu8]
    lea rsi, [bBs8]
    lea rdx, [bCref]
    call bench_scalar
    call clock_ms
    sub rax, [t0]
    mov [tref], rax
    ; VNNI INT8 (if available)
    cmp qword [use_vnni], 1
    jne .nobenchv
    call clock_ms
    mov [t0], rax
    lea rdi, [bAu8]
    lea rsi, [bBp]
    lea rdx, [bCvn]
    call bench_vnni
    call clock_ms
    sub rax, [t0]
    mov [tvn], rax
    ; exactness VNNI vs scalar (65536 dwords)
    lea rdi, [bCref]
    lea rsi, [bCvn]
    mov rcx, 65536
    call cmp_dwords
    test rax, rax
    jnz .fbench
    lea rsi, [msg_bexact]
    mov rdx, msg_bexact_l
    call print_str
.nobenchv:
    ; FP32 AVX2 baseline
    call clock_ms
    mov [t0], rax
    lea rdi, [bAf]
    lea rsi, [bBf]
    lea rdx, [bCf]
    mov ecx, 256
    mov r8d, 256
    mov r9d, 256
    call matmul_avx2
    call clock_ms
    sub rax, [t0]
    mov [tavx], rax
    ; report ms
    lea rsi, [msg_bref]
    mov rdx, msg_bref_l
    call print_str
    mov rax, [tref]
    call print_u64
    cmp qword [use_vnni], 1
    jne .nomsvn
    lea rsi, [msg_bvn]
    mov rdx, msg_bvn_l
    call print_str
    mov rax, [tvn]
    call print_u64
.nomsvn:
    lea rsi, [msg_bavx]
    mov rdx, msg_bavx_l
    call print_str
    mov rax, [tavx]
    call print_u64
    lea rsi, [msg_nl]
    mov rdx, msg_nl_l
    call print_str
    ; sanity: FP32 bench result finite
    lea rax, [bCf]
    movss xmm0, [rax]
    lea rax, [mask_abs4]
    movups xmm1, [rax]
    andps xmm0, xmm1
    ucomiss xmm0, [f_big]
    jp .fbench
    jae .fbench
    lea rsi, [msg_pass]
    mov rdx, msg_pass_l
    call print_str
    mov rax, SYS_exit
    xor edi, edi
    syscall
.fa1:
    lea rsi, [e_a1]
    mov rdx, e_a1_l
    call fail
.fpr:
    lea rsi, [e_pred]
    mov rdx, e_pred_l
    call fail
.ftol:
    lea rsi, [e_tol]
    mov rdx, e_tol_l
    call fail
.fbench:
    lea rsi, [e_bench]
    mov rdx, e_bench_l
    call fail

; gen_bytes: rdi=ptr rsi=count rdx=seed -> LCG low bytes. preserves rbx.
gen_bytes:
    push rbx
    mov rbx, rdx
.loop:
    mov rax, rbx
    mov rcx, 6364136223846793005
    imul rax, rcx
    mov rcx, 1442695040888963407
    add rax, rcx
    mov rbx, rax
    mov [rdi], al
    inc rdi
    dec rsi
    jne .loop
    pop rbx
    ret

; u8_to_f32: rdi=srcU8 rsi=dstF rcx=count. preserves rbx.
u8_to_f32:
.loop:
    test rcx, rcx
    jz .done
    movzx eax, byte [rdi]
    cvtsi2ss xmm0, eax
    movss [rsi], xmm0
    inc rdi
    add rsi, 4
    dec rcx
    jmp .loop
.done:
    ret

; s8_to_f32: rdi=srcS8 rsi=dstF rcx=count. preserves rbx.
s8_to_f32:
.loop:
    test rcx, rcx
    jz .done
    movsx eax, byte [rdi]
    cvtsi2ss xmm0, eax
    movss [rsi], xmm0
    inc rdi
    add rsi, 4
    dec rcx
    jmp .loop
.done:
    ret

segment readable writeable
use_vnni  rq 1
numbuf    rb 32
tsbuf     rb 16
t0        rq 1
tref      rq 1
tvn       rq 1
tavx      rq 1
; FP32 net globals
qX        rq 1
qN        rq 1
qW1       rq 1
qb1       rq 1
qW2       rq 1
qb2v      dd 0.0
qa1cal    rq 1
qa1min    dd 0.0
qa1max    dd 0.0
; INT8 globals
qXq       rq 1
qsx       dd 0.0
qzxp      dd 0
qW1q      rq 1
qsw1      dd 0.0
qA1dst    rq 1
qW2q      rq 1
qsw2      dd 0.0
qsc1      dd 0.0
qsc2      dd 0.0
qinva     dd 0.0
qsa       dd 0.0
qza       dd 0
corr2v    dd 0.0
qpredir   rq 1
qpredvn   rq 1
qw1t      rq 1
qw2pad    rq 1
qmaxabs   dd 0.0
qmeanabs  dd 0.0
qxmin     dd 0.0
qxmax     dd 0.0
qsamin    dd 0.0
qsamax    dd 0.0
tmpinv    dd 0.0
tmpscale  dd 0.0
tmpascale dd 0.0
tmpazp    rq 1
tmpmin    dd 0.0
tmpmax    dd 0.0
astride   rq 1
bstride   rq 1
cstride   rq 1
bsave     rq 1
tmpavec   rb 4
tmpavec16 rb 16
tmpacc    rb 16
a1row     rb 64
; MLP buffers
Xf        rb 512
W1f       rb 128
b1f       rb 64
W2f       rb 64
b2f       rb 4
pred_fp   rb 256
a1cal     rb 4096
Xq        rb 128
W1q       rb 32
w1t       rb 64
cs1buf    rd 16
corr1buf  rd 16
A1q       rb 1024
A1qv      rb 1024
W2q       rb 16
w2pad     rb 64
cs2buf    rd 1
pred_ir   rb 256
pred_iv   rb 256
; bench buffers (256^3)
bAu8      rb 65536
bBs8      rb 65536
bBp       rb 65536
bCref     rb 262144
bCvn      rb 262144
bAf       rb 262144
bBf       rb 262144
bCf       rb 262144
; consts
f_1       dd 1.0
f_zero    dd 0.0
f_half    dd 0.5
f_4       dd 4.0
f_127     dd 127.0
f_255     dd 255.0
f_1e6     dd 1000000.0
f_8388608 dd 8388608.0
f_big     dd 1.0e10
c_w2sc    dd 0.1767767
leak      dd 0.01
qtol      dd 0.05
mask_abs4 dd 0x7FFFFFFF, 0x7FFFFFFF, 0x7FFFFFFF, 0x7FFFFFFF
msg_be_vnni   db 'BACKEND vnni', 10
msg_be_vnni_l = $ - msg_be_vnni
msg_be_scalar db 'BACKEND scalar-int8 (no VNNI)', 10
msg_be_scalar_l = $ - msg_be_scalar
msg_fp32   db 'FP32 ref done', 10
msg_fp32_l = $ - msg_fp32
msg_sx     db 'SCALE sx-e6='
msg_sx_l   = $ - msg_sx
msg_sa     db 'SCALE sa-e6='
msg_sa_l   = $ - msg_sa
msg_zp     db ' zp='
msg_zp_l   = $ - msg_zp
msg_nl     db 10
msg_nl_l   = $ - msg_nl
msg_i8s    db 'INT8 scalar done', 10
msg_i8s_l  = $ - msg_i8s
msg_i8v    db 'INT8 vnni done', 10
msg_i8v_l  = $ - msg_i8v
msg_a1ok   db 'A1Q exact ok', 10
msg_a1ok_l = $ - msg_a1ok
msg_prok   db 'PRED exact ok', 10
msg_prok_l = $ - msg_prok
msg_agree  db 'AGREE maxabs-e6='
msg_agree_l = $ - msg_agree
msg_mean   db ' meanabs-e6='
msg_mean_l = $ - msg_mean
msg_tolok  db 'TOL ok', 10
msg_tolok_l = $ - msg_tolok
msg_bpack  db 'BENCH packed', 10
msg_bpack_l = $ - msg_bpack
msg_bexact db 'BENCH exact ok', 10
msg_bexact_l = $ - msg_bexact
msg_bref   db 'BENCH scalar-ms='
msg_bref_l = $ - msg_bref
msg_bvn    db ' vnni-ms='
msg_bvn_l  = $ - msg_bvn
msg_bavx   db ' fp32avx-ms='
msg_bavx_l = $ - msg_bavx
msg_pass   db 'ALL PASS', 10
msg_pass_l = $ - msg_pass
e_a1      db 'FAIL a1exact', 10
e_a1_l    = $ - e_a1
e_pred    db 'FAIL predexact', 10
e_pred_l  = $ - e_pred
e_tol     db 'FAIL tol', 10
e_tol_l   = $ - e_tol
e_bench   db 'FAIL bench', 10
e_bench_l = $ - e_bench
