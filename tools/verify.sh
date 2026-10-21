#!/usr/bin/env bash
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.
#
# Copyright (c) 2026 Breno Xavier
#
# Checks every signature of a built registry against the public key the clients carry, the way they do.
#
#   tools/verify.sh [dir]          (default _site)
set -euo pipefail
DIR="${1:-_site}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# The public key embedded in the Stein Loader, the Stein Client and the installer (raw 32 bytes, base64).
PUB="exxXasq5SsodR84fDi9gVEs3oRfXXaPVgTn/eK47TUc="
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
# DER SubjectPublicKeyInfo of an ed25519 key: the fixed 12-byte prefix, then the raw key.
{ printf '\x30\x2a\x30\x05\x06\x03\x2b\x65\x70\x03\x21\x00'; printf '%s' "$PUB" | base64 -d; } > "$TMP/pub.der"
openssl pkey -pubin -inform DER -in "$TMP/pub.der" -out "$TMP/pub.pem"
# A relative dir is taken from the repository root, as sign.sh does.
case "$DIR" in /* | [A-Za-z]:*) ;; *) DIR="$ROOT/$DIR" ;; esac
cd "$DIR"
bad=0
while IFS= read -r f; do
    base64 -d < "$f.sig" > "$TMP/sig.bin"
    if ! openssl pkeyutl -verify -pubin -inkey "$TMP/pub.pem" -rawin -in "$f" -sigfile "$TMP/sig.bin" > /dev/null; then
        echo "BAD signature: $f" >&2
        bad=1
    fi
done < <(find . -name '*.json' | sed 's#^\./##')
[ "$bad" = 0 ] && echo "all signatures valid"
exit "$bad"
