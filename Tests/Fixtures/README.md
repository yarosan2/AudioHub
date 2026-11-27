# Test fixtures

Recorded from real devices and checked by `audiohub selftest`. Keep the bytes exact:
line endings are CRLF and must stay that way (see `.gitattributes`).

| File | Source | Edits |
| --- | --- | --- |
| `chromecast-get.http` | The HTTP request a Google Cast speaker (CrKey 1.52, Xiaomi Mi Smart Speaker) sends to fetch the WAV stream. Recorded with `AUDIOHUB_DUMP_HTTP_DIR=<dir> ./run.sh route <app>=cast:<speaker>`. | Per-route token replaced with `0123456789abcdef0123456789abcdef`; the Mac's LAN address in `Host` replaced with `192.0.2.10` (documentation range). Everything else is byte-for-byte. |

Why this exists: an earlier parser looked for the end of the request line with
`prefix { $0 != "\r" }`. In Swift `"\r\n"` is a single Character, so that never stopped, and
any request **with headers** — i.e. every real one — was rejected with 400, while
hand-written test requests without headers passed.

To record a new fixture, run the command above, then make the same two edits.
