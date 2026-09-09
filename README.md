# microg-recovery-installer

A small, flashable recovery zip that installs **microG** and **Aurora Store**
as system apps — and nothing else.

This project installs six packages, at
most, and asks before installing the two that are genuinely optional.

The repo contains the **zip skeleton only**. The APKs are downloaded, verified
and packed by GitHub Actions, which publishes the finished zip as a release.

## What it installs

| Component | Package | Location | Optional |
| --- | --- | --- | --- |
| microG Services | `com.google.android.gms` | `priv-app` | no |
| microG Services Framework Proxy | `com.google.android.gsf` | `priv-app` | no |
| microG Companion (FakeStore) | `com.android.vending` | `priv-app` | no |
| Aurora Store | `com.aurora.store` | `app` | no |
| Aurora Services | `com.aurora.services` | `priv-app` | **yes** |
| F-Droid Privileged Extension | `org.fdroid.fdroid.privileged` | `priv-app` | **yes** |

## Where it installs

Android loads privileged apps out of `/system`, `/system_ext` and `/product`
alike, so the installer measures the free space on all three and installs to
whichever has the most room — falling back from `/system` automatically on
devices whose system partition is too full, or read-only.

`/system_ext` and `/product` are used whenever the device actually has them,
rather than being gated on an API level: some Android 10 builds ship
`/system_ext`, some Android 11 ones leave `/product` empty. A partition is only
accepted as a target if the ROM already ships a `privapp-permissions` file
there, which is direct proof that the platform reads privileged permission
whitelists from that partition. Getting that wrong bootloops the device, so
guessing from the API level is not good enough.

Everything for one install stays on the same partition. That is not just tidy:
Android matches a privileged app against the `privapp-permissions` file **from
its own partition**, so an app in `/product/priv-app` whitelisted only under
`/system/etc/permissions` would be denied its permissions and bootloop the
device. The only exception is `addon.d`, which lives in `/system/addon.d`
because that is where the ROM looks for it; the generated script records which
partition to restore to.

Plus the configuration those packages need to actually work:

- `etc/permissions/privapp-permissions-*.xml` (Android 8+) — privileged
  permission whitelists. Android **refuses to boot** if a privileged app asks
  for a `signature|privileged` permission that is not whitelisted, so these are
  deliberately a superset of what the current APKs declare.
- `etc/default-permissions/default-permissions-*.xml` (Android 6+) — runtime
  permissions pre-granted so microG works on first boot. None are `fixed`, so
  you can revoke all of them.
- `etc/sysconfig/microg.xml` — doze/background whitelisting and the implicit
  broadcast exemptions push messaging needs.
- `addon.d/50-microg.sh` — survives dirty flashes of the ROM.
- `etc/microg-installer/files.list` — the receipt used to uninstall cleanly.

## Requirements

- A custom recovery (TWRP, OrangeFox, …) that can mount `/system` read-write.
- Android **5.0+ recommended**, 4.4 (API 19) minimum — that is microG's floor.
- A ROM with **signature spoofing support**, otherwise microG cannot pretend to
  be Google Play Services. This zip does not patch your framework.
- Free space on **one of** `/system`, `/system_ext` or `/product`: about
  **165 MiB** on arm64, **150 MiB** on arm32. Current microG builds are large —
  a 103 MiB universal APK, plus the native libraries for your CPU unpacked next
  to it. The installer measures this exactly and aborts rather than
  half-installing.

## Flashing

1. Download the newest zip from [Releases](../../releases).
2. Flash it in your recovery.
3. Answer the prompts with the volume keys:
   - **Volume Up** = yes / left-hand option
   - **Volume Down** = no / right-hand option
4. Reboot, open **microG Settings**, and turn on *Google device registration*
   and *Cloud Messaging*.

Flashing the zip again on a device that already has it offers **reinstall /
update** or **uninstall**.

### Unattended flashing

If volume keys are not readable (adb sideload, some recoveries), every question
falls back to its default — which is *yes* for the optional components. To pick
explicitly, drop a `microg-installer.prop` next to the zip or on `/sdcard`:

```properties
# 1 = reinstall/update, 0 = uninstall (only asked when already installed)
ACTION=1
AURORA_SERVICES=0
FDROID_PRIV=1
# optional: force a partition instead of letting the installer pick
PARTITION=product
```

## Where the APKs come from

`.env` is the single source of truth. Each component names a resolver used to
find the newest build, **and** a pinned `_URL` used as a fallback if the
resolver breaks (upstream moves, an API changes, a repo goes away).

| Component | Source |
| --- | --- |
| microG Services / GSF Proxy / FakeStore | official microG F-Droid repo, `repo.microg.org` |
| Aurora Store | IzzyOnDroid, which redistributes the upstream-signed APK unchanged |
| Aurora Services | GitLab release of `AuroraOSS/AuroraServices` |
| F-Droid Privileged Extension | `f-droid.org` |

Aurora Store is taken from IzzyOnDroid rather than GitLab because GitLab's
release uploads sit behind a Cloudflare challenge that CI cannot pass, and
rather than from f-droid.org because IzzyOnDroid keeps upstream's signature —
the same key Aurora Services is signed with.

**Every download is checked against the signing certificate pinned in `.env`
before it is packed.** Those are the same certificates the
`privapp-permissions` XMLs pin, so a mismatch would otherwise produce a zip
that grants no permissions — or bootloops. If upstream legitimately rotates a
key, the build fails until someone verifies the new key and updates `.env`.

## Building locally

```sh
python3 scripts/fetch_apks.py                 # resolve, download, verify -> build/apps/
python3 scripts/fetch_apks.py --resolve-only  # just print what upstream has now
scripts/build_zip.sh my-version               # assemble -> dist/
```

Only `python3`, `openssl` and `zip` are needed. `aapt2` is used for an extra
package-name check when the Android SDK happens to be present.

## Releases

Three workflows:

| Workflow | Runs on | Does |
| --- | --- | --- |
| **Build** | every push and PR | builds and verifies the zip, publishes nothing |
| **Release** | manual only | builds it and publishes a release |
| **Check microG** | daily | starts a Release when upstream microG has moved |

Releases are cut by running **Release** from the Actions tab. The first release
of a given microG version is tagged with that version (`v0.3.16.252432`); later
builds of the same microG become `v0.3.16.252432-HOTFIX1`, `-HOTFIX2` and so on.
It takes two options: **dry run**, which builds everything and shows you the tag
and the notes in the run summary without publishing, and **prerelease**.

**Check microG** resolves upstream microG without downloading it. When it no
longer matches the newest release it replaces `CHANGELOG.md` with
`Updated microG`, commits it, and starts a Release.

[`CHANGELOG.md`](CHANGELOG.md) holds the notes for the *next* release. They go
into the release description under the component table and the flashing
instructions, and the file is replaced for the release after that — earlier
notes stay readable on the releases page. Edit it in the same commit as the
change it describes.

## Layout

```
.env                       what to download, and how
zip/                       the flashable skeleton (no APKs)
  META-INF/.../update-binary   recovery entry point
  installer/main.sh            the installer
  installer/util.sh            mounting, volume keys, permissions
  installer/config/            the XMLs and the addon.d template
  apps/                        APKs land here at build time
  busybox/                     static busybox, one per ABI, added at build time
CHANGELOG.md               notes for the next release
scripts/fetch_apks.py      resolve + download + verify
scripts/build_zip.sh       assemble the zip
scripts/next_tag.sh        version / HOTFIX tag for the next release
```

## Notes and caveats

- **A/B and dynamic-partition devices** often cannot mount any of these
  partitions writable from recovery at all. There is no Magisk module here; if
  nothing is writable, this zip will tell you and stop.
- Aurora Store is installed to `app`, not `priv-app`, so it is not itself a
  privileged installer. That is what Aurora Services is for.
- Aurora Services upstream has been dormant since 2021. It still works; it is
  optional for exactly that reason.
- microG needs signature spoofing. If your ROM does not support it, microG will
  install and run but Google account login will not work.
- The zip carries a static busybox for each ABI, taken from the Magisk APK and
  pinned to its signing certificate like everything else. Recoveries built on
  toybox have no `awk`, so relying on the recovery's own tools is not safe.
  Mounting still uses the recovery's `mount`, which is what knows its fstab.
- Only your device's ABI is unpacked (40 MiB for arm64, 27 MiB for arm32), not
  all four. The APK itself still carries every ABI and cannot be slimmed: it
  uses APK Signature Scheme v2 with `X-Android-APK-Signed` stripping
  protection, so removing the unused `lib/` entries invalidates the signature
  and the certificate digest the permission XMLs pin. Trimming it would mean
  re-signing microG with our own key, which this project will not do.

## Credits

Based on [ale5000's microG unofficial installer](https://github.com/micro5k/microg-unofficial-installer).

## License

GPL-3.0-or-later. See [LICENSE](LICENSE).
