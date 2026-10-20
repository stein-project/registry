#!/usr/bin/env bash
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.
#
# Copyright (c) 2026 Breno Xavier
#
# Builds the published registry in <out> (default _site): every .json of the repository, each with its signature
# next to it (<file>.sig: the base64 of the raw ed25519 signature over the file's exact bytes). The Stein Loader, the
# Stein Client and the installer check the signature against the public key they carry and refuse a file without a
# valid one.
#
#   tools/sign.sh <private-key.pem> [out]
#
# The key is never in this repository: in CI it comes from the REGISTRY_SIGNING_KEY secret; on a machine, from a file
# outside the repositories. Needs OpenSSL 3 (ed25519 with -rawin).
set -euo pipefail
KEY="${1:?usage: $0 <private-key.pem> [out]}"
OUT="${2:-_site}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
rm -rf "$OUT"
mkdir -p "$OUT"
n=0
# python3, or python where python3 is only the Windows Store alias.
PY=python3
"$PY" -c "" 2>/dev/null || PY=python
while IFS= read -r f; do
    "$PY" -c 'import json,sys; json.load(open(sys.argv[1], encoding="utf-8"))' "$f" \
        || { echo "invalid JSON: $f" >&2; exit 1; }
    mkdir -p "$OUT/$(dirname "$f")"
    cp "$f" "$OUT/$f"
    openssl pkeyutl -sign -inkey "$KEY" -rawin -in "$f" | base64 | tr -d '\n' > "$OUT/$f.sig"
    n=$((n + 1))
done < <(git ls-files '*.json' 2>/dev/null | grep . || find . -name '*.json' -not -path "./$OUT/*" | sed 's#^\./##')
[ "$n" -gt 0 ] || { echo "no .json to sign" >&2; exit 1; }
# GitHub Pages: no Jekyll (it would hide files and folders it does not like).
touch "$OUT/.nojekyll"
echo "signed $n file(s) into $OUT"
