#!/usr/bin/env python3
"""Real Android integration check: Vulkan request -> ES3 -> moving video pixels.

Requires adb and Pillow. Install the current Aura debug APK first, then run:
  python3 android/tests/verify_renderer_fallback.py --serial <emulator> \
      --video /data/local/tmp/fs-gles/baseline.mp4 --output <evidence-dir>
The video must be a moving SDR H264 clip long enough to consume 300 frames.
--lifecycle also checks direct release/reset after an invalid option. Only the
com.debugly.aura.debug test application is controlled; no app data is cleared.
Evidence stays local. Emulator codec/OES success is not silicon hardware proof.
"""
import argparse
import io
import json
import re
import shlex
import subprocess
import time
from pathlib import Path
from PIL import Image

PKG = "com.debugly.aura.debug"
ACTIVITY = PKG + "/com.debugly.aura.testing.MainActivity"


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--serial", required=True)
    ap.add_argument("--video", required=True)
    ap.add_argument("--output", required=True, type=Path)
    ap.add_argument("--lifecycle", action="store_true")
    ap.add_argument("--renderer", choices=("auto", "vulkan"), default="vulkan")
    args = ap.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)

    def adb_bytes(*words):
        r = subprocess.run(["adb", "-s", args.serial, *words],
                           capture_output=True, check=True, timeout=20)
        return r.stdout

    def adb(*words):
        return adb_bytes(*words).decode("utf-8", "replace")

    def prop(value):
        adb("shell", "setprop debug.fsplayer.renderer " + shlex.quote(value))
        assert adb("shell", "getprop", "debug.fsplayer.renderer").strip() == value

    def logs():
        text = adb("logcat", "-d", "-v", "threadtime", "-t", "4000")
        return "\n".join(line for line in text.splitlines()
                         if len(line.split()) >= 3 and line.split()[2] == pid)

    def wait_for(predicate, timeout=15):
        until = time.monotonic() + timeout
        while time.monotonic() < until:
            text = logs()
            assert "Fatal signal" not in text and "FATAL EXCEPTION" not in text, text[-3000:]
            if predicate(text):
                return text
            time.sleep(.5)
        raise AssertionError("Timed out waiting for playback/lifecycle condition: " + logs()[-3000:])

    def launch(renderer, lifecycle=None):
        nonlocal pid
        adb("shell", "am", "force-stop", PKG)
        words = ["shell", "am", "start", "-n", ACTIVITY,
                 "--es", "url", args.video, "--es", "videoRenderer", renderer,
                 "--ei", "hud", "1", "--ei", "mediacodec", "1", "--ei", "ndkCodec", "1"]
        if lifecycle:
            words += ["--es", "lifecycleAction", lifecycle]
        adb(*words)
        for _ in range(20):
            rows = [row.split() for row in adb("shell", "ps").splitlines()]
            found = [row[1] for row in rows if row and row[-1] == PKG]
            if found:
                pid = found[0]
                return
            time.sleep(.1)
        raise AssertionError("Test application process did not start")

    def capture(name):
        data = adb_bytes("exec-out", "screencap", "-p")
        (args.output / name).write_bytes(data)
        return Image.open(io.BytesIO(data)).convert("RGB")

    pid = ""
    saved_property = adb("shell", "getprop", "debug.fsplayer.renderer").strip()
    report = {}
    try:
        # Auto is tested without diagnostic overrides; explicit Vulkan must beat GLES.
        prop("" if args.renderer == "auto" else "gles3")
        launch(args.renderer)
        api = int(adb("shell", "getprop", "ro.build.version.sdk").strip())
        needs_warning = args.renderer != "auto" or api >= 24
        text = wait_for(lambda t: (not needs_warning or "fallback to OpenGL ES 3" in t)
                        and "FSPlayer render backend: OpenGL ES 3" in t
                        and "Video: first frame decoded" in t)
        print("PASS: " + args.renderer + " -> Vulkan unavailable -> logged ES3 fallback -> first frame", flush=True)
        time.sleep(4)
        before = capture("fallback-before.png")
        time.sleep(2)
        after = capture("fallback-after.png")
        assert before.size == after.size
        w, h = before.size
        # Central video-only band: do not count HUD clocks/text as moving video.
        box = (w // 8, h * 9 // 20, w * 7 // 8, h * 11 // 20)
        raw_a = before.crop(box).tobytes()
        raw_b = after.crop(box).tobytes()
        a = list(zip(raw_a[0::3], raw_a[1::3], raw_a[2::3]))
        b = list(zip(raw_b[0::3], raw_b[1::3], raw_b[2::3]))
        nonblack = sum(max(pixel) > 16 for pixel in b) / len(b)
        changed = sum(max(abs(x-y) for x, y in zip(p, q)) > 16
                      for p, q in zip(a, b)) / len(a)
        assert nonblack > .02, ("video region is black", nonblack)
        assert changed > .02, ("video pixels are not changing", changed)
        report.update(nonblack_ratio=nonblack, changed_video_pixel_ratio=changed,
                      api=adb("shell", "getprop", "ro.build.version.sdk").strip())
        print("PASS: nonblack video %.2f%%; changing video pixels %.2f%%" %
              (nonblack*100, changed*100), flush=True)
        text = wait_for(lambda t: "oes_frames=300 cpu_uploads=0" in t, timeout=45)
        assert "video-renderer initialization failed" not in text
        (args.output / "fallback.log").write_text(text)
        report["oes_frames"] = 300
        report["cpu_uploads"] = 0
        print("PASS: fallback renderer consumed 300 real OES frames, zero CPU video uploads", flush=True)
        adb("shell", "input", "keyevent", "4")
        if args.lifecycle:
            for action in ("release", "reset"):
                launch("invalid-backend", action)
                text = wait_for(lambda t: "ijkmp_prepare_async()=-22" in t
                                and "lifecycle completed: " + action in t)
                assert "lifecycle failed:" not in text
                if action == "reset":
                    text = wait_for(lambda t: "lifecycle completed: reset" in t
                                    and "Video: first frame decoded" in t)
                (args.output / ("invalid-" + action + ".log")).write_text(text)
                print("PASS: invalid option -> delayed direct " + action +
                      (" -> playback recovered" if action == "reset" else " completed"), flush=True)
            adb("shell", "input", "keyevent", "4")
            report["invalid_option_release_reset"] = "passed"
        (args.output / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    finally:
        if pid:
            (args.output / "last-process.log").write_text(logs())
        adb("shell", "am", "force-stop", PKG)
        prop(saved_property)


if __name__ == "__main__":
    main()
