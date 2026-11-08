/* SPDX-License-Identifier: LGPL-2.1-or-later
 * Private implementation included by fs_gles_renderer.c (not a separate TU).
 */
static int has_extension(const char *wanted)
{
    GLint count = 0;
    glGetIntegerv(GL_NUM_EXTENSIONS, &count);
    GLenum error = glGetError();
    if (error == GL_NO_ERROR && count >= 0 && count < 65536) {
        int complete = 1;
        for (GLint i = 0; i < count; ++i) {
            const char *name = (const char *)glGetStringi(GL_EXTENSIONS, (GLuint)i);
            error = glGetError();
            if (error != GL_NO_ERROR || !name) {
                LOGE("indexed GL extensions failed at %d/%d (0x%x); checking ES extension string",
                     i, count, error);
                complete = 0;
                break;
            }
            if (!strcmp(name, wanted))
                return 1;
        }
        if (complete)
            return 0;
    } else {
        LOGE("GL_NUM_EXTENSIONS failed: count=%d error=0x%x; checking ES extension string", count, error);
    }
    /* Some old Android emulator translators return the host extension count
     * but reject indices beyond their filtered guest list with INVALID_VALUE.
     * GLES (unlike desktop core GL) still permits GL_EXTENSIONS via glGetString.
     * Only use this fallback after a diagnosed indexed-query failure. */
    const char *extensions = (const char *)glGetString(GL_EXTENSIONS);
    error = glGetError();
    if (error != GL_NO_ERROR || !extensions) {
        LOGE("GL extension string query failed: 0x%x", error);
        return 0;
    }
    size_t length = strlen(wanted);
    const char *match = extensions;
    while ((match = strstr(match, wanted))) {
        if ((match == extensions || match[-1] == ' ') &&
            (match[length] == ' ' || match[length] == '\0'))
            return 1;
        match += length;
    }
    return 0;
}
#ifdef FS_GLES_ANDROID_CODEC
static int mc_exception(JNIEnv *env, const char *where)
{
    if (!(*env)->ExceptionCheck(env))
        return 0;
    (*env)->ExceptionDescribe(env);
    (*env)->ExceptionClear(env);
    LOGE("MediaCodec JNI exception: %s", where);
    return 1;
}
static jobject mc_global(JNIEnv *env, jobject local)
{
    if (mc_exception(env, "create local") || !local)
        return NULL;
    jobject global = (*env)->NewGlobalRef(env, local);
    int error = mc_exception(env, "retain global");
    (*env)->DeleteLocalRef(env, local);
    return error ? NULL : global;
}
static void mc_cleanup(FSGLESRenderer *r)
{
    JNIEnv *env = NULL;
    if (!r->mc_class && !r->mc_helper && !r->mc_surface && !r->mc_matrix)
        return;
    if (SDL_JNI_SetupThreadEnv(&env) != JNI_OK || !env) {
        LOGE("MediaCodec cleanup: VM attachment failed");
        return;
    }
    if (r->mc_helper && r->mc_release) {
        (*env)->CallVoidMethod(env, r->mc_helper, r->mc_release);
        mc_exception(env, "release");
    }
    if (r->mc_surface) (*env)->DeleteGlobalRef(env, r->mc_surface);
    if (r->mc_matrix) (*env)->DeleteGlobalRef(env, r->mc_matrix);
    if (r->mc_helper) (*env)->DeleteGlobalRef(env, r->mc_helper);
    if (r->mc_class) (*env)->DeleteGlobalRef(env, r->mc_class);
    r->mc_surface = r->mc_helper = NULL;
    r->mc_class = NULL;
    r->mc_matrix = NULL;
}
static int mc_init(FSGLESRenderer *r)
{
    JNIEnv *env = NULL;
    if (!r->oes || SDL_JNI_SetupThreadEnv(&env) != JNI_OK || !env)
        return 0;
    /* create() runs during Java native player creation, before decode threads.
     * Retain this app class here; FindClass on attached native threads cannot
     * resolve the app's loader. No class lookup occurs while rendering. */
    r->mc_class = (jclass)mc_global(env, (*env)->FindClass(env,
        "com/debugly/fsplayer/player/FSGLESCodecSurface"));
    if (!r->mc_class)
        goto fail;
    jmethodID ctor = (*env)->GetMethodID(env, r->mc_class, "<init>", "(I)V");
    if (mc_exception(env, "constructor lookup") || !ctor) goto fail;
    r->mc_release = (*env)->GetMethodID(env, r->mc_class, "release", "()V");
    if (mc_exception(env, "release lookup") || !r->mc_release) goto fail;
    r->mc_latch = (*env)->GetMethodID(env, r->mc_class, "latch", "([FI)Z");
    if (mc_exception(env, "latch lookup") || !r->mc_latch) goto fail;
    jmethodID surface = (*env)->GetMethodID(env, r->mc_class, "getSurface", "()Landroid/view/Surface;");
    if (mc_exception(env, "surface lookup") || !surface) goto fail;
    glActiveTexture(GL_TEXTURE0);
    glGenTextures(1, &r->external);
    glBindTexture(GL_TEXTURE_EXTERNAL_OES, r->external);
    glTexParameteri(GL_TEXTURE_EXTERNAL_OES, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_EXTERNAL_OES, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_EXTERNAL_OES, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_EXTERNAL_OES, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    if (!r->external || glGetError() != GL_NO_ERROR) goto fail;
    jobject helper = (*env)->NewObject(env, r->mc_class, ctor, (jint)r->external);
    if (mc_exception(env, "helper constructor") || !helper) goto fail;
    r->mc_helper = (*env)->NewGlobalRef(env, helper);
    int retain_error = mc_exception(env, "helper global ref");
    if (retain_error || !r->mc_helper) {
        /* Constructor already owns a running thread/Surface. Even if retaining
         * it fails (e.g. OOM), release through the still-valid local reference. */
        (*env)->CallVoidMethod(env, helper, r->mc_release);
        mc_exception(env, "unretained helper release");
    }
    (*env)->DeleteLocalRef(env, helper);
    if (retain_error || !r->mc_helper) goto fail;
    r->mc_surface = mc_global(env, (*env)->CallObjectMethod(env, r->mc_helper, surface));
    if (!r->mc_surface) goto fail;
    r->mc_matrix = (jfloatArray)mc_global(env, (*env)->NewFloatArray(env, 16));
    r->mc_last = av_frame_alloc();
    if (!r->mc_matrix || !r->mc_last || glGetError() != GL_NO_ERROR) goto fail;
    return 1;
fail:
    LOGE("MediaCodec OES initialization failed; software decode remains available");
    mc_cleanup(r);
    return 0;
}
static int mc_upload(FSGLESRenderer *r, const AVFrame *f)
{
    if (!r->mc_surface || r->mc_failed || !f->data[3])
        return -1;
    /* SurfaceTexture's RGB conversion/color management is platform-dependent for
     * HDR/wide gamut. Never pretend this SDR-only path tone-maps those frames. */
    if (f->color_primaries == AVCOL_PRI_BT2020 || f->colorspace == AVCOL_SPC_BT2020_NCL ||
        f->colorspace == AVCOL_SPC_BT2020_CL || f->color_trc == AVCOL_TRC_SMPTE2084 ||
        f->color_trc == AVCOL_TRC_ARIB_STD_B67) {
        LOGE("MediaCodec OES rejects HDR/BT2020; select software decode before codec open");
        r->mc_failed = 1;
        return -1;
    }
    /* Retain the AVFrame, not just its pointer: paused redisplays can use cloned
     * frames, and a released buffer's address can otherwise be recycled. */
    if (r->mc_last->data[3] == f->data[3])
        return r->have_frame && r->format == AV_PIX_FMT_MEDIACODEC ? 0 : -1;
    JNIEnv *env = NULL;
    if (SDL_JNI_SetupThreadEnv(&env) != JNI_OK || !env)
        return -1;
    av_frame_unref(r->mc_last);
    if (av_frame_ref(r->mc_last, f) < 0)
        return -1;
    /* There is exactly one outstanding producer frame. Callback runs on its
     * HandlerThread and only signals; updateTexImage executes here, EGL-current. */
    AVMediaCodecBuffer *buffer = (AVMediaCodecBuffer *)f->data[3];
    if (av_mediacodec_release_buffer(buffer, 1) < 0) {
        LOGE("MediaCodec render release failed");
        r->mc_failed = 1;
        return -1;
    }
    jboolean ready = (*env)->CallBooleanMethod(env, r->mc_helper, r->mc_latch,
                                              r->mc_matrix, (jint)500);
    if (mc_exception(env, "latch") || !ready) {
        LOGE("MediaCodec frame wait/update failed (500ms); renderer needs recreation");
        /* Do not issue another release against a queued/stale callback or wait
         * again on a paused redisplay. Report failure rather than false success. */
        r->mc_failed = 1;
        return -1;
    }
    (*env)->GetFloatArrayRegion(env, r->mc_matrix, 0, 16, r->tex_matrix);
    if (mc_exception(env, "transform matrix") || glGetError() != GL_NO_ERROR) {
        LOGE("MediaCodec update GL/matrix failure");
        r->mc_failed = 1;
        return -1;
    }
    for (int i = 0; i < 16; i++) {
        if (!isfinite(r->tex_matrix[i])) {
            r->mc_failed = 1;
            return -1;
        }
    }
    r->width = f->width;
    r->height = f->height;
    r->format = AV_PIX_FMT_MEDIACODEC;
    r->have_frame = 1;
    ++r->oes_frames;
    if (r->oes_frames == 1 || r->oes_frames % 300 == 0)
        LOGI("MediaCodec OES consumed: oes_frames=%lu cpu_uploads=%lu", r->oes_frames, r->cpu_uploads);
    return 0;
}
#else
static int mc_init(FSGLESRenderer *r) { (void)r; return 0; }
static void mc_cleanup(FSGLESRenderer *r) { (void)r; }
static int mc_upload(FSGLESRenderer *r, const AVFrame *f) { (void)r; (void)f; return -1; }
#endif
