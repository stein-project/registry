#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.
#
# Copyright (c) 2026 Breno Xavier
"""The version history the Stein Client offers the player, read from a repository's releases (tools/collect.sh).

    history.py packs <packs.json> <owner/repo> <first tag>
        packs.json: every pack release of the installer from <first tag> on, stable and test (pre-releases), newest
        first, each with its Stein Bridge and Stein Loader versions (the table in the release notes) and its
        changelog (changelog/<version>.<lang>.md of Stein-Project/loader, where the pack's notes live).

    history.py mod <mods/<id>.json> <owner/repo> <first tag>
        adds "versions" to each mod of an index already brought up to date: every release of the mod from <first tag>
        on, stable and test, newest first, each a full entry (version, url, sha256, loader, test) with its
        changelog (changelog/<version>.<lang>.md of the repository at the release's tag). The minimum Loader is read
        from the steinmod.json inside the released .steinmod; an entry already published with the same version and
        sha256 is reused, so only new releases are downloaded.

The history starts at <first tag> (the releases out when the history began) and only grows. A release that cannot be
read is left out with a warning; nothing here fails the publication. Needs gh (GH_TOKEN) for the release lists.
"""

import io
import json
import os
import re
import subprocess
import sys
import urllib.request
import zipfile

REGISTRY_URL = os.environ.get("REGISTRY_URL", "https://stein-project.github.io/registry/")
LANGS = ("en_US", "pt_BR", "es_ES")
PACK_CHANGELOGS = "Stein-Project/loader"
# A changelog is a few paragraphs; anything bigger is not one.
CHANGELOG_LIMIT = 16 * 1024


def warn(msg):
    print(f"::warning::{msg}")


def version_key(v):
    """Orders "0.1.45" after "0.1.45-rc.2" after "0.1.45-rc.1" after "0.1.44"."""
    v = v.lstrip("v")
    main, _, pre = v.partition("-")
    nums = tuple(int(p) if p.isdigit() else 0 for p in main.split("."))
    if not pre:
        return nums, 1, ()
    parts = tuple((0, int(p), "") if p.isdigit() else (1, 0, p) for p in pre.split("."))
    return nums, 0, parts


def fetch(url, limit=None):
    req = urllib.request.Request(url, headers={"User-Agent": "stein-registry"})
    with urllib.request.urlopen(req, timeout=60) as r:
        data = r.read() if limit is None else r.read(limit + 1)
    if limit is not None and len(data) > limit:
        raise ValueError(f"{url} is larger than {limit} bytes")
    return data


def releases(repo, first):
    """The repository's published releases from <first> on (draft ones never count)."""
    out = subprocess.run(
        ["gh", "api", "--paginate", f"repos/{repo}/releases?per_page=100"],
        check=True,
        capture_output=True,
        text=True,
        encoding="utf-8",
    ).stdout
    # --paginate joins the pages' arrays one after the other.
    found = []
    for page in re.split(r"(?<=\])\s*(?=\[)", out.strip()):
        found.extend(json.loads(page))
    start = version_key(first)
    return [r for r in found if not r.get("draft") and version_key(r["tag_name"]) >= start]


def changelog(repo, ref, version):
    """The release notes in each language there is a file for: {"en_US": "...", "pt_BR": "..."}."""
    notes = {}
    for lang in LANGS:
        url = f"https://raw.githubusercontent.com/{repo}/{ref}/changelog/{version}.{lang}.md"
        try:
            notes[lang] = fetch(url, CHANGELOG_LIMIT).decode("utf-8").strip()
        except Exception:  # noqa: BLE001 - a language without a file is simply absent
            pass
    return notes


def published(name):
    try:
        return json.loads(fetch(f"{REGISTRY_URL}{name}"))
    except Exception:  # noqa: BLE001 - nothing published yet
        return None


def component(body, name):
    m = re.search(rf"^\|\s*{re.escape(name)}\s*\|\s*([0-9][0-9A-Za-z.\-]*)\s*\|", body or "", re.M)
    return m.group(1) if m else None


def packs(path, repo, first):
    out = []
    for r in releases(repo, first):
        tag = r["tag_name"]
        version = tag.lstrip("v").split("-")[0]
        bridge = component(r.get("body"), "Stein Bridge")
        loader = component(r.get("body"), "Stein Loader")
        if not bridge or not loader:
            warn(f"{path}: {tag} of {repo} does not say its Bridge and Loader versions; left out")
            continue
        out.append(
            {
                "version": tag.lstrip("v"),
                "tag": tag,
                "test": bool(r.get("prerelease")),
                "date": (r.get("published_at") or "")[:10],
                "bridge": bridge,
                "loader": loader,
                "changelog": changelog(PACK_CHANGELOGS, "main", version),
            }
        )
    out.sort(key=lambda p: version_key(p["version"]), reverse=True)
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        json.dump({"schema": 1, "packs": out}, f, ensure_ascii=False, indent=2)
        f.write("\n")
    print(f"{path}: " + ", ".join(p["version"] for p in out))


def sums(text):
    out = {}
    for line in text.splitlines():
        parts = line.split()
        if len(parts) >= 2:
            out[parts[1].lstrip("*")] = parts[0].lower()
    return out


def mod_entry(repo, r, current, reuse):
    """The index entry of one release of the mod in <current> (the index's entry, for the fields a release keeps)."""
    tag = r["tag_name"]
    assets = {a["name"]: a["browser_download_url"] for a in r.get("assets", [])}
    if current["file"] not in assets or "SHA256SUMS.txt" not in assets:
        return None
    sha = sums(fetch(assets["SHA256SUMS.txt"], 64 * 1024).decode("utf-8")).get(current["file"])
    if not sha or not re.fullmatch(r"[0-9a-f]{64}", sha):
        return None
    version = tag.lstrip("v")
    old = reuse.get((version, sha))
    if old:
        return old
    with zipfile.ZipFile(io.BytesIO(fetch(assets[current["file"]], 64 * 1024 * 1024))) as z:
        manifest = json.loads(z.read("steinmod.json"))
    if manifest.get("id") != current["modId"]:
        warn(f"{tag} of {repo}: the released file is not the mod {current['modId']}; left out")
        return None
    entry = {k: current[k] for k in ("id", "modId", "name", "file", "description") if k in current}
    entry.update(
        {
            "version": version,
            "url": assets[current["file"]],
            "sha256": sha,
            "loader": manifest.get("loader", ""),
            "test": bool(r.get("prerelease")),
            "date": (r.get("published_at") or "")[:10],
            "changelog": changelog(repo, tag, version.split("-")[0]),
        }
    )
    return entry


def mod(path, repo, first):
    with open(path, encoding="utf-8") as f:
        index = json.load(f)
    old = published(path) or {}
    reuse = {
        (v["version"], v["sha256"]): v
        for m in old.get("mods", [])
        for v in m.get("versions", [])
        if "version" in v and "sha256" in v
    }
    rels = releases(repo, first)
    for current in index.get("mods", []):
        versions = []
        for r in rels:
            try:
                e = mod_entry(repo, r, current, reuse)
            except Exception as ex:  # noqa: BLE001 - one bad release does not stop the others
                warn(f"{path}: {r['tag_name']} of {repo} could not be read ({ex}); left out")
                continue
            if e:
                versions.append(e)
        versions.sort(key=lambda v: version_key(v["version"]), reverse=True)
        current["versions"] = versions
        print(f"{path}: {current['id']} " + ", ".join(v["version"] for v in versions))
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        json.dump(index, f, ensure_ascii=False, indent=2)
        f.write("\n")


def main(argv):
    if len(argv) != 5 or argv[1] not in ("packs", "mod"):
        print(__doc__, file=sys.stderr)
        return 2
    kind, path, repo, first = argv[1:]
    try:
        (packs if kind == "packs" else mod)(path, repo, first)
    except Exception as ex:  # noqa: BLE001 - the published copy stays (collect.sh)
        warn(f"{path}: the history of {repo} could not be built ({ex})")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
