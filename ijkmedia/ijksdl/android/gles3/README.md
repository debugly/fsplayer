# FSPlayer Android OpenGL ES 3 renderer

LGPL-2.1-or-later. New ES3 implementation; architectural reference:
Bilibili/ijkplayer's `renderer_yuv420p.c` and `ijksdl_egl.c` (Bilibili /
Zhang Rui, LGPL-2.1-or-later). HDR/tone-map and picture-adjust mathematics follow
FSPlayer's Vulkan/Metal shaders. Android baseline is API21 with a mandatory ES3
context. There is no ES2 context or extension-only CPU upload requirement.
Only the optional OES sampling shader may use ESSL100 on older ES3 drivers.

## Selecting the Android backend

Set the player option after construction and **before the first `prepareAsync()`**:

```java
FSPlayer player = new FSPlayer();
player.setOption(FSPlayer.OPT_CATEGORY_PLAYER, "video-renderer", "opengl");
// Other supported values: "auto" (default), "vulkan".
// Set the data source / display, then call prepareAsync().
```

- `auto`: API24+ tries Vulkan **with AHB external-memory support**. If AHB is
  absent, initialization is rejected, the Vulkan resources are destroyed, and a
  warning explains the ES3 fallback before decoder selection. Other Vulkan
  initialization failures also fall back to ES3. API21–23 uses ES3. The existing
  `debug.fsplayer.renderer` diagnostic override applies only to `auto`
  (`gles3` / `opengl` / `vulkan`); a Vulkan override does not bypass auto's AHB gate.
  The AHB requirement is auto-only: an explicit Vulkan request may still render
  software-decoded frames without AHB. AHB availability alone is not a complete
  MediaCodec capability or performance guarantee.
- `opengl` requires OpenGL ES 3. `vulkan` prefers Vulkan, but an unsupported API,
  unavailable driver or renderer/surface initialization failure logs a warning and
  falls back to ES3 before decoder selection. Both explicit values override the
  diagnostic property. HUD still reports the actual initialized backend, so a
  Vulkan request that falls back displays `OpenGL ES 3` on the HUD title line.
  Invalid option values or failure of every available backend still fail preparation.
- Backend resources are initialized during prepare, before decoder selection.
  Surface and rendering setters issued earlier are cached and replayed, including
  an owned copy of pending background-image pixels.
- An initialized native instance retained across stop/reprepare keeps its renderer
  and GPU ownership. Repeating native prepare with `auto` or the same backend does
  not recreate it; requesting a different explicit backend on that instance fails.
  Java `FSPlayer.reset()` releases and recreates the native instance: reapply the
  option before preparing again. Aura also does this when switching playlist URLs.
- Aura: `Settings` → `Choose Player` → `FSPlayer`, then `Video: FSPlayer` →
  `Video renderer`. The saved choice applies to the next new FSPlayer, not an
  existing playback session. SurfaceView/TextureView is a separate setting.
- FSPlayer's HUD reads native actual-backend property `20024`: `0` before
  successful initialization, `1` OpenGL ES 3, `2` Vulkan. It displays
  `Not initialized`, `OpenGL ES 3`, or `Vulkan` directly on its first/title line,
  with no separate `Renderer:` row. It does not echo the requested preference or
  assume Vulkan. Repeated refreshes replace that title rather than appending it.

`python3 android/tests/test_video_renderer_native.py` compiles the production vout
with instrumented backend/platform stubs. It checks lazy construction, explicit
selection and Vulkan/auto fallback, per-instance isolation, cached setters/surface/image
ownership, failure rollback/retry, reset retention and unsupported switching.
These control-flow tests are not real Vulkan or OpenGL rendering tests.

For an installed Aura debug APK and a moving SDR H264 clip on an Android target:

```sh
python3 android/tests/verify_renderer_fallback.py \
  --serial "$SERIAL" --video /data/local/tmp/fs-gles/baseline.mp4 \
  --output android/build/fallback-check --renderer auto --lifecycle
```

The integration probe requires adb and Pillow. Auto runs without diagnostic
backend overrides. `--renderer vulkan` instead tests explicit Vulkan with an
opposing GLES override. The probe requires a Vulkan failure/fallback warning
(except API21–23 auto, which selects ES3 directly), a decoded first frame, and
compares two captures' central video-only band (not HUD text).
Both nonblack pixels and changing video pixels must exceed 2%. It also requires
300 consumed OES frames with zero CPU video uploads. `--lifecycle` follows an invalid
option with delayed direct release and reset/recovery; neither may block. Screenshots
and logs stay local. Emulator codec/OES success does not establish physical GPU
hardware decoding or Vulkan success on a supported driver.

## Integration and lifetime

- Compile `fs_gles_renderer.c`, link `EGL`, `GLESv3`, `android`, `log`, `m`,
  FFmpeg `avcodec` / `avutil` / `swscale`, existing Android SDL JNI thread glue,
  and the existing platform-neutral SDL_GPU
  lifecycle and rectangle helpers. Public functions mirror the Vulkan renderer
  except its Vulkan-specific `context()` export. `FSScalingMode` and
  `FSSnapshotType` come from the existing Vulkan header (no Vulkan dependency).
- `create()` creates a strict ES3 EGL context and a 1x1 pbuffer immediately.
  Video upload, subtitle composition and snapshots work without a window.
  `set_surface()` retains the window, transactionally replaces the window surface,
  and accepts NULL to detach. The current surface size is queried on each present.
- `get_gpu()` publishes a single SDL_GPU shell owned by the player; call
  `SDL_GPUFreeP` exactly once. Repeated getters do not create extra shells.
  `detach_gpu()` clears that shell's opaque pointer without freeing the shell.
  `destroy()` also detaches defensively; a never-published shell is reclaimed.
- Texture and FBO callbacks retain a small renderer/mutex shell. EGL resources
  disappear on renderer destruction; late overlay releases then only free CPU
  state. A retained FBO output texture owns its texture independently of the FBO
  wrapper, so releasing the FBO cannot invalidate an already-published overlay.
- All renderer state and GPU callbacks use one recursive mutex. A balanced
  `beginDraw` / `drawTexture` / `endDraw` subtitle batch must run on one thread;
  the mutex stays locked across the batch to prevent presenting partial glyphs.
  **EGL is still unbound between every callback/public GL call**, not held across
  the batch. Do not carry a batch into shutdown. Stop/join producers before
  destroying their renderer or SDL_GPU shell, as with other SDL backends.
- Existing shared SDL texture reference helpers are provided elsewhere in the
  project. For externally concurrent Retain/Release, those shared helpers must
  provide atomic reference counts; GPU callback locking cannot serialize a
  generic helper's pre-callback reference decrement.

## Rendering

- Direct YUV420P / YUVJ420P, YUV420P10LE and NV12 upload. Odd dimensions, padded
  rows and negative strides are supported. Other software pixel formats use
  swscale. Hardware-frame memory is never treated as CPU-readable video data.
- Immutable reusable plane storage (`glTexStorage2D`), static VBO/VAO and a
  three-slot PBO ring. Uploads use core `glMapBufferRange` WRITE + INVALIDATE,
  orphaned storage and `GLsync`; busy storage is not mapped unsynchronized.
  There is no per-frame `glFinish`, blocking GPU wait, or ES3.1 requirement.
- 10-bit planes use core `R16UI` with explicit bilinear filtering; no mandatory
  `EXT_texture_norm16` or `EXT_buffer_storage`. Eight-bit planes use R8/RG8.
- Full/limited-range BT.601/709/2020-NCL matrices; PQ/HLG -> SDR tone mapping,
  orthographic XYZ rotation, metadata rotation, SAR, aspect-fit/fill/stretch,
  brightness/saturation/contrast, solid/image backgrounds and cached separable
  Gaussian blur. Background sigma/iteration changes only regenerate the cache.
  Caller-supplied RGBA backgrounds should be downsampled to longest side 400,
  matching the existing Java API. Blur sigma is bounded at 64 and iterations
  at 32. BT.2020-CL metadata uses the NCL compatibility matrix, not a separate
  constant-luminance reconstruction.
- Premultiplied ASS BGRA is converted to RGBA on upload; PAL8/A8's 0xAARRGGBB
  palette is expanded with alpha premultiplication when composited. Palette
  changes on an existing A8 overlay are honored. Both subtitle composition and
  final overlay use ONE / ONE_MINUS_SRC_ALPHA blending. Video adjustments do not
  alter subtitles or background colors.

## Snapshots

`take_snapshot()` is a blocking request consumed by the next `display()` or
`display_sub_overlay()` call, **not GL work performed on the requesting thread**.
The caller must release any vout lock needed by that render call. Keep the render
pump alive while paused if snapshots must work then. A request times out after
three seconds, and shutdown wakes waiters with failure. Concurrent requests are
rejected, not silently overwritten. Returned RGBA is top-down, tightly packed,
`malloc`-owned by the caller.

- ORIGIN: coded dimensions, no subtitle, no display transform/color adjustment.
- SCREEN: current surface dimensions (coded dimensions headlessly), full scene.
- EFFECT_ORIGIN: coded dimensions + subtitle, no display/color effects.
- EFFECT_SUBTITLE_ORIGIN: subtitle + rotation/color effects; dimensions swap at
  odd quarter turns, matching the existing Vulkan snapshot contract.
- HDR -> SDR conversion is mandatory on the SDR render target in every type.

## MediaCodec zero-CPU-copy (SDR)

- The internal package-private Java `FSGLESCodecSurface` owns a `SurfaceTexture`,
  decoder `Surface`, and dedicated callback `HandlerThread`. Both decoder objects
  and the external texture survive `set_surface(NULL)` and window recreation;
  they are released only at renderer destruction, after codec/render producers stop.
  No public FSPlayer Java API is added.
- Create the renderer during preparation after applying the player's options,
  before opening a decoder. Native caches a global app helper class and method
  IDs on that initial Java-to-native prepare call; decode/render native threads
  only use those cached references and attach via `SDL_JNI_SetupThreadEnv`.
  JNI failures are described, cleared and reported as unavailable/failure.
  Shrinking builds must keep the helper's JNI names, for example:

  ```proguard
  -keep class com.debugly.fsplayer.player.FSGLESCodecSurface { *; }
  ```

- Capability requires actual extension discovery, shader compile/link, external
  texture setup and live Java Surface creation. Prefer
  `GL_OES_EGL_image_external_essl3` + `#version 300 es`; legacy
  `GL_OES_EGL_image_external` can use an isolated ESSL100 sampling program **in
  the same ES3 context**, with attribute location explicitly bound before link.
  Neither shader compiling means software fallback, not fake hardware support.
  Extension discovery primarily uses `glGetStringi`; a diagnosed indexed-query
  failure permits exact-token GLES extension-string fallback and logs the cause.
- A hardware AVFrame's `data[3]` is released to the decoder Surface exactly once
  using `av_mediacodec_release_buffer(..., 1)`. Retaining the last AVFrame prevents
  its buffer address from being recycled and recognizes cloned/paused redisplays.
  Frame callbacks only signal; a bounded 500ms wait and `updateTexImage` /
  `getTransformMatrix` run on the serialized, EGL-current render thread.
  Paused redisplay/subtitle/snapshot calls sample the already-latched OES image:
  no second buffer release and no wait for a nonexistent next callback.
- Rendering directly samples `GL_TEXTURE_EXTERNAL_OES`. There is no CPU video
  upload, frame readback, intermediate RGBA copy, or per-frame texture allocation.
  SurfaceTexture crop/producer transform is applied after conversion from the
  renderer's top-down UV convention. The same scene handles video rotation,
  SAR/scaling, picture adjustments, subtitle composition and all snapshot types.
  A requested snapshot remains the only `glReadPixels` path.
- The SurfaceTexture RGB conversion is platform-owned for SDR YUV/color range.
  **Do not select this hardware path for HDR/BT.2020**: codec selection must
  fall back to software before opening the decoder. Native rendering also rejects
  BT.2020 primaries/matrices, PQ and HLG instead of falsely reporting tone mapping.
  Software rendering retains the existing HDR-to-SDR shaders.
- A release failure, callback timeout or GL/update exception is a rendering error;
  the hardware capability is disabled until renderer recreation. This avoids
  associating a late callback with a later released frame. There is no silent
  runtime reconfiguration of a live MediaCodec decoder.
- `FSGLESRenderer` logs `OES setup` once per renderer (extension flags, actual shader
  version 100/300, and Java capability), then actual `oes_frames` and `cpu_uploads`
  on the first/each 300th frame and at destruction. Actual hardware verification
  requires growing `oes_frames` with `cpu_uploads=0`, decoded MediaCodec selection,
  and visible/readable changing content; capability logs alone are not proof.

## Explicit limitations
- The RGBA8 EGL configuration is SDR. HDR direct-display capability is always
  false; `allow_hdr_display` is remembered but cannot enable an unsupported
  colorspace. Accepted HDR content uses software decode plus tone mapping;
  hardware HDR/BT.2020 must be rejected before opening MediaCodec.
- Context loss is reported as rendering failure; recreate the renderer after
  EGL_CONTEXT_LOST. Window BAD_SURFACE/BAD_NATIVE_WINDOW errors invalidate that
  EGL surface so `set_surface()` can bind the window again. This backend does
  not own Java activity/window lifecycle.
- Public GL calls leave no current context behind; they do not restore an
  unrelated caller-owned current EGL context. Call on renderer-owned threads.

## Reproducible checks

From the repository root:

```sh
python3 ijkmedia/ijksdl/android/gles3/tests/native_check.py --api 21
python3 ijkmedia/ijksdl/android/gles3/tests/host_check.py
python3 ijkmedia/ijksdl/android/gles3/tests/java_check.py
python3 ijkmedia/ijksdl/android/gles3/tests/extension_check.py
python3 ijkmedia/ijksdl/android/gles3/tests/mediacodec_contract_check.py
```

`native_check.py` compiles the production renderer **including real JNI/OES code**
with NDK API21, `-Wall -Wextra -Werror`, for arm64-v8a, armeabi-v7a, x86_64 and x86.
It additionally compiles JNI-disabled standalone Android pbuffer harnesses against
real FFmpeg static libraries (no JVM/player JNI exists in a shell executable).
It prints executable paths in the Hermes scratch directory; it does not run adb
or install an APK. `--abi arm64-v8a` limits the ABI. `ANDROID_NDK_HOME` can override
its default NDK location.

`host_check.py` runs those same real renderer tests against the Android SDK's
macOS host ANGLE/Metal EGL/GLES libraries and Homebrew FFmpeg, with ASan + UBSan.
Only Android window/log glue is shimmed; shaders, EGL, GL, PBO uploads, FBOs,
readback and FFmpeg are real. `ANGLE_LIB_DIR` and `FFMPEG_PREFIX` override defaults.
The `.inc` harness suffix deliberately keeps it out of production CMake C globs.

Checks include odd/padded/negative-stride YUV420P/NV12/10-bit, full/limited range,
BT.601/709/2020 + PQ/HLG versus CPU reference pixels, nonidentity B/S/C,
fit/fill/stretch/SAR/XYZ, BGRA and changing A8 palettes, premultiplied FBO blending,
retained FBO outputs, snapshot effect isolation, blur/background rendering,
240 changing frame uploads with pixel readback, cross-thread EGL handoff,
multi-renderer display lifetime and late overlay release.

`java_check.py` compiles the actual package-private helper with Java 8 source/
target compatibility and runs callback-before-wait, delayed callback, timeout,
interruption, shutdown-wakeup and idempotent resource-release tests. Its Android
classes are JVM stubs: this tests synchronization/lifetime, **not BufferQueue/GL
or hardware zero-copy**. `JAVA_HOME` overrides the Android Studio JBR default.
`extension_check.py` narrowly stubs extension queries to reproduce broken indexed
enumeration and tests error recovery plus token boundaries. The static contract
check catches accidental removal of the hardware path; neither is a device test.

Host GL execution and native compilation/linking are not Android window/device
verification. APK integration, window recreation tests and device playback belong
to the parent integration task. On a real emulator/device, force GLES3 and enable
MediaCodec, then verify a 100/300 shader, `mediacodec=1`, growing `oes_frames` with
`cpu_uploads=0`, changing decoded content, all four snapshot modes, pause/snapshot,
seek, and window detach/rebind without decoder Surface reconfiguration. Repeat
with hardware disabled to verify CPU upload counters and software regression.
Use asymmetric labeled/quadrant content for crop/orientation comparisons; a
successful callback or black snapshot is not sufficient evidence.
