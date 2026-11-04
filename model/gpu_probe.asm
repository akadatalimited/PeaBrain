; PeaBrain GPU probe — Stage 6a (recon, read-only).
; Pure-FASM raw-syscall NVRM touchpoint: open /dev/nvidiactl, issue
; NV_ESC_CARD_INFO, print PCI IDs + BAR windows. No libcuda, no .so,
; no writes to the device (read-only info escape only).
;
; ABI provenance (exact driver 610.57.04, MIT-licensed published source):
;   NV_IOCTL_MAGIC 'F', NV_IOCTL_BASE 200, NV_ESC_CARD_INFO 200
;   struct nv_ioctl_card_info (72 bytes) from
;   kernel-open/common/inc/nv-ioctl.h @ tag 610.57.04.
;   ioctl cmd = _IOWR('F',200,72B) = 0xC04846C8 (verified in C first).
; Expected: vendor 0x10de, GA106 device 0x2504 (RTX 3060), valid=1.
; Build: fasm gpu_probe.asm gpu_probe && ./gpu_probe (exit 0 = card found)
format ELF64 executable 3
entry _start

SYS_write  = 1
SYS_openat = 257
SYS_close  = 3
SYS_ioctl  = 16
SYS_exit   = 60

AT_FDCWD = -100
O_RDWR   = 2

NV_CARD_INFO_CMD = 0xC04846C8     ; _IOWR('F', 200, 72)
NV_CI_SZ         = 72
; field offsets within nv_ioctl_card_info_t
NV_CI_VALID   = 0                 ; u8
NV_CI_VENDOR  = 12                ; u16 (pci_info.vendor_id, padded nest)
NV_CI_DEVICE  = 14                ; u16 (pci_info.device_id)
NV_CI_FBSIZE  = 48                ; u64 fb_size (BAR aperture, not total VRAM)

segment readable executable

_start:
    ; fd = openat(AT_FDCWD, "/dev/nvidiactl", O_RDWR)
    mov rax, SYS_openat
    mov rdi, AT_FDCWD
    lea rsi, [path_ctl]
    mov edx, O_RDWR
    syscall
    cmp rax, -4095
    jae .fail_open
    mov r14, rax                  ; fd (callee-saved-ish: no calls but syscall)
    ; zero the 72-byte arg (BSS already zero, but reset for reruns)
    lea rdi, [ci_buf]
    mov ecx, NV_CI_SZ
    xor eax, eax
    rep stosb
    ; ioctl(fd, 0xC04846C8, &ci_buf)
    mov rax, SYS_ioctl
    mov rdi, r14
    mov esi, NV_CARD_INFO_CMD
    lea rdx, [ci_buf]
    syscall
    test rax, rax
    js .fail_ioctl
    ; out "vendor=.... device=....\n"
    lea rsi, [m_vendor]
    call out_cstr
    movzx eax, word [ci_buf + NV_CI_VENDOR]
    call out_hex16
    lea rsi, [m_device]
    call out_cstr
    movzx eax, word [ci_buf + NV_CI_DEVICE]
    call out_hex16
    lea rsi, [m_valid]
    call out_cstr
    movzx eax, byte [ci_buf + NV_CI_VALID]
    call out_hex8
    lea rsi, [m_fb]
    call out_cstr
    mov rax, qword [ci_buf + NV_CI_FBSIZE]
    shr rax, 20                   ; bytes -> MiB
    call out_uint
    lea rsi, [m_mib]
    call out_cstr
    ; verdict: vendor must be 0x10de and valid nonzero
    cmp byte [ci_buf + NV_CI_VALID], 0
    je .fail_bad
    cmp word [ci_buf + NV_CI_VENDOR], 0x10DE
    jne .fail_bad
    lea rsi, [m_pass]
    call out_cstr
    xor edi, edi
    mov rax, SYS_exit
    syscall
.fail_open:
    lea rsi, [m_noopen]
    call out_cstr
    jmp .die
.fail_ioctl:
    lea rsi, [m_noioctl]
    call out_cstr
    jmp .die
.fail_bad:
    lea rsi, [m_bad]
    call out_cstr
.die:
    mov edi, 1
    mov rax, SYS_exit
    syscall

; out_cstr: rsi=NUL string -> stdout. clobbers rax,rdi,rdx,rcx.
out_cstr:
    push rsi
    xor edx, edx
.len:
    cmp byte [rsi + rdx], 0
    je .have
    inc rdx
    jmp .len
.have:
    mov rax, SYS_write
    mov edi, 1
    pop rsi
    syscall
    ret

; out_hex16: eax value -> 4 lowercase hex chars. clobbers rax,rcx,rdx,rsi,rdi.
out_hex16:
    mov rcx, 4
    lea rsi, [hexbuf + 4]
.dig:
    mov edx, eax
    and edx, 0xF
    cmp dl, 10
    jb .d09
    add dl, 'a' - 10
    jmp .sto
.d09:
    add dl, '0'
.sto:
    dec rsi
    mov [rsi], dl
    shr eax, 4
    dec rcx
    jne .dig
    mov rdx, 4
    mov rax, SYS_write
    mov edi, 1
    syscall
    ret

; out_hex8: al value -> 2 hex chars.
out_hex8:
    movzx eax, al
    mov rcx, 2
    lea rsi, [hexbuf + 4]
.dig:
    mov edx, eax
    and edx, 0xF
    cmp dl, 10
    jb .d09
    add dl, 'a' - 10
    jmp .sto
.d09:
    add dl, '0'
.sto:
    dec rsi
    mov [rsi], dl
    shr eax, 4
    dec rcx
    jne .dig
    mov rdx, 2
    mov rax, SYS_write
    mov edi, 1
    syscall
    ret

; out_uint: rax value -> decimal. clobbers rax,rcx,rdx,rsi,rdi.
out_uint:
    lea rsi, [numbuf + 32]
    mov rcx, 10
    test rax, rax
    jnz .lp
    dec rsi
    mov byte [rsi], '0'
    mov rdx, 1
    jmp .wr
.lp:
    xor edx, edx
    div rcx
    add dl, '0'
    dec rsi
    mov [rsi], dl
    test rax, rax
    jne .lp
    lea rdx, [numbuf + 32]
    sub rdx, rsi
.wr:
    mov rax, SYS_write
    mov edi, 1
    syscall
    ret

segment readable writeable
path_ctl db '/dev/nvidiactl', 0
m_vendor db 'vendor=', 0
m_device db ' device=', 0
m_valid  db ' valid=', 0
m_fb     db ' fb_aperture=', 0
m_mib    db 'MiB', 10, 0
m_pass   db 'GPU-PROBE PASS', 10, 0
m_noopen db 'GPU-PROBE FAIL: open', 10, 0
m_noioctl db 'GPU-PROBE FAIL: ioctl', 10, 0
m_bad    db 'GPU-PROBE FAIL: not nvidia', 10, 0
ci_buf   rb 72
hexbuf   rb 8
numbuf   rb 32
