#!/usr/bin/env python3
"""Host-executable prepare/release regression; NOT an Android/device test.

Run: python3 android/tests/test_prepare_failure_lifecycle.py
Production ijkplayer lifecycle functions, ffp_stop_l/ffp_wait_stop_l and the
complete message queue implementation are extracted and compiled unchanged.
Stub boundaries: reduced FFPlayer/VideoState layouts, FFmpeg allocation/logging,
SDL adapters backed by real pthreads, stream_close/toggle_pause, and synchronous
ffp_prepare_async_l fault injection (not real option parsing or GPU init). The
consumer uses the real blocking queue. A barrier ensures it is waiting before
prepare returns. Reset is modeled as shutdown/release then a fresh player, not
as execution of Java/JNI reset. Every compiler/child process has a short timeout;
subprocess.run kills and reaps blocked children. Temporary files stay in scratch.
"""
from pathlib import Path
import os
import re
import shlex
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
CORE = ROOT / "ijkmedia/ijkplayer"
SCRATCH = Path(os.environ.get("TMPDIR", str(Path.home() / ".hermes/cache/scratch")))


def function(source, name):
    """Extract a complete top-level production definition, not a replica."""
    match = re.search(
        r"^[\w *]+\b" + re.escape(name) + r"\([^;{}]*\)\s*\n\{.*?^\}",
        source, re.M | re.S,
    )
    if not match:
        raise AssertionError("Missing production function: " + name)
    return match.group(0)


PRELUDE = r'''
#include <assert.h>
#include <errno.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#define MPTRACE(...) ((void)0)
#define MPST_RET_IF_EQ(real, expected) do { \
    if ((real) == (expected)) return EIJK_INVALID_STATE; } while (0)
#define av_malloc malloc
#define av_free free
static void freep(void *p) { void **v = p; free(*v); *v = NULL; }
#define av_freep freep
typedef pthread_mutex_t SDL_mutex;
typedef pthread_cond_t SDL_cond;
static pthread_mutex_t barrier_mutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t barrier_cond = PTHREAD_COND_INITIALIZER;
static int consumer_waiting, joined, destroyed, prepare_result;
static SDL_mutex *SDL_CreateMutex(void) {
    SDL_mutex *m = malloc(sizeof(*m)); assert(m);
    assert(!pthread_mutex_init(m, NULL)); return m;
}
static SDL_cond *SDL_CreateCond(void) {
    SDL_cond *c = malloc(sizeof(*c)); assert(c);
    assert(!pthread_cond_init(c, NULL)); return c;
}
static void SDL_LockMutex(SDL_mutex *m) { assert(!pthread_mutex_lock(m)); }
static void SDL_UnlockMutex(SDL_mutex *m) { assert(!pthread_mutex_unlock(m)); }
static void SDL_CondSignal(SDL_cond *c) { assert(!pthread_cond_signal(c)); }
static void SDL_CondWait(SDL_cond *c, SDL_mutex *m) {
    assert(!pthread_mutex_lock(&barrier_mutex));
    consumer_waiting = 1;
    assert(!pthread_cond_signal(&barrier_cond));
    assert(!pthread_mutex_unlock(&barrier_mutex));
    assert(!pthread_cond_wait(c, m));
}
static void SDL_DestroyMutex(SDL_mutex *m) {
    assert(!pthread_mutex_destroy(m)); free(m);
}
static void SDL_DestroyCond(SDL_cond *c) {
    assert(!pthread_cond_destroy(c)); free(c);
}
typedef struct SDL_Thread {
    pthread_t id; int (*fn)(void *); void *arg;
} SDL_Thread;
static void *thread_entry(void *arg) {
    SDL_Thread *t = arg; t->fn(t->arg); return NULL;
}
static SDL_Thread *SDL_CreateThreadEx(SDL_Thread *t, int (*fn)(void *),
                                     void *arg, const char *name) {
    (void)name; t->fn = fn; t->arg = arg;
    assert(!pthread_create(&t->id, NULL, thread_entry, t)); return t;
}
static void SDL_WaitThread(SDL_Thread *t, int *status) {
    (void)status; assert(!pthread_join(t->id, NULL)); joined++;
}
'''

BOUNDARIES = r'''
typedef struct VideoState {
    int abort_request, audio_accurate_seek_req, video_accurate_seek_req;
    SDL_mutex *accurate_seek_mutex;
    SDL_cond *audio_accurate_seek_cond, *video_accurate_seek_cond;
} VideoState;
typedef struct FFPlayer {
    VideoState *is; MessageQueue msg_queue; int enable_accurate_seek;
} FFPlayer;
typedef struct IjkMediaPlayer IjkMediaPlayer;
static void toggle_pause(FFPlayer *ffp, int pause) { (void)ffp; (void)pause; }
static void stream_close(FFPlayer *ffp) { (void)ffp; }
static void ffp_destroy_p(FFPlayer **ffp) {
    msg_queue_destroy(&(*ffp)->msg_queue); free(*ffp); *ffp = NULL; destroyed++;
}
static void ffp_notify_msg2(FFPlayer *ffp, int what, int arg) {
    msg_queue_put_simple2(&ffp->msg_queue, what, arg);
}
static int ffp_prepare_async_l(FFPlayer *ffp, const char *source) {
    (void)source; assert(ffp->is == NULL);
    assert(!pthread_mutex_lock(&barrier_mutex));
    while (!consumer_waiting)
        assert(!pthread_cond_wait(&barrier_cond, &barrier_mutex));
    assert(!pthread_mutex_unlock(&barrier_mutex));
    return prepare_result;
}
'''

DRIVER = r'''
static int consumer(void *arg) {
    IjkMediaPlayer *mp = arg; AVMessage msg;
    while (msg_queue_get(&mp->ffplayer->msg_queue, &msg, 1) >= 0)
        msg_free_res(&msg);
    return 0;
}
static void lifecycle(int result, int explicit_shutdown) {
    consumer_waiting = 0; prepare_result = result;
    IjkMediaPlayer *mp = calloc(1, sizeof(*mp)); assert(mp);
    mp->ffplayer = calloc(1, sizeof(*mp->ffplayer)); assert(mp->ffplayer);
    assert(!pthread_mutex_init(&mp->mutex, NULL));
    mp->msg_loop = consumer; mp->ref_count = 1;
    msg_queue_init(&mp->ffplayer->msg_queue);
    assert(ijkmp_set_data_source(mp, "host-fault-injection") == 0);
    assert(ijkmp_prepare_async(mp) == result);
    assert(mp->ffplayer->is == NULL);
    assert(mp->mp_state == (result < 0 ? MP_STATE_ERROR : MP_STATE_ASYNC_PREPARING));
    if (result == 0) {
        assert(!mp->ffplayer->msg_queue.abort_request);
        ffp_stop_l(mp->ffplayer); /* Control: successful prepare still needs stop. */
    }
    printf("prepare=%d state=%d stream=NULL; releasing\n", result, mp->mp_state);
    fflush(stdout);
    if (explicit_shutdown) ijkmp_shutdown(mp);
    int before = joined;
    ijkmp_dec_ref_p(&mp); /* Production shutdown -> destroy -> real pthread join. */
    assert(mp == NULL && joined == before + 1 && destroyed == joined);
    printf("PASS: prepare=%d shutdown=%d joined=%d destroyed=%d\n",
           result, explicit_shutdown, joined, destroyed);
}
int main(int argc, char **argv) {
    assert(argc == 3);
    int result = atoi(argv[1]), reset = atoi(argv[2]);
    lifecycle(result, reset);
    if (reset) lifecycle(0, 1); /* Fresh native instance after modeled reset. */
    return 0;
}
'''


def translation_unit():
    player = (CORE / "ijkplayer.c").read_text()
    ffplay = (CORE / "ff_ffplay.c").read_text()
    constants = "\n".join(
        line for header in ("ijkplayer.h", "ff_ffmsg.h", "ff_fferror.h")
        for line in (CORE / header).read_text().splitlines()
        if re.match(r"#define (MP_STATE_\w+|EIJK_\w+|FFP_MSG_\w+)\s", line)
    )
    queue = re.sub(r'^#include .*$', '', (CORE / "ff_ffmsg_queue.h").read_text(), flags=re.M)
    layout_match = re.search(r"struct IjkMediaPlayer \{.*?^\};",
                             (CORE / "ijkplayer_internal.h").read_text(), re.M | re.S)
    if not layout_match:
        raise AssertionError("Missing production IjkMediaPlayer layout")
    layout = layout_match.group(0)
    ff_functions = "\n".join(function(ffplay, name) for name in
                               ("ffp_stop_l", "ffp_wait_stop_l"))
    # Dependency order only; every function body remains production source.
    player_functions = "\n".join(function(player, name) for name in (
        "ijkmp_destroy", "ijkmp_destroy_p", "ijkmp_change_state_l",
        "ijkmp_shutdown_l", "ijkmp_shutdown", "ijkmp_dec_ref", "ijkmp_dec_ref_p",
        "ijkmp_set_data_source_l", "ijkmp_set_data_source", "ijkmp_msg_loop",
        "ijkmp_prepare_async_l", "ijkmp_prepare_async"))
    return "\n".join((PRELUDE, constants, queue, BOUNDARIES, layout,
                       ff_functions, player_functions, DRIVER))


class PrepareFailureLifecycle(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        SCRATCH.mkdir(parents=True, exist_ok=True)
        cls.temp = tempfile.TemporaryDirectory(prefix="prepare-lifecycle-", dir=SCRATCH)
        cls.addClassCleanup(cls.temp.cleanup)
        source = Path(cls.temp.name) / "lifecycle.c"
        cls.binary = Path(cls.temp.name) / "lifecycle"
        source.write_text(translation_unit())
        subprocess.run(shlex.split(os.environ.get("CC", "cc")) + [
            "-std=c11", "-Wall", "-Wextra", "-Werror", "-Wno-unused-function",
            "-pthread", str(source), "-o", str(cls.binary)],
            check=True, capture_output=True, text=True, timeout=10)

    def run_lifecycle(self, result, reset):
        try:
            child = subprocess.run([str(self.binary), str(result), str(int(reset))],
                                   capture_output=True, text=True, timeout=2)
        except subprocess.TimeoutExpired as error:
            self.fail("message thread did not exit; release/reset join blocked "
                      "(child killed/reaped after 2s). stdout=" + repr(error.stdout))
        self.assertEqual(child.returncode, 0, child.stdout + child.stderr)
        self.assertIn("PASS:", child.stdout)
        print(child.stdout, end="", flush=True)

    def test_sync_failure_delayed_release(self):
        self.run_lifecycle(-22, False)  # Injected invalid-option-style return.

    def test_sync_failure_reset_then_new_prepare(self):
        self.run_lifecycle(-5, True)  # Injected renderer-init-style return.

    def test_success_not_aborted_by_prepare(self):
        self.run_lifecycle(0, False)


if __name__ == "__main__":
    unittest.main(verbosity=2)
