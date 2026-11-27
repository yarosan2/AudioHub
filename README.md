# AudioHub


**Per-app audio routing for macOS — to local outputs, Chromecast and AirPlay speakers.**

<img width="390" height="647" alt="Знімок екрана 2026-11-26 о 21 51 25" src="https://github.com/user-attachments/assets/85764a47-a6b8-4483-a068-ac4feaaed5d1" />

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

`install.sh` keeps the kind of build that is already installed: a release build (from GitHub
or the in-app updater) stays a release build so one-click updates keep working. Override with
`--release` or `--source`. It refuses to replace a newer installed version unless `--force`.
Or download the latest release.

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

## Updates

AudioHub checks GitHub once a day for a newer release (turn it off under the gear menu,
where you can also check manually). When one is available, the top of the menu says so.

- **Installed from a release zip:** click **Install**. AudioHub downloads the update, verifies
  it and restarts. Privacy permissions are kept, because every release is signed with the same
  certificate.
- **Built from source:** you only get a notice with a link; pull and run `scripts/install.sh`.

An update is installed only if all of these hold, otherwise nothing is changed:
the archive comes from GitHub, matches the size in the release, carries a valid Ed25519
signature from the project's release key (public half in `Info.plist`, private half never
leaves the maintainer's keychain), contains the same app (bundle identifier) with a newer
version, and that app's code signature is intact and from the same certificate as the
running copy. A compromised GitHub account alone therefore cannot push code to users.

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
| `StereoPair.swift` | channel splitter with crossfading delay line and calibration clicks |
| `SPSCRing.swift` | lock-free ring between the audio thread and the senders |
| `RTSP.swift` | RTSP client: one read loop, responses matched by CSeq |
| `Updater.swift` | update check, Ed25519 verification, code-identity check, installer |
| `SelfTest.swift` | `audiohub selftest` |
| `Engine.swift` | routing state, persistence, volume |
| `MenuBarUI.swift` | SwiftUI menu-bar interface |

## Security

AudioHub only talks to devices on your local network.

- **Chromecast stream.** The speaker fetches audio over HTTP from the Mac, so a port is open
  on the LAN while a route is active. Each route uses a random 128-bit URL token, only
  GET/HEAD on that exact path is served, and only to the IP address of the speaker the URL
  was sent to. The port closes when the route stops.
- **Chromecast control (TLS).** Cast devices use short-lived self-signed certificates, so
  AudioHub accepts any certificate on port 8009 and does not yet implement Cast device
  authentication. Someone who can intercept traffic on your LAN could impersonate a speaker:
  see which stream URL it is given and receive volume commands. Do not rely on AudioHub on
  untrusted networks.
- **AirPlay** is unencrypted (RAOP with `et=0`): audio and volume commands travel in the
  clear on the LAN.

## Development

### Releasing

```bash
# bump CFBundleShortVersionString in Info.plist, commit, then:
scripts/release.sh 0.2.1
```

Builds a release build, runs the self-test, writes `build/AudioHub-<version>.zip` and its
`.zip.sig`. Attach both to a GitHub release tagged `v<version>`. Signing needs the release key
in the keychain (`audiohub update-keygen` creates it once and prints the public key for
`AHUpdatePublicKey`) and the *AudioHub Local Signing* certificate.

### Rotating the release key

Installed copies trust only the key embedded in them, so a new key is introduced through a
*transition release* that is signed with the current key but carries the new one:

```bash
build/AudioHub.app/Contents/MacOS/audiohub update-keygen --rotate   # prints the new public key
# put it into Info.plist as AHUpdatePublicKey, bump the version, commit
scripts/release.sh <version>        # signs with the current key, reports "TRANSITION RELEASE"
# publish that release, then:
build/AudioHub.app/Contents/MacOS/audiohub update-keygen --finish-rotation   # new key active, old deleted
```

Back up the key only from a separate Terminal window, never paste it anywhere.

```bash
./build.sh                                          # build build/AudioHub.app
build/AudioHub.app/Contents/MacOS/audiohub selftest # automated checks, no speakers needed
```

See [TESTING.md](TESTING.md) for what the checks cover, the ThreadSanitizer run, and manual
scenarios with real speakers.

## Known limitations

- AirPlay speakers that require pairing or encryption (e.g. HomePod) are not supported.
- Chromecast latency is set by the speaker and cannot be lowered from the sender side.
- Stereo pair: the offset is set by hand; clock drift between the two speakers is not yet
  corrected automatically.
- Safari's web audio comes from a WebKit process shared by all WebKit apps.
- On a Mac with two network interfaces on the same subnet AudioHub tries each in turn.

## License

MIT — see [LICENSE](LICENSE).
