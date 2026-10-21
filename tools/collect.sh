#!/usr/bin/env bash
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.
#
# Copyright (c) 2026 Breno Xavier
#
# Brings the files that follow the releases (tools/releases.tsv) up to date in the working tree, before signing: each
# official mod's index from its latest release's steinmods.json (with "source" pointing here), client.json from the
# Stein Client's update.json, and "latest"/"test.loader" of stein.json from the installer's releases. The registry
# reads the releases instead of the releases writing here, so no other repository needs a token for it.
#
#   tools/collect.sh
#
# A release that cannot be read, or whose file is not what the programs expect, does not reach the registry: the
# published copy of that file stays (or, before the first publication, the one in the repository), with a warning.
# Needs gh (GH_TOKEN; reading public releases is enough) and jq. Run locally it changes the files in place, which can
# be committed or thrown away.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
REGISTRY_URL="${REGISTRY_URL:-https://stein-project.github.io/registry/}"
# jq on the Windows runner ends lines with CRLF, and a \r at the end of a value breaks comparisons.
jq() { command jq "$@" | tr -d '\r'; }
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# keep <file> <why>: the published copy of <file> stays; before the first publication, the repository's.
keep() {
  echo "::warning::$1: $2; keeping the published copy"
  if curl -fsSL "${REGISTRY_URL}$1" -o "$work/published.json" && command jq -e . "$work/published.json" > /dev/null; then
    cp "$work/published.json" "$1"
  else
    echo "::warning::$1: nothing published yet, the repository's copy goes out"
  fi
}

# asset <owner/repo> <file> <out>: <file> of the repository's latest stable release.
asset() {
  curl -fsSL "https://github.com/$1/releases/latest/download/$2" -o "$3"
}

mod_index() {
  local file="$1" repo="$2"
  asset "$repo" steinmods.json "$work/in.json" || { keep "$file" "no steinmods.json on the latest release of $repo"; return; }
  if ! command jq -e '.format == 1 and (.mods | type == "array" and length > 0)
      and all(.mods[]; (.id | type == "string") and (.version | type == "string")
        and (.url | type == "string" and startswith("https://"))
        and (.sha256 | type == "string" and test("^[0-9a-f]{64}$")))' "$work/in.json" > /dev/null; then
    keep "$file" "the steinmods.json of $repo is not a valid index"
    return
  fi
  jq --arg s "${REGISTRY_URL}$file" '.source = $s' "$work/in.json" > "$file"
  echo "$file: $(jq -r '[.mods[] | "\(.id) \(.version)"] | join(", ")' "$file")"
}

client() {
  local file="$1" repo="$2"
  asset "$repo" update.json "$work/in.json" || { keep "$file" "no update.json on the latest release of $repo"; return; }
  if ! command jq -e '(.version | type == "string") and (.base | type == "string" and startswith("https://"))
      and (.files | type == "object" and length > 0)
      and all(.files[][]; type == "string" and test("^[0-9a-f]{64}$"))' "$work/in.json" > /dev/null; then
    keep "$file" "the update.json of $repo is not a valid manifest"
    return
  fi
  jq . "$work/in.json" > "$file"
  echo "$file: $(jq -r .version "$file")"
}

# "latest" is the newest stable release, "test.loader" a test release newer than it (as the installer's index.sh).
installer() {
  local file="$1" repo="$2" releases latest test_tag version test_version
  if ! releases="$(gh api "repos/$repo/releases?per_page=100" \
      --jq '[.[] | select(.draft | not) | {tag: .tag_name, pre: .prerelease}]')"; then
    echo "::warning::$file: the releases of $repo could not be read; latest stays as it is"
    return
  fi
  latest="$(jq -r '[.[] | select(.pre | not)][0].tag // empty' <<< "$releases")"
  test_tag="$(jq -r '[.[] | select(.pre)][0].tag // empty' <<< "$releases")"
  [ -n "$latest" ] || { echo "::warning::$file: no stable release of $repo; latest stays as it is"; return; }
  version="${latest#v}"
  test_version="${test_tag#v}"; test_version="${test_version%%-*}"
  local filter='.latest.version = $v | .latest.url = $u | del(.test.loader)'
  local args=(--arg v "$version" --arg u "https://github.com/$repo/releases/latest")
  # A test release counts only while it is ahead of the stable one (the stable of the same version replaces it).
  if [ -n "$test_tag" ] && [ "$test_version" != "$version" ] \
      && [ "$(printf '%s\n%s\n' "$version" "$test_version" | sort -V | tail -1)" = "$test_version" ]; then
    filter="$filter | .test.loader = {version: \$tv, tag: \$tt, url: \$tu}"
    args+=(--arg tv "$test_version" --arg tt "$test_tag" --arg tu "https://github.com/$repo/releases/tag/$test_tag")
  fi
  # An empty "test" block goes away instead of staying as {}.
  jq "${args[@]}" "$filter | if .test == {} then del(.test) else . end" "$file" > "$work/out.json"
  mv "$work/out.json" "$file"
  echo "$file: latest $version${test_tag:+ (test $test_tag)}"
}

while IFS=$'\t' read -r file repo kind; do
  case "$file" in ''|'#'*) continue ;; esac
  case "$kind" in
    steinmods.json) mod_index "$file" "$repo" ;;
    update.json) client "$file" "$repo" ;;
    installer) installer "$file" "$repo" ;;
    *) echo "::error::tools/releases.tsv: unknown kind \"$kind\" for $file"; exit 1 ;;
  esac
done < tools/releases.tsv
