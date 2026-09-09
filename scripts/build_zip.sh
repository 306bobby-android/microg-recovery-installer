#!/usr/bin/env bash
# Assemble the flashable zip from zip/ (skeleton) + build/apps (downloaded APKs).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="${ROOT}/build"
STAGE="${BUILD}/zip"
DIST="${ROOT}/dist"

VERSION="${1:-$(date -u '+%Y.%m.%d')}"
NAME="microg-recovery-installer"
OUT="${DIST}/${NAME}-${VERSION}.zip"

[ -d "${BUILD}/apps" ] || { echo "error: run scripts/fetch_apks.py first" >&2; exit 1; }
[ -f "${BUILD}/apps.list" ] || { echo "error: build/apps.list is missing" >&2; exit 1; }

rm -rf "${STAGE}"
mkdir -p "${STAGE}" "${DIST}"

cp -a "${ROOT}/zip/." "${STAGE}/"
rm -f "${STAGE}/apps/.gitkeep"

cp "${BUILD}/apps.list" "${STAGE}/installer/apps.list"
cp "${BUILD}/sizes.list" "${STAGE}/installer/sizes.list"
cp "${BUILD}"/apps/*.apk "${STAGE}/apps/"

mkdir -p "${STAGE}/busybox"
cp "${BUILD}"/busybox/busybox-* "${STAGE}/busybox/"
chmod 0755 "${STAGE}"/busybox/busybox-*

cat > "${STAGE}/installer/module.prop" <<PROP
id=${NAME}
name=microG recovery installer
version=${VERSION}
author=306bobby-android
description=Minimal microG + Aurora Store system installer for custom recoveries.
PROP

chmod 0755 "${STAGE}/META-INF/com/google/android/update-binary"
chmod 0644 "${STAGE}/META-INF/com/google/android/updater-script"
find "${STAGE}/installer" -type f -exec chmod 0644 {} +

rm -f "${OUT}"
cd "${STAGE}"

# APKs are already deflated; storing them keeps the zip the same size and makes
# on-device extraction noticeably cheaper.
zip -q -r -9 -X "${OUT}" . -x 'apps/*'
zip -q -r -0 -X "${OUT}" apps

cd "${ROOT}"
( cd "${DIST}" && sha256sum "$(basename "${OUT}")" > "$(basename "${OUT}").sha256" )

echo "Built ${OUT}"
ls -lh "${OUT}"
