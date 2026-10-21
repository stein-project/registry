# Stein registry

Everything the Stein Project's programs look up at run time, in one place: the Stein Loader in the game, the Stein
Client and the installer read these files, and nothing they need to change without a new version is built into them.
The binaries stay in each repository's releases; the registry only says what is current and where to download it,
with the sha256.

Published at **https://stein-project.github.io/registry/** by the `publish` workflow: each `.json` goes out with its
**ed25519 signature** next to it (`<file>.sig`, the base64 of the raw signature over the file's exact bytes). The
programs carry the public key and refuse a file without a valid signature, keeping their last good copy instead. The
private key is never in a repository: in CI it is the `REGISTRY_SIGNING_KEY` secret.

**After a release, run `publish` by hand** (Actions > publish > Run workflow, also on the GitHub app). Before signing,
`tools/collect.sh` reads the releases listed in `tools/releases.tsv` and brings those files up to date: each official
mod's `mods/<id>.json` from its latest release's `steinmods.json`, `client.json` from the Stein Client's `update.json`
and `latest`/`test.loader` of `stein.json` from the installer's releases. No other repository writes here, so none
needs a token for it. A release that cannot be read, or whose file is not valid, does not reach the registry: the
published copy of that file stays, with a warning in the run. The copies of those files in this repository are only
the starting point; the published ones are the current ones.

| File | Read by | What it holds |
|---|---|---|
| `stein.json` | Loader, Stein Client, installer | links (Discord, site, player heads), the latest pack version, the menu news, the official mods enabled by default and their indexes (`sources`) |
| `mods/<id>.json` | Stein Client, installer | each official mod's index (the `steinmods.json` format): version, file, sha256, minimum Loader |
| `client.json` | Stein Client | the launcher's latest version: download base and sha256 of each executable |
| `launch.json` | Stein Client | the game's memory and Java arguments |
| `compat.json` | Stein Client | extra Java arguments by system, architecture and graphics card |
| `servers.json` | Loader | features turned off on a given server (only while playing there) |
| `revoked.json` | Loader, Stein Client | mods that must not load or be installed, by sha256 |
| `migrations.json` | Stein Client | official mods that moved to a third-party source |

Files carry `"schema": 1` (`client.json` and the mod indexes keep their own formats; a file without `schema` counts
as 1); a program skips a file whose schema it does not know and keeps its last copy.

## Formats

**`stein.json`**

```json
{ "schema": 1,
  "discord": "https://discord.gg/...",
  "links": { "discord": "https://discord.gg/...", "site": "https://stein-project.github.io",
             "heads": "https://mc-heads.net/avatar/{uuid}/{size}" },
  "latest": { "version": "0.1.35", "url": "https://github.com/stein-project/installer/releases/latest" },
  "news": { "id": "discord", "title": { "pt_BR": "...", "en_US": "..." }, "text": { "...": "..." }, "url": "https://..." },
  "defaultMods": ["hud", "connect", "keybind", "replay"],
  "sources": ["https://stein-project.github.io/registry/mods/hud.json", "..."] }
```

`latest` comes from the installer's releases (`tools/collect.sh`). `sources` are the official mods; a mod that joins
also needs its line in `tools/releases.tsv`.

**`launch.json`** — `ramGb` (the `-Xmx` the game gets) and `javaArgs`. **`compat.json`** — a list of rules, each
`{ "when": { "os": "windows|macos|linux", "arch": "x86_64|aarch64", "gpuVendor": "...", "gpuRenderer": "...",
"driver": "..." }, "javaArgs": "...", "note": "..." }`: every field of `when` is optional and is a case-insensitive
substring of what the game recorded about the card (`config/steinloader-gpu.json`, written by the Loader on each
start). Every matching rule adds its arguments, after the launcher's own.

Java arguments from the registry are limited to an allowed list in the Stein Client: `-Xmx`, `-Xms`, the memory and
garbage-collector `-XX:` flags (a fixed list plus ZGC's and G1's, with a plain value), `--enable-native-access=` and
`-D` properties under `stein.`, `steinbridge.` and `steinloader.` except `steinbridge.diag.`. Anything else
(`-javaagent`, `-agentpath`, `-cp`, `-XX:OnError`/`OnOutOfMemoryError`/`Flags`, the diagnostic properties, other
properties) is dropped and logged: a signed file is still not a way to run code on a player's machine.

**`servers.json`**

```json
{ "schema": 1,
  "servers": [ { "name": "Hypixel", "hosts": ["hypixel.net"], "rules": "https://...",
                 "disable": ["minimap", "targetInfo", "playerDistance", "chatMacros", "liveReplay"] } ] }
```

A host matches the server address itself and every subdomain (`hypixel.net` covers `mc.hypixel.net`). The features
are names the mods ask the Loader about (`Server.allows`):

| Feature | Who asks | What goes off |
|---|---|---|
| `minimap` | HUD | the minimap, radar included |
| `targetInfo` | HUD | the target element (health, armor, distance, held item of another player) |
| `playerDistance` | HUD | distance in the Tab list: column, "nearby" filter, sorting by distance |
| `chatMacros` | Keybind | every bind |
| `liveReplay` | Replay | the death replay during the match (still recorded and saved) |

**`revoked.json`** — `{ "schema": 1, "mods": [ { "sha256": "...", "reason": "..." } ] }`. **`migrations.json`** — each
migration runs once per folder: `{ "id", "author", "mods": [ { "id", "modId", "name", "source" } ] }`.

## Changing something

Edit the file, commit to `main`; the `publish` workflow signs and publishes it in a minute or two. Locally,
`tools/sign.sh <key.pem>` builds `_site/` and `tools/verify.sh` checks it against the embedded public key.

## Licence

[Mozilla Public License 2.0](LICENSE).
