# AudioHub

**Per-app audio routing for macOS — to local outputs, Chromecast and AirPlay speakers.**

[Русский](README.ru.md)

AudioHub lives in the menu bar and lets you choose, for every app, where its sound goes:
music to a Chromecast speaker, a web radio to an AirPlay speaker, system sounds stay on your
monitor. It can even turn two speakers of *different* protocols into a stereo pair.

No virtual audio drivers, no kernel extensions: it uses the Core Audio process taps that macOS
has had since 14.2.

## Features

- **Per-app routing** — every app that plays sound is listed; pick a destination for each:
  - outputs of this Mac (HDMI/DisplayPort, analog, USB…)
  - **Chromecast / Google Cast** speakers (Default Media Receiver, live WAV stream)
  - **AirPlay** speakers (RAOP, unencrypted; works with many AirPlay 2 speakers)
- The app is silenced on its original output while it is routed elsewhere.
- Helper processes are grouped with their app (browser tabs, Electron, Safari's WebKit audio).
- **Speaker volume** — for network speakers the slider sets the speaker's own volume.
- **Master volume and mute** for everything AudioHub plays.
- **Remembers routes** and re-applies them when the app starts playing again.
- **Cross-protocol stereo pair** — left channel to one speaker, right to another, with a delay
  line and calibration clicks to line them up by ear.
- Menu-bar app and a command-line mode.
- English, Russian and Ukrainian.

## Requirements

- macOS 14.2 or later (tested on macOS 26)
- Xcode Command Line Tools (`xcode-select --install`). Full Xcode is not required.

## Install

```bash
git clone <this repository>
cd AudioHub
scripts/make-signing-cert.sh   # once, see "Permissions" below
scripts/install.sh             # builds and copies AudioHub to /Applications
```

On first use macOS asks for two permissions:

1. **System audio recording**: *System Settings → Privacy & Security → Screen & System Audio
   Recording → System Audio Recording Only*. If AudioHub is not listed, add it with **+**.
2. **Local network**: needed to find and stream to speakers.

To start it at login: *System Settings → General → Login Items → +* → AudioHub.

### Permissions and signing

macOS remembers privacy permissions per code signature. An ad-hoc signed build gets a new
identity every time it is rebuilt, and macOS then silently revokes audio capture: the app
"works" but records silence. `scripts/make-signing-cert.sh` creates a self-signed certificate
*AudioHub Local Signing* in your login keychain; `build.sh` signs with it when it exists, so a
permission granted once survives rebuilds. The certificate is used for nothing else and can
be deleted in Keychain Access at any time.

## Usage

Click the speaker icon in the menu bar. Apps that are playing show a green waveform. Choose a
destination next to an app; the slider below it controls the volume.

**Latency:** network speakers play about 2 s (AirPlay) to 2–9 s (Chromecast) late. Fine for
music, not for video.

### Stereo pair

1. Open **Stereo pair** at the bottom of the menu and choose the left and right speakers.
2. Choose **Stereo pair** as the destination of an app.
3. Turn on **Calibration clicks**. Every second there is a click and every 10 seconds a long
   beep. First line up the beeps with `« »` (100 ms steps), then the clicks with `‹ ›` (10 ms).
4. Turn the clicks off and balance the two volumes.

Chromecast decides itself how much to buffer, and the two speakers run on different clocks, so
the alignment can drift — after a pause or rebuffering re-check it with the clicks.

### Command line

```bash
AUDIOHUB=/Applications/AudioHub.app/Contents/MacOS/audiohub
$AUDIOHUB list                        # apps with audio and local outputs
$AUDIOHUB speakers                    # Chromecast and AirPlay speakers
$AUDIOHUB route Spotify=cast:Bedroom Music=airplay:Kitchen
```

Run the CLI through `run.sh` (which launches the app bundle) if macOS blocks capture or the
network for a bare binary started from a terminal.

## How it works

```
app ──► Core Audio process tap (muted at its original output)
          │
          ▼
   private aggregate device (tap + clock device) ──► IO callback
          ├─► local output device
          ├─► Chromecast: 16-bit WAV over HTTP  ◄── speaker pulls the URL (Cast v2: LAUNCH + LOAD)
          ├─► AirPlay: RTSP (auth-setup, ANNOUNCE, SETUP, RECORD) + RTP/UDP,
          │            uncompressed ALAC @ 44.1 kHz, NTP timing replies, sync packets
          └─► stereo pair: L/R split ─► delay line ─► two of the above
```

| File | What it does |
| --- | --- |
| `Route.swift` | process tap + aggregate device + IO callback |
| `Inventory.swift` | audio processes and output devices |
| `Chromecast.swift` | Bonjour discovery, minimal Cast v2 sender (TLS + protobuf) |
| `StreamServer.swift` | live WAV HTTP server for Chromecast |
| `AirPlay.swift` | RAOP sender, resampling, ALAC framing, timing/sync |
| `StereoPair.swift` | channel splitter with delay line and calibration clicks |
| `Engine.swift` | routing state, persistence, volume |
| `MenuBarUI.swift` | SwiftUI menu-bar interface |

## Known limitations

- AirPlay speakers that require pairing or encryption (e.g. HomePod) are not supported.
- Chromecast latency is set by the speaker and cannot be lowered from the sender side.
- Safari's web audio comes from a WebKit process shared by all WebKit apps.
- On a Mac with two network interfaces on the same subnet AudioHub tries each in turn.

## License

MIT — see [LICENSE](LICENSE).
