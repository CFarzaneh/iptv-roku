# IPTV Player for Roku

A personal IPTV player for a Hisense Roku TV (Roku OS 15+), built with BrightScript
and SceneGraph. It loads an M3U playlist over HLS, groups channels by category, and
adds favorites, recents, search, an on-screen guide (EPG), and a channel zapper — all
driven by the remote. Installed by developer-mode sideload; not distributed through the
Roku Channel Store.

## Features
- **Playlist** — M3U over HLS (`index.m3u8`), parsed and cached on device; optional
  extra playlists merged in as their own category.
- **Channels** — two-pane rail + grid, category counts, logo/initials tiles, incompatible
  streams flagged.
- **Favorites & Recents** — stored by channel name (survives provider domain/token changes);
  toggle with `*` or long-press OK.
- **Player** — HLS video with an info overlay, channel zap (▲/▼), a side zapper panel,
  automatic on-device repair for Roku's `Unsupported AAC stream` failure, and an error
  dialog with retry / next / favorite / back.
- **Search / Settings / Onboarding** — on-screen keyboard search, editable playlist & EPG
  URLs, cache reset.
- **EPG** — compact "now/next" guide generated off-device (see [`epg/`](epg/)) and shown on
  cards and in the player overlay.

## Repository layout
```
manifest              Roku channel manifest (title, version, artwork)
config.example.json   Config template (copy to config.json; real config.json is gitignored)
deploy.ps1            Build + sideload helper (Windows / PowerShell)
source/               Shared BrightScript: Theme, ChannelStore, M3uParser, Epg
components/           SceneGraph components (screens, cards) + tasks/ (async config/playlist/epg)
images/               Splash screens and channel/app icons
epg/                  EPG generator (Python) — see epg/README.md
.github/workflows/    GitHub Action that regenerates the EPG on a schedule
control-room/         React dashboard, Node.js relay, tests, and AWS CDK (us-east-2)
```

## Website control room

The [control-room application](control-room/README.md) adds one private login for two
TVs, on-device channel catalogs with existing provider IDs, remote tuning, playback
metrics, and provider credential replacement. AWS CDK provisions Amplify Hosting,
Cognito, and a single Lightsail container in `us-east-2`. Software updates are deferred.
The app's direct playback does not depend on AWS. A personalized, gitignored
`source/dashboard.json` enables its background connection; without it cloud controls
remain dormant. Device attestation and playback reporting still require hardware validation.

## Requirements
- A Roku device with **Developer Mode** enabled.
- Windows with PowerShell for `deploy.ps1` (or any OS for the manual upload flow).
- **Node.js**, for the BrightScript compile gate `deploy.ps1` runs before it builds
  anything. Restore it with `npm ci` (the compiler version is pinned in `package.json`).
- **Python**, for the node-reference check that resolves `findNode` / `observeField` /
  `onChange` names the compiler cannot see.

## Configuration
Copy `config.example.json` to `config.json` and fill in your URLs:
```json
{
  "playlistUrl": "https://HOST/path/TOKEN/playlist.m3u8",
  "epgUrl": "https://raw.githubusercontent.com/DimaKarma/iptv-roku/epg-data/epg.json",
  "extraPlaylists": [
    { "url": "https://iptv-org.github.io/iptv/categories/sports.m3u", "category": "Sport2" }
  ]
}
```
`config.json` holds a subscription token in `playlistUrl`, so it is **gitignored** and never
committed. The playlist and EPG URLs can also be changed on the TV in Settings.

**Prefer `https`.** The token is a path segment, so over plain `http` it — and the whole
playlist, including every stream URL — crosses the network in the clear on every launch,
readable by anyone on the path. The app fetches `https` over verified TLS with no change
needed; whether your provider serves it is worth checking before settling for `http`.

## Install via the deploy script (Windows)
1. Enable Developer Mode on the Roku TV: `Home x3, Up x2, Right, Left, Right, Left, Right`.
2. Set a password and note the TV's IP address.
3. Pass the password to the script — **never put it in the file**:
   ```powershell
   $env:ROKU_PASS = "<your dev password>"
   .\deploy.ps1 -RokuIp <TV_IP>
   ```
   (`-RokuPass <password>` works too.) The script has no default and refuses to run
   without one, so the password stays out of the repository.
4. It compile-checks the sources, backs up your favorites off the TV, builds the ZIP
   archive and uploads it.

## Install manually
1. Build a ZIP from the `manifest` and `config.json` files and the `source`, `components`,
   and `images` folders (`manifest` must sit at the archive root, not inside a folder).

   > **The archive must be a real ZIP with forward slashes.** On Windows, GNU `tar` (the
   > one in Git Bash) writes a *tar* file under a `.zip` name, and PowerShell's
   > `Compress-Archive` writes backslash paths — Roku rejects both, and a rejected install
   > can clear the channel's stored data. Use the bundled `C:\Windows\System32\tar.exe`,
   > then check that the first two bytes are `PK` and that `unzip -t` passes.
2. Open a browser on your PC and go to `http://<ROKU_IP>`.
3. Enter the username `rokudev` and your Developer Mode password.
4. Click **Upload**, select the ZIP, then click **Install with squashfs**.

## EPG
For ordinary M3U configuration, [`epg/generate_epg.py`](epg/generate_epg.py) builds the
compact `epg.json` format consumed by the app, and a scheduled GitHub Action can publish
it to the **`epg-data`** branch. See [`epg/README.md`](epg/README.md) for details.

For an Xtream-compatible account configured in `config.json`, the app automatically loads
short guide listings for channels in categories opened during the current session. This
avoids downloading a provider XMLTV document that may be too large for Roku memory. A
nonempty EPG URL saved in Settings overrides automatic mode; saving an empty value restores
automatic provider EPG.

## Debugging
View BrightScript logs and errors over telnet:
```cmd
telnet <ROKU_IP> 8085
```
If `telnet` is not installed on Windows, enable it via "Turn Windows features on or off",
or use PuTTY (connection type: Raw, port 8085).

## License
[MIT](LICENSE) © 2026 DimaKarma. The license covers this repository's own source code.
Roku OS / SceneGraph APIs it calls remain Roku's, and playlist/EPG data come from their
respective third-party sources.
