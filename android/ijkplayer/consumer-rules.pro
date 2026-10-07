# ProGuard/R8 rules for apps that consume the FSPlayer Android AAR.
#
# These rules ship inside the AAR (consumerProguardFiles) and are applied
# automatically by AGP when the consumer enables minification.
#
# Why they are required: libijkplayer.so has Java member *names* baked into it.
#   * JNI_OnLoad registers 24 methods via RegisterNatives by name+signature
#     (_prepareAsync, _start, _stop, _release, _setDataSource, seekTo, getDuration,
#      isPlaying, setVolume, getCurrentPosition, getAudioSessionId, native_init, ...),
#     so the Java names on IjkMediaPlayer must match the table in the .so exactly.
#   * At runtime the native side calls back into Java with GetStaticMethodID
#     (postEventFromNative, postAudioSamplesEventFromNative, onNativeInvoke,
#     onSelectCodec) and reads FSSubtitlePreference fields with GetFieldID
#     (Scale, BottomMargin, ForceOverride, FontName, PrimaryColour, SecondaryColour,
#      BackColour, OutlineColour, Outline, FontsDir).
#   * IMediaDataSource / IAndroidIO implementations live in the consuming app and are
#     called by the native side through the interface name + method name.
# Renaming any of those makes native registration or the callbacks silently fail
# (symptom: prepare never completes / no first frame), so keep them verbatim.

# 1. JNI entry point: class name and every member name must survive
#    (the RegisterNatives table in ijkplayer_jni.c lists these by name).
-keep class tv.danmaku.ijk.media.player.IjkMediaPlayer { *; }

# 2. Second native entry point (av_base64_encode).
-keep class tv.danmaku.ijk.media.player.ffmpeg.FFmpegApi { *; }

# 3. Subtitle style object: native code reads these fields by name.
-keep class tv.danmaku.ijk.media.player.FSSubtitlePreference { *; }

# 4. Interfaces implemented by the consumer app but invoked from native code
#    (the interface class name is looked up with FindClass and must stay).
-keep interface tv.danmaku.ijk.media.player.misc.IMediaDataSource { *; }
-keep interface tv.danmaku.ijk.media.player.misc.IAndroidIO { *; }

# 5. Library loader extension point.
-keep interface tv.danmaku.ijk.media.player.IjkLibLoader { *; }

# 6. Annotation-driven safety net: anything tagged as a native touchpoint stays.
-keep class tv.danmaku.ijk.media.player.annotations.** { *; }
-keepclasseswithmembers class * {
    @tv.danmaku.ijk.media.player.annotations.CalledByNative <methods>;
}
-keepclasseswithmembers class * {
    @tv.danmaku.ijk.media.player.annotations.AccessedByNative <fields>;
}

# 7. Belt and braces: keep the names of any native methods, even when the consumer
#    supplies its own proguard config without the Android default rule.
-keepclasseswithmembernames class * {
    native <methods>;
}
