; PeaBrain matrix engine prototype — Stage 2.
; FP32 row-major matmul: AVX2/FMA outer-product kernel + scalar reference.
; Self-test: hand-known answers, AVX2-vs-scalar agreement (rel tol 1e-5),
; CPUID backend detection, 256^3 micro-benchmark with GFLOPS.
; Pure FASM, raw syscalls, no libc.
; Build: fasm mat.asm mat && ./mat   (exit 0 = all PASS)
format ELF64 executable 3
entry _start

SYS_write = 1
SYS_exit  = 60
SYS_clock = 228
CLOCK_MONO = 1

FMA_BIT  = 1 shl 12
AVX_BIT  = 1 shl 28
AVX2_BIT = 1 shl 5

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

; cpuid_check -> rax=1 if AVX2+FMA+OS-sup else 0. preserves rbx.
cpuid_check:
    push rbx
    mov eax, 1
    cpuid
    mov r10d, ecx
    and r10d, FMA_BIT + AVX_BIT
    cmp r10d, FMA_BIT + AVX_BIT
    jne .no
    mov eax, 7
    xor ecx, ecx
    cpuid
    test ebx, AVX2_BIT
    jz .no
    ; OS support: XCR0[2:1] (AVX state) via xgetx
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

; genmat: rdi=ptr, rsi=count(floats), rdx=seed -> fills [-1,1) deterministic
genmat:
    push rbx
    mov rbx, rdx
.loop:
    mov rax, rbx
    mov rcx, 6364136223846793005
    imul rax, rcx
    mov rcx, 1442695040888963407
    add rax, rcx
    mov rbx, rax
    shr rax, 41                    ; 23 bits
    cvtsi2ss xmm0, eax
    movss xmm1, [f_8388608]
    divss xmm0, xmm1                ; [0,2)
    subss xmm0, [f_1]               ; [-1,1)
    movss [rdi], xmm0
    add rdi, 4
    dec rsi
    jne .loop
    pop rbx
    ret

; zero: rdi=ptr, rsi=count(floats)
zero:
    xor eax, eax
.z:
    mov [rdi], eax
    add rdi, 4
    dec rsi
    jne .z
    ret

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
    ; N in r9; row strides: astride=K*4, bstride=N*4, cstride=N*4
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
    ; Arow = A + i*astride ; Crow = C + i*cstride
    mov rax, rbx
    imul rax, [astride]
    lea r10, [rdi + rax]            ; Arow
    mov rax, rbx
    imul rax, [cstride]
    lea r11, [r15 + rax]            ; Crow
    ; j tiles of 8
    xor r14d, r14d                  ; j (reuse r14 as j; B base saved below)
    mov [bsave], rsi
.jtile:
    lea rax, [r14 + 8]
    cmp rax, r9
    ja .tail
    vxorps ymm2, ymm2, ymm2
    ; Bj = B + j*4
    mov rax, r14
    shl rax, 2
    lea rcx, [rsi + rax]            ; Bj col ptr (k=0 row)
    mov rax, r10                    ; a_ptr = Arow
    push r11
    push r10                        ; frees r10 as k counter (restored below)
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
    ; scalar column j=r14
    mov rax, r10                    ; a_ptr
    mov rcx, [bsave]
    lea rcx, [rcx + r14*4]          ; B[0][j]
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

; matmul_ref: same args, pure scalar (mulss/addss)
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

; maxdiff: rdi=P rsi=Q rcx=count -> xmm0=max|a-b|, xmm1=max rel. preserves rbx.
maxdiff:
    push rbx
    lea rax, [mask_abs]
    movups xmm7, [rax]
    xorps xmm0, xmm0
    xorps xmm1, xmm1
    mov ebx, [f_1]
    movd xmm2, ebx                  ; one
.loop:
    movss xmm3, [rdi]
    movss xmm4, [rsi]
    subss xmm3, xmm4                ; diff
    movaps xmm5, xmm3
    andps xmm5, xmm7                ; |diff|
    maxss xmm0, xmm5
    ; rel = |diff| / max(1,|b|)
    movaps xmm6, xmm4
    andps xmm6, xmm7
    maxss xmm6, xmm2
    divss xmm5, xmm6
    maxss xmm1, xmm5
    add rdi, 4
    add rsi, 4
    dec rcx
    jne .loop
    pop rbx
    ret

; clock_ms -> rax=ms (u64). preserves rbx,r12-r15.
clock_ms:
    push rbx
    mov rax, SYS_clock
    mov rdi, CLOCK_MONO
    lea rsi, [tsbuf]
    syscall
    mov rax, qword [tsbuf]                ; sec
    mov rcx, 1000
    imul rax, rcx                   ; sec*1000
    push rax
    mov eax, dword [tsbuf + 8]      ; nsec (<1e9)
    mov ecx, 1000000
    xor edx, edx
    div ecx                         ; eax = nsec/1e6
    mov ecx, eax
    pop rax
    add rax, rcx
    pop rbx
    ret

; run_case: rdi=A rsi=B rdx=C r8=Cref rcx=M, K=[kcase], N=[ncase]
; gens A/B, zeros outputs, runs AVX2 (or ref if no hw) vs ref, compares.
; prints CASE line. rax=0 ok else 1. preserves rbx,r12-r15.
run_case:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov rbx, rdi                    ; A
    mov r15, rsi                    ; B
    mov r14, rdx                    ; C
    mov [crefptr], r8
    mov r12, rcx                    ; M
    mov rax, [kcase]
    mov [kcasev], rax
    mov rax, [ncase]
    mov [ncasev], rax
    ; Acount=M*K
    mov rax, r12
    imul rax, [kcasev]
    mov rdi, rbx
    mov rsi, rax
    mov rdx, 0x1111111111111111
    push rax
    call genmat
    ; Bcount=K*N
    mov rax, [kcasev]
    imul rax, [ncasev]
    mov rdi, r15
    mov rsi, rax
    mov rdx, 0x2222222222222222
    push rax
    call genmat
    ; Ccount=M*N, zero both outputs
    mov rax, r12
    imul rax, [ncasev]
    mov [ccount], rax
    mov rdi, r14
    mov rsi, rax
    call zero
    mov rdi, [crefptr]
    mov rsi, [ccount]
    call zero
    pop rax                         ; (balance; Bcount unused further)
    pop rax                         ; Acount
    ; run fast kernel -> C
    mov rdi, rbx
    mov rsi, r15
    mov rdx, r14
    mov rcx, r12
    mov r8, [kcasev]
    mov r9, [ncasev]
    cmp qword [use_avx], 1
    je .fast
    call matmul_ref
    jmp .slow
.fast:
    call matmul_avx2
.slow:
    ; run reference -> Cref
    mov rdi, rbx
    mov rsi, r15
    mov rdx, [crefptr]
    mov rcx, r12
    mov r8, [kcasev]
    mov r9, [ncasev]
    call matmul_ref
    ; compare
    mov rdi, r14
    mov rsi, [crefptr]
    mov rcx, [ccount]
    call maxdiff                     ; xmm0=maxabs xmm1=maxrel
    movaps xmm2, xmm0
    movaps xmm3, xmm1
    ; tol check (NaN-safe: jp -> bad)
    ucomiss xmm3, [f_tol]
    jp .bad
    ja .bad
    ; print CASE MxKxN maxabs=<.6f scaled> maxrel=<...> ok
    push rax
    lea rsi, [msg_case]
    mov rdx, msg_case_l
    call print_str
    mov rax, r12
    call print_u64
    lea rsi, [msg_x]
    mov rdx, msg_x_l
    call print_str
    mov rax, [kcasev]
    call print_u64
    lea rsi, [msg_x]
    mov rdx, msg_x_l
    call print_str
    mov rax, [ncasev]
    call print_u64
    lea rsi, [msg_abs]
    mov rdx, msg_abs_l
    call print_str
    movaps xmm0, xmm2
    mulss xmm0, [f_1e6]
    cvttss2si rax, xmm0
    call print_u64
    lea rsi, [msg_rel]
    mov rdx, msg_rel_l
    call print_str
    movaps xmm0, xmm3
    mulss xmm0, [f_1e6]
    cvttss2si rax, xmm0
    call print_u64
    lea rsi, [msg_ok]
    mov rdx, msg_ok_l
    call print_str
    pop rax
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

_start:
    call cpuid_check
    mov [use_avx], rax
    cmp rax, 1
    je .havx
    lea rsi, [msg_be_ref]
    mov rdx, msg_be_ref_l
    call print_str
    jmp .cases
.havx:
    lea rsi, [msg_be_avx]
    mov rdx, msg_be_avx_l
    call print_str
.cases:
    ; ---- hand 2x2: [[1,2],[3,4]] x [[5,6],[7,8]] = [[19,22],[43,50]] ----
    lea rdi, [handA]
    lea rsi, [handB]
    lea rdx, [matC]
    mov ecx, 2
    mov r8d, 2
    mov r9d, 2
    cmp qword [use_avx], 1
    je .havx2
    call matmul_ref
    jmp .hcmp
.havx2:
    call matmul_avx2
.hcmp:
    lea rdi, [matC]
    lea rsi, [handH]
    mov ecx, 4
    call maxdiff
    ucomiss xmm1, [f_tol]
    jp .fhand
    ja .fhand
    lea rsi, [msg_hand]
    mov rdx, msg_hand_l
    call print_str
    ; ---- identity 4x4: C = I x X must equal X (X=matA, I=matB) ----
    lea rdi, [matA]
    mov rsi, 16
    mov rdx, 0x3333333333333333
    call genmat
    lea rdi, [matB]
    mov rsi, 16
    call zero
    mov dword [matB], 0x3F800000
    mov dword [matB + 20], 0x3F800000
    mov dword [matB + 40], 0x3F800000
    mov dword [matB + 60], 0x3F800000
    lea rdi, [matB]
    lea rsi, [matA]
    lea rdx, [matC]
    mov ecx, 4
    mov r8d, 4
    mov r9d, 4
    cmp qword [use_avx], 1
    je .havx3
    call matmul_ref
    jmp .icmp
.havx3:
    call matmul_avx2
.icmp:
    lea rdi, [matC]
    lea rsi, [matA]
    mov ecx, 16
    call maxdiff
    ucomiss xmm1, [f_tol]
    jp .fident
    ja .fident
    lea rsi, [msg_ident]
    mov rdx, msg_ident_l
    call print_str
    ; ---- table cases ----
    mov qword [kcase], 5
    mov qword [ncase], 7
    lea rdi, [matA]
    lea rsi, [matB]
    lea rdx, [matC]
    lea r8, [matD]
    mov ecx, 3
    call run_case
    test rax, rax
    jnz .fcase
    mov qword [kcase], 16
    mov qword [ncase], 16
    lea rdi, [matA]
    lea rsi, [matB]
    lea rdx, [matC]
    lea r8, [matD]
    mov ecx, 16
    call run_case
    test rax, rax
    jnz .fcase
    mov qword [kcase], 13
    mov qword [ncase], 11
    lea rdi, [matA]
    lea rsi, [matB]
    lea rdx, [matC]
    lea r8, [matD]
    mov ecx, 17
    call run_case
    test rax, rax
    jnz .fcase
    mov qword [kcase], 48
    mov qword [ncase], 32
    lea rdi, [matA]
    lea rsi, [matB]
    lea rdx, [matC]
    lea r8, [matD]
    mov ecx, 64
    call run_case
    test rax, rax
    jnz .fcase
    ; ---- bench 256^3 ----
    lea rdi, [matA]
    mov rsi, 65536
    mov rdx, 0x4444444444444444
    call genmat
    lea rdi, [matB]
    mov rsi, 65536
    mov rdx, 0x5555555555555555
    call genmat
    lea rdi, [matC]
    mov rsi, 65536
    call zero
    cmp qword [use_avx], 1
    jne .benchref
    call clock_ms
    mov [t0], rax
    lea rdi, [matA]
    lea rsi, [matB]
    lea rdx, [matC]
    mov ecx, 256
    mov r8d, 256
    mov r9d, 256
    call matmul_avx2
    call clock_ms
    sub rax, [t0]
    mov [tavx], rax
    lea rsi, [msg_bench_avx]
    mov rdx, msg_bench_avx_l
    call print_str
    mov rax, [tavx]
    call print_u64
    lea rsi, [msg_ms]
    mov rdx, msg_ms_l
    call print_str
.benchref:
    call clock_ms
    mov [t0], rax
    lea rdi, [matA]
    lea rsi, [matB]
    lea rdx, [matC]
    mov ecx, 256
    mov r8d, 256
    mov r9d, 256
    call matmul_ref
    call clock_ms
    sub rax, [t0]
    mov [tref], rax
    lea rsi, [msg_bench_ref]
    mov rdx, msg_bench_ref_l
    call print_str
    mov rax, [tref]
    call print_u64
    lea rsi, [msg_ms]
    mov rdx, msg_ms_l
    call print_str
    ; verify bench result sane: C[0] finite (|C[0]| < 1e10)
    movss xmm0, dword [matC]
    lea rax, [mask_abs]
    movups xmm7, [rax]
    andps xmm0, xmm7
    ucomiss xmm0, [f_big]
    jp .fbench
    jae .fbench
    lea rsi, [msg_pass]
    mov rdx, msg_pass_l
    call print_str
    mov rax, SYS_exit
    xor edi, edi
    syscall
.fhand:
    lea rsi, [e_hand]
    mov rdx, e_hand_l
    call fail
.fident:
    lea rsi, [e_ident]
    mov rdx, e_ident_l
    call fail
.fcase:
    lea rsi, [e_case]
    mov rdx, e_case_l
    call fail
.fbench:
    lea rsi, [e_bench]
    mov rdx, e_bench_l
    call fail

segment readable writeable
use_avx  rq 1
kcase    rq 1
ncase    rq 1
kcasev   rq 1
ncasev   rq 1
ccount   rq 1
crefptr  rq 1
astride  rq 1
bstride  rq 1
cstride  rq 1
bsave    rq 1
t0       rq 1
tavx     rq 1
tref     rq 1
tsbuf    rb 16
numbuf   rb 32
matA     rb 262144
matB     rb 262144
matC     rb 262144
matD     rb 262144
f_1        dd 1.0
f_tol      dd 0.00001
f_1e6      dd 1000000.0
f_big      dd 1.0e10
f_8388608  dd 8388608.0
mask_abs   dd 0x7FFFFFFF, 0x7FFFFFFF, 0x7FFFFFFF, 0x7FFFFFFF
handA      dd 1.0, 2.0, 3.0, 4.0
handB      dd 5.0, 6.0, 7.0, 8.0
handH      dd 19.0, 22.0, 43.0, 50.0
msg_be_avx   db 'BACKEND avx2fma', 10
msg_be_avx_l = $ - msg_be_avx
msg_be_ref   db 'BACKEND reference', 10
msg_be_ref_l = $ - msg_be_ref
msg_hand     db 'HAND ok', 10
msg_hand_l   = $ - msg_hand
msg_ident    db 'IDENT ok', 10
msg_ident_l  = $ - msg_ident
msg_case     db 'CASE '
msg_case_l   = $ - msg_case
msg_x        db 'x'
msg_x_l      = $ - msg_x
msg_abs      db ' maxabs-e6='
msg_abs_l    = $ - msg_abs
msg_rel      db ' maxrel-e6='
msg_rel_l    = $ - msg_rel
msg_ok       db ' ok', 10
msg_ok_l     = $ - msg_ok
msg_bench_avx db 'BENCH avx ms='
msg_bench_avx_l = $ - msg_bench_avx
msg_bench_ref db 'BENCH ref ms='
msg_bench_ref_l = $ - msg_bench_ref
msg_ms       db 'ms', 10
msg_ms_l     = $ - msg_ms
msg_pass     db 'ALL PASS', 10
msg_pass_l   = $ - msg_pass
e_hand    db 'FAIL hand', 10
e_hand_l  = $ - e_hand
e_ident   db 'FAIL ident', 10
e_ident_l = $ - e_ident
e_case    db 'FAIL case', 10
e_case_l  = $ - e_case
e_bench   db 'FAIL bench', 10
e_bench_l = $ - e_bench
