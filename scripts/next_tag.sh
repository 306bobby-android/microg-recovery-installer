#!/usr/bin/env bash
# Prints the tag for the next release of a given microG version: the bare
# version the first time, then HOTFIX1, HOTFIX2, ... for later builds of it.
set -euo pipefail

version="${1:?usage: next_tag.sh <microg version>}"
base="v${version}"
escaped="${base//./\\.}"

tags="$(git ls-remote --tags origin 2>/dev/null | sed 's|.*refs/tags/||; s|\^{}$||' | sort -u)"

if ! grep -qxF "${base}" <<<"${tags}"; then
  echo "${base}"
  exit 0
fi

last="$(sed -n "s|^${escaped}-HOTFIX\([0-9]\{1,\}\)$|\1|p" <<<"${tags}" | sort -n | tail -1)"
echo "${base}-HOTFIX$(( ${last:-0} + 1 ))"
