#!/usr/bin/env python3
"""Static hardware-path safety regression, NOT a hardware/zero-copy execution test."""
from pathlib import Path
directory = Path(__file__).resolve().parent.parent
source = (directory/'fs_gles_renderer.c').read_text() + (directory/'fs_gles_mediacodec.inc').read_text()
assert 'samplerExternalOES' in source, 'missing real GLES external-texture shader'
assert 'GL_OES_EGL_image_external :' in source and 'glBindAttribLocation' in source, 'missing ES3-context legacy OES shader fallback with fixed attribute location'
assert 'GL_OES_EGL_image_external_essl3' in source, 'ESSL3 capability must be gated'
assert 'glGetStringi' in source, 'ES3 extension enumeration required'
assert 'av_mediacodec_release_buffer' in source, 'missing MediaCodec render release'
assert 'f->data[3]' in source, 'MediaCodec buffer must use AVFrame.data[3]'
assert 'mc_last' in source and 'av_frame_ref' in source, 'redisplay must retain buffer identity'
assert 'SDL_JNI_SetupThreadEnv' in source, 'native threads must attach to VM'
assert source.count('glReadPixels(') == 1, 'CPU readback must remain snapshot-only'
assert 'oes_frames=' in source and 'cpu_uploads=' in source, 'device path diagnostics required'
print('Static MediaCodec safety contract PASS (not device verification)')
