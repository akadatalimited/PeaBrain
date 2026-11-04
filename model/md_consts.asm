; PeaBrain model consts (initialized; included before trailing BSS).
; PeaBrain model data: consts/messages first, ALL rb buffers trailing (NOBITS).
md_hcur     dd 0
md_actf     dd 0
md_tact     dd 0
md_lastloss dd 0.0
md_hasloss  dd 0
md_lr       dd 0.01
md_initsc   dd 1.0
md_ldh      dd 0
md_ldact    dd 0
md_Gb2      dd 0.0
md_tmpf     dd 0.0
md_f1       dd 1.0
md_f01      dd 0.01
md_f16      dd 16.0
md_fseed0   dd 42.0
md_f10      dd 10.0
md_f1e6     dd 1000000.0
md_f1e12    dd 1.0e12
md_fneg0    dd 0x80000000
md_f2       dd 2.0
md_mu0      dd 0.9
md_leak     dd 0.01
md_f8388608 dd 8388608.0
md_he_sc    dd 1.41421356, 1.0, 0.81649658, 0.70710678
            dd 0.63245553, 0.57735027, 0.53452248, 0.5
            dd 0.47140452, 0.44721360, 0.42640143, 0.40824829
            dd 0.39223227, 0.37796447, 0.36514837, 0.35355339
md_absmask  dd 0x7FFFFFFF, 0x7FFFFFFF, 0x7FFFFFFF, 0x7FFFFFFF
md_defpath  db 'peabrain.pbmd', 0
md_dot      db '.', 0
md_m_modnone db 'no model loaded (model_init or model_load first)', 0
md_m_modio  db 'model save/load failed', 0
md_m_modmem db 'model alloc failed (mmap)', 0
md_v_leaky  db 'leaky', 0
md_v_linear db 'linear', 0
md_v_none   db 'none', 0
md_v_avx    db 'avx2fma', 0
md_v_ref    db 'reference', 0
md_jn_init  db '{"ok":true,"hidden":', 0
md_jn_act   db ',"activation":"', 0
md_jn_step0 db '","step":0}', 0
md_jn_train db '{"ok":true,"step":', 0
md_jn_loss  db ',"train_loss":', 0
md_jn_pred  db '{"ok":true,"values":[', 0
md_jn_save  db '{"ok":true,"step":', 0
md_jn_load  db '{"ok":true,"step":', 0
md_jn_regions db ',"regions":', 0
md_jn_status db '{"ok":true,"initialized":', 0
md_jn_hidden db ',"hidden":', 0
md_jn_act2  db ',"activation":"', 0
md_jn_step  db '","step":', 0
md_jn_lastloss db ',"last_loss":', 0
md_jn_alloc db ',"allocated":', 0
md_jn_commit db ',"committed":', 0
md_jn_backend db ',"backend":"', 0
md_jn_gpu   db '","gpu":"unavailable","gpu_reason":"no libcuda; CPU reference is the supported backend (see MODEL)"', 0
