# Testing AudioHub

## Automated checks

```bash
./build.sh
build/AudioHub.app/Contents/MacOS/audiohub selftest
```

No speakers or permissions needed. Run it from the repository root (it reads
`Tests/Fixtures/`), or pass `--fixtures <dir>`. A missing fixture fails the run. Covers:

| Area | What is checked |
| --- | --- |
| Lock-free ring | overflow, wrap-around, 20 M values across two threads arrive complete and in order |
| HTTP stream server | request validation (token path, method, client IP, malformed); a live loopback server: 403 before the speaker is known, 200 + WAV header for it, 404/403 otherwise, oversized requests, refusal after stop |
| Recorded fixtures | `Tests/Fixtures/chromecast-get.http` — the exact request a real Chromecast sends — must stay intact, pass validation, and get 200 + WAV from a live server (see `Tests/Fixtures/README.md`) |
| Cast framing | frames split/merged across reads, 64 KiB limit, oversized length rejected from the header alone |
| RTSP | parser (binary bodies, partial bodies); a scripted fake server: split responses, out-of-order replies to concurrent requests, a late reply after a timeout, peer close, non-200 |
| AirPlay resend | ranges across the 16-bit sequence wrap, reply format, too-old packets, capped counts |
| Stereo delay | sample-exact delay, click-free delay changes (with a control run proving the check detects a jump), rapid changes |
| ALAC | uncompressed frame layout and round-trip |

### Recording a fixture from a real device

```bash
AUDIOHUB_DUMP_HTTP_DIR=/tmp/http ./run.sh route <app>=cast:<speaker> --seconds 10
```

Every incoming request is saved byte for byte; anonymize it as described in
`Tests/Fixtures/README.md` before committing.

### Under ThreadSanitizer

```bash
SWIFTFLAGS="-sanitize=thread -Onone" ./build.sh
DYLD_LIBRARY_PATH="$(dirname "$(find /Library/Developer/CommandLineTools/usr/lib/clang -name 'libclang_rt.tsan_osx_dynamic.dylib' | head -1)")" \
  build/AudioHub.app/Contents/MacOS/audiohub selftest
./build.sh   # rebuild normally afterwards
```

Expected: all checks pass, no `WARNING: ThreadSanitizer`.

## Manual checks with real speakers

Use a long, steady source (a music stream, or `say -o test.aiff "…"` + `afplay`).
`AUDIOHUB_DEBUG=1 ./run.sh route <app>=<dest> --seconds 30` prints protocol details.

### Chromecast
1. Route an app to a Chromecast speaker. **Expect:** the app goes silent on the Mac within
   a second; the speaker starts within ~2–9 s; the log shows `HTTP 200 ← <speaker IP>`.
2. While it plays, from another machine on the LAN:
   `curl -v http://<mac-ip>:<port>/stream.wav` and the full URL with the token.
   **Expect:** 404 / 403 — never audio.
3. Stop the route. **Expect:** the port no longer accepts connections.

### AirPlay
1. Route an app to an AirPlay speaker for a few minutes. **Expect:** no dropouts; the stats
   line shows ~125 packets/s, `errors 0`.
2. Packet loss: `AUDIOHUB_DROP_EVERY=50 ./run.sh route <app>=airplay:<name> --seconds 20`.
   **Expect:** `resend requests N → resent N` with N ≈ dropped packets, and no audible gaps.
3. Power-cycle or unplug the speaker mid-stream. **Expect:** AudioHub reports the failure;
   it does not hang, and other routes keep playing.

### Stereo pair
1. Pair two speakers, turn on calibration clicks, line them up.
2. Drag the offset slider back and forth with music playing. **Expect:** the sound shifts
   without clicks or pops.
3. Leave it playing for an hour; note how far it drifts (re-check with the clicks).

### Volume
1. Move a speaker's slider. **Expect:** the speaker's own volume changes immediately.
2. Change the volume on the speaker itself (Chromecast). **Expect:** the slider follows.
3. Master volume and mute scale every route and keep their balance.
