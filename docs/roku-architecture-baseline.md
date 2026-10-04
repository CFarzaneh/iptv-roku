# Roku IPTV architecture baseline

Inspected October 2, 2026; updated October 3, 2026 for the Lambda/DynamoDB control-room deployment. The structure and playback findings below describe the original app inspection. The new backend has passed live cloud checks, but the control-room app has not been sideloaded or hardware-tested on either Roku.

Project directory: `/Users/cfarzaneh/Documents/Codex/2026-09-13/https-github-com-dimakarma-iptv-roku/work/iptv-roku`.

## Design constraints

- Keep developer-mode sideloading.
- Play stream URLs from an M3U directly whenever possible.
- Minimize startup delay, channel-switch delay, and delay behind live separately.
- Keep catalog, search, settings, and playback on-device where practical.
- Introduce a proxy or transcoding only for a demonstrated requirement. An external metadata service need not handle video.
- Retain a single-player architecture; confirm any new concurrent-stream requirements before changing it.

## Existing structure

| Area | Files | Responsibility |
| --- | --- | --- |
| Startup | `source/main.brs`, `components/MainScene.brs` | Create the scene, load configuration, choose catalog source, coordinate screens and guide tasks |
| Catalog | `components/tasks/PlaylistTask.brs`, `source/M3uParser.brs` | Download and parse M3U, merge extras, group channels, cache results |
| Provider API | `components/tasks/XtreamTask.brs` | Load live categories, category channels, or full-provider search data |
| Browsing | `components/ChannelsScreen.brs`, `components/SearchScreen.brs` | Category grids, favorites, recents, channel-name search, playback requests |
| Playback | `components/PlayerScreen.brs` and `.xml` | One Video node, channel switching, overlays, errors, optional audio repair |
| Repair | `components/tasks/LocalProxyTask.brs` | Loopback HTTP relay and narrow AAC header transformation |
| Guide | `components/tasks/EpgTask.brs`, `source/Epg.brs`, `epg/` | Compact JSON guide or provider short listings; off-device XMLTV conversion option |
| Persistence | `source/ChannelStore.brs`, `components/SettingsScreen.brs` | Registry settings, favorites and recents; cache reset |
| Packaging | `manifest`, `deploy.ps1`, `tools/`, `tests/` | Sideload packaging, compile and contract checks, backup tooling |

The manifest identifies build 1.0.20. The packaged configuration contains Xtream settings, no nonempty EPG URL, and no extra playlists. Credential values were not included in this report. Saved TV settings can override packaged settings; the TV's actual state was not inspected.

## Current data and playback flow

1. `RunUserInterface` creates `MainScene`. `ConfigTask` reads packaged configuration; registry settings normally override the playlist URL. A changed `importRevision` can import a packaged URL once.
2. If an Xtream account exists and the selected playlist URL matches the packaged URL, `MainScene` chooses `XtreamTask`. Otherwise it chooses `PlaylistTask`.
3. M3U mode downloads the full playlist, parses channel metadata and URLs, fetches extra playlists sequentially, builds categories, and writes `cachefs:/playlist.json`. Conditional HTTP requests use stored ETag/Last-Modified values. Cached content is returned after a 304 or network failure, rather than displayed immediately before refreshing.
4. Xtream mode first loads categories. Opening a category loads its channels, builds direct HLS URLs, and retains the category in session memory. Provider search downloads the full live-stream list and filters it locally, returning at most 500 matches. Category loads reject more than 2,500 usable channels.
5. Selecting a channel passes the current channel list and selected index to `PlayerScreen`. It creates a ContentNode containing the provider URL, marks it live, defaults to HLS, sets a User-Agent header, and starts the Video node. Up/down switches within that supplied list; Back stops playback.
6. An exact “Unsupported AAC stream” diagnostic can trigger the local repair task. Video then reads a loopback URL on port 8765. The relay downloads HLS data, rewrites manifest URLs, and changes specific ADTS profile bits in transport-stream segments. It does not decode and re-encode media. Affected channels are remembered for the current app session.
7. Guide loading is separate from initial channel display. An explicit guide URL loads compact JSON; automatic Xtream mode fetches short listings for loaded channels. The app refreshes guides hourly and updates its current-time field every 30 seconds. The repository also includes an XMLTV-to-JSON generator and a GitHub Actions schedule every two hours; live workflow operation was not verified.
8. Favorites and up to 20 recents are stored by channel name in the registry. Guide lookup also uses channel names. M3U search matches name and `tvgName`; provider search matches name and provider EPG ID.

## Findings that affect the next design

- **Startup can wait on the network.** The primary M3U request waits up to 30 seconds before cache fallback, with extra requests adding time. Use cached display plus background refresh if fast startup is a priority.
- **Provider favorites depend on loaded metadata.** The provider catalog begins empty and accumulates channels as categories open. Persist enough channel metadata to resolve favorites immediately after launch.
- **Names are doing the work of IDs.** Duplicate names and renames can confuse favorites and guide matching. Separate channel identity from display names and expiring playback URLs, with migration for existing favorites.
- **Compatibility is only a URL heuristic.** The M3U parser marks URLs containing `.m3u8` compatible and rejects other forms. This can reject valid extensionless HLS and cannot validate codecs. Preserve “unknown” compatibility and use playback evidence for confirmed results.
- **Caches need source identity.** M3U fallback loads a shared cached file without checking its source at fallback time. Guide caches are also shared. Partition or validate caches by source/account and schema version.
- **Search can be expensive.** Xtream search downloads the full live catalog for each submitted search. A bounded, reusable local index would avoid repeated downloads.
- **Parsed M3U guide metadata is not wired through.** The parser extracts `url-tvg`, but current guide selection uses saved/configured JSON URLs or automatic provider mode. XMLTV ingestion and guide-source precedence need an explicit design.
- **The relay is specialized.** Its manifest rewrite treats every non-comment URI as a media segment and leaves tag-embedded URIs unchanged. It should not be assumed to handle arbitrary master playlists, encryption, alternate audio, or fragmented MP4. It also downloads complete segments before serving them. Repair correctness and latency require device testing.
- **Playback health is limited.** Session memory records that AAC repair was triggered, rather than a durable history of verified playback success. General stream ranking and automatic alternative-source selection are not implemented.

## Proposed baseline, pending requirements

Keep a single Roku application with four clear responsibilities:

1. **Source adapters:** M3U and optional Xtream adapters produce the same channel model, including source ID, stable channel ID, display metadata, guide ID, playback URL, and required headers.
2. **Local catalog and guide store:** Own source-scoped caches, indexes, favorites, recents, guide matching, and bounded background refresh. Screens read this shared state instead of owning independent catalog copies.
3. **Playback controller:** Own the one Video node and the transition between stopping, loading, playing, retrying, and failing. Prefer direct playback. Isolate any proven compatibility repair and discard stale work after a channel switch.
4. **Remote-driven screens:** Browse, search, settings, guide, and player overlays request actions from those shared components.

The normal media path stays: provider → Roku Video node → screen. Metadata retrieval and guide refresh run independently. Add a local or hosted helper only if measured catalog/guide limits or specific stream incompatibilities justify one; a guide helper should remain outside the media path.

Measure launch-to-browse, selection-to-playing, rebuffering, and live-edge delay separately. Roku exposes playback-start timing through `playStartInfo` and live-edge information through its Video diagnostics; availability and behavior should be validated on the target device. See [Roku Video documentation](https://developer.roku.com/dev/docs/video). Check actual stream codecs and containers against [Roku streaming specifications](https://developer.roku.com/dev/docs/media), rather than relying on filename extensions.

## Control-room extension deployed in AWS, pending device validation

The [system design](iptv-dashboard-system-design.md) now uses Amplify Hosting and Cognito for one browser administrator, a Node.js Lambda Function URL for the HTTPS API, and a small DynamoDB table for latest state and short-lived commands. This replaces the previous Lightsail container and 25-second long poll. CDK defines the stack and CloudFormation deploys it in `us-east-2`. No cloud video proxy, transcoder, or permanent catalog/history database is introduced. S3 software releases remain the last phase.

`components/tasks/DashboardTask.brs` authenticates a personalized sideload using an installation secret and Roku device attestation, then makes a short asynchronous `/device/sync` roughly every two seconds while the IPTV app is active. `components/DashboardBridge.brs` keeps UI and Video-node changes on the SceneGraph side. A sync reports bounded telemetry/results and receives at most one remote command. The dashboard polls Lambda for state/results while visible. The Roku still fetches provider catalogs, resolves playback IDs, and tunes through the original `PlayerScreen` controller; AWS loss must not interrupt local playback.

The Roku registry remains the durable owner of provider credentials, favorites, recents, and settings. A browser-initiated provider replacement is only a temporary DynamoDB command; the Roku validates and saves it locally. DynamoDB TTL is not immediate, so the application must enforce expiry and explicitly remove sensitive commands. No manual in-app dashboard pairing is intended: each TV receives its own private sideload package containing its dashboard URL and installation secret. Dad’s Roku is at another home, so someone there still must sideload the package initially.

The original v1.0.20 ZIP is a backup of a sideloadable app package, not of the current Roku registry. The installed build does not emit the store markers required by the old console-backup helper. A read-only ECP registry query is available on developer-mode devices, but My Roku returned 403; Roku documents that this endpoint requires “Control by mobile apps” enabled. The owner elected to prepare a personalized ZIP without a favorites/recents restore seed, accepting the risk that a sideload failure or registry reset may erase those lists. That ZIP has not yet been installed. Hardware gates remain: signed attestation claims on the actual devices, command timing, duplicate/stale-command fencing, provider validation, metric completeness, and continued local playback during cloud failure.
