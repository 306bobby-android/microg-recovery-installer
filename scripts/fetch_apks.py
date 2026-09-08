#!/usr/bin/env python3
"""Resolve, download and verify the APKs listed in .env.

Writes:
  build/apps/<DEST>.apk     the downloaded APKs
  build/apps.list           manifest consumed by the on-device installer
  build/libsizes.list       per-ABI native library sizes
  build/versions.env        resolved versions, for the CI release step

With --resolve-only nothing is downloaded and only versions.env is written,
which is all the daily upstream check needs.

Every download is checked against the signing certificate pinned in .env before
it is accepted -- the privapp-permissions XMLs pin the same certificates, so a
mismatch would silently produce a zip that boot-loops or has no permissions.
"""

from __future__ import annotations

import hashlib
import io
import json
import os
import re
import shlex
import subprocess
import sys
import urllib.parse
import urllib.request
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BUILD = ROOT / "build"
UA = "microg-recovery-installer/1 (+https://github.com/306bobby-android/microg-recovery-installer)"


# --------------------------------------------------------------------------- io
def log(msg: str) -> None:
    print(msg, flush=True)


def fail(msg: str) -> "NoReturn":  # type: ignore[valid-type]
    print(f"error: {msg}", file=sys.stderr, flush=True)
    raise SystemExit(1)


def fetch(url: str, timeout: int = 180) -> bytes:
    req = urllib.request.Request(url, headers={"User-Agent": UA, "Accept": "*/*"})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return resp.read()


def fetch_json(url: str, timeout: int = 60):
    return json.loads(fetch(url, timeout).decode("utf-8"))


def download(url: str, dest: Path, timeout: int = 600) -> None:
    req = urllib.request.Request(url, headers={"User-Agent": UA, "Accept": "*/*"})
    dest.parent.mkdir(parents=True, exist_ok=True)
    with urllib.request.urlopen(req, timeout=timeout) as resp, dest.open("wb") as fh:
        while True:
            chunk = resp.read(1 << 20)
            if not chunk:
                break
            fh.write(chunk)


# ------------------------------------------------------------------------- .env
def load_env(path: Path) -> dict[str, str]:
    env: dict[str, str] = {}
    for raw in path.read_text().splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        key = key.strip()
        if not re.fullmatch(r"[A-Z0-9_]+", key):
            continue
        env[key] = " ".join(shlex.split(value, comments=True)) if value else ""
    return env


def get(env: dict[str, str], comp: str, suffix: str, default: str | None = None) -> str:
    key = f"{comp}_{suffix}"
    if key in env:
        return env[key]
    if default is None:
        fail(f"{key} is missing from .env")
    return default


# -------------------------------------------------------------------- resolvers
def resolve_fdroid(repo: str, package: str) -> tuple[str, str] | None:
    """Newest APK for `package` in an F-Droid style repo."""
    repo = repo.rstrip("/")

    # index-v1.jar is authoritative and works for every repo, including ones
    # that use non-standard APK file names (repo.microg.org does).
    try:
        blob = fetch(f"{repo}/index-v1.jar", timeout=120)
        index = json.loads(zipfile.ZipFile(io.BytesIO(blob)).read("index-v1.json"))
        versions = index.get("packages", {}).get(package)
        if versions:
            best = max(versions, key=lambda v: int(v["versionCode"]))
            return f"{repo}/{best['apkName']}", str(best.get("versionName") or best["versionCode"])
    except Exception as exc:  # noqa: BLE001 - fall through to the API
        log(f"    index-v1.jar unusable ({exc}); trying the v1 API")

    # f-droid.org and IzzyOnDroid also expose a small per-package API, which is
    # much cheaper than their (large) index.
    base = repo[: -len("/repo")] if repo.endswith("/repo") else repo
    try:
        data = fetch_json(f"{base}/api/v1/packages/{package}")
        best = max(data["packages"], key=lambda v: int(v["versionCode"]))
        code = int(best["versionCode"])
        return f"{repo}/{package}_{code}.apk", str(best.get("versionName") or code)
    except Exception as exc:  # noqa: BLE001
        log(f"    v1 API unusable ({exc})")
    return None


_MD_LINK = re.compile(r"\[([^\]]+)\]\(([^)]+)\)")


def resolve_gitlab(project: str, asset_regex: str) -> tuple[str, str] | None:
    """Newest release whose description links an APK matching `asset_regex`.

    GitLab has no real release assets here; upstream pastes markdown links to
    /uploads/<hash>/<file>.apk into the release description.
    """
    pattern = re.compile(asset_regex)
    api = f"https://gitlab.com/api/v4/projects/{urllib.parse.quote(project, safe='')}/releases?per_page=20"
    try:
        releases = fetch_json(api)
    except Exception as exc:  # noqa: BLE001
        log(f"    GitLab API unusable ({exc})")
        return None
    for release in releases:
        for name, href in _MD_LINK.findall(release.get("description") or ""):
            name = name.strip()
            if not pattern.search(name):
                continue
            if href.startswith("/"):
                href = f"https://gitlab.com/{project}{href}"
            return href, str(release.get("tag_name") or "")
    return None


def resolve_github(repo: str, asset_regex: str) -> tuple[str, str] | None:
    pattern = re.compile(asset_regex)
    try:
        release = fetch_json(f"https://api.github.com/repos/{repo}/releases/latest")
    except Exception as exc:  # noqa: BLE001
        log(f"    GitHub API unusable ({exc})")
        return None
    for asset in release.get("assets", []):
        if pattern.search(asset["name"]):
            return asset["browser_download_url"], str(release.get("tag_name") or "")
    return None


# ----------------------------------------------------------------- verification
def cert_sha256(apk: Path) -> str:
    """SHA-256 of the DER encoded v1 signing certificate.

    This is the value Android compares against `sha256-cert-digest` in
    privapp-permissions / default-permissions XMLs.
    """
    with zipfile.ZipFile(apk) as zf:
        sigs = [
            n
            for n in zf.namelist()
            if n.upper().startswith("META-INF/") and n.upper().endswith((".RSA", ".DSA", ".EC"))
        ]
        if not sigs:
            fail(f"{apk.name}: no v1 (JAR) signature block, cannot pin the certificate")
        der = zf.read(sorted(sigs)[0])

    pem = subprocess.run(
        ["openssl", "pkcs7", "-inform", "DER", "-print_certs"],
        input=der, capture_output=True, check=True,
    ).stdout.decode()
    try:
        body = pem.split("-----BEGIN CERTIFICATE-----")[1].split("-----END CERTIFICATE-----")[0]
    except IndexError:
        fail(f"{apk.name}: could not read a certificate out of the signature block")
    first = f"-----BEGIN CERTIFICATE-----{body}-----END CERTIFICATE-----\n"
    cert = subprocess.run(
        ["openssl", "x509", "-outform", "DER"],
        input=first.encode(), capture_output=True, check=True,
    ).stdout
    return hashlib.sha256(cert).hexdigest().upper()


def lib_sizes(apk: Path) -> dict[str, int]:
    """Uncompressed size of the native libraries in each ABI the APK ships."""
    totals: dict[str, int] = {}
    with zipfile.ZipFile(apk) as zf:
        for info in zf.infolist():
            parts = info.filename.split("/")
            if len(parts) >= 3 and parts[0] == "lib" and parts[-1].endswith(".so"):
                totals[parts[1]] = totals.get(parts[1], 0) + info.file_size
    return totals


def apk_package(apk: Path) -> str | None:
    """Package name via aapt2, when the Android SDK happens to be around."""
    aapt2 = None
    sdk = os.environ.get("ANDROID_HOME") or os.environ.get("ANDROID_SDK_ROOT")
    if sdk:
        candidates = sorted(Path(sdk, "build-tools").glob("*/aapt2"), reverse=True)
        if candidates:
            aapt2 = str(candidates[0])
    if aapt2 is None:
        from shutil import which
        aapt2 = which("aapt2")
    if aapt2 is None:
        return None
    out = subprocess.run([aapt2, "dump", "packagename", str(apk)], capture_output=True)
    if out.returncode != 0:
        return None
    return out.stdout.decode().strip() or None


# ------------------------------------------------------------------------- main
def main() -> int:
    resolve_only = "--resolve-only" in sys.argv[1:]
    env = load_env(ROOT / ".env")
    components = env.get("COMPONENTS", "").split()
    if not components:
        fail("COMPONENTS is empty in .env")

    apps_dir = BUILD / "apps"
    if resolve_only:
        BUILD.mkdir(parents=True, exist_ok=True)
    else:
        apps_dir.mkdir(parents=True, exist_ok=True)
        for stale in apps_dir.glob("*.apk"):
            stale.unlink()

    manifest: list[str] = []
    versions: list[str] = []
    libsizes: list[str] = []

    for comp in components:
        name = get(env, comp, "NAME")
        package = get(env, comp, "PACKAGE")
        dest = get(env, comp, "DEST")
        target = get(env, comp, "TARGET")
        optional = get(env, comp, "OPTIONAL", "0")
        extract_libs = get(env, comp, "EXTRACT_LIBS", "0")
        expected_cert = get(env, comp, "CERT_SHA256").upper().replace(":", "")
        resolver = get(env, comp, "RESOLVER", "direct")
        pinned = get(env, comp, "URL")

        log(f"==> {name} ({package})")

        resolved: tuple[str, str] | None = None
        if resolver == "fdroid":
            resolved = resolve_fdroid(get(env, comp, "FDROID_REPO"), package)
        elif resolver == "gitlab":
            resolved = resolve_gitlab(
                get(env, comp, "GITLAB_PROJECT"), get(env, comp, "ASSET_REGEX")
            )
        elif resolver == "github":
            resolved = resolve_github(
                get(env, comp, "GITHUB_REPO"), get(env, comp, "ASSET_REGEX")
            )
        elif resolver != "direct":
            fail(f"{comp}: unknown resolver {resolver!r}")

        url, version = resolved if resolved else (pinned, "")
        if resolve_only:
            if not version:
                version = re.sub(r"^.*?[-_]", "", url.rsplit("/", 1)[-1]).removesuffix(".apk")
            log(f"    {version} -> {url}")
            versions.append(f"{comp}_VERSION={shlex.quote(version)}")
            versions.append(f"{comp}_RESOLVED_URL={shlex.quote(url)}")
            continue
        if resolved:
            log(f"    resolved {version or 'latest'} -> {url}")
        else:
            log(f"    resolution failed, falling back to the pinned URL -> {url}")

        apk = apps_dir / f"{dest}.apk"
        try:
            download(url, apk)
        except Exception as exc:  # noqa: BLE001
            if url == pinned:
                fail(f"{comp}: download failed: {exc}")
            log(f"    download failed ({exc}); falling back to the pinned URL")
            url, version = pinned, ""
            download(url, apk)

        if not zipfile.is_zipfile(apk):
            fail(f"{comp}: {url} did not return an APK")

        actual_cert = cert_sha256(apk)
        if actual_cert != expected_cert:
            fail(
                f"{comp}: signing certificate mismatch for {url}\n"
                f"       expected {expected_cert}\n"
                f"       got      {actual_cert}\n"
                "       Refusing to ship it. Update <COMP>_CERT_SHA256 in .env only "
                "if you have verified the new signing key yourself."
            )
        log(f"    certificate OK ({actual_cert[:16]}...)")

        actual_package = apk_package(apk)
        if actual_package and actual_package != package:
            fail(f"{comp}: expected package {package}, APK declares {actual_package}")

        if not version:
            version = re.sub(r"^.*?[-_]", "", url.rsplit("/", 1)[-1]).removesuffix(".apk")

        size = apk.stat().st_size
        log(f"    {apk.name}  {size / 1048576:.1f} MiB  version {version}")

        if extract_libs == "1":
            for abi, total in sorted(lib_sizes(apk).items()):
                libsizes.append(f"{dest}|{abi}|{total}")
                log(f"      libs {abi}: {total / 1048576:.1f} MiB unpacked")

        manifest.append(
            "|".join([comp, name, target, dest, package, optional, extract_libs, version])
        )
        versions.append(f"{comp}_VERSION={shlex.quote(version)}")
        versions.append(f"{comp}_RESOLVED_URL={shlex.quote(url)}")

    (BUILD / "versions.env").write_text("\n".join(versions) + "\n")
    if resolve_only:
        log(f"\nWrote {BUILD / 'versions.env'} (nothing downloaded)")
        return 0

    (BUILD / "apps.list").write_text("\n".join(manifest) + "\n")
    (BUILD / "libsizes.list").write_text("".join(f"{row}\n" for row in libsizes))
    log(f"\nWrote {BUILD / 'apps.list'} ({len(manifest)} components)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
