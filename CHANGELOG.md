<!--
Notes for the next release. They are appended to the release description below
the component table and the flashing instructions, then this file is replaced
for the release after that. Past notes stay readable on the releases page.
-->

- Install to whichever of `/system`, `/system_ext` or `/product` has the most
  free space, instead of always using `/system`.
- Detect `/system_ext` and `/product` by presence rather than by API level, and
  only use one if the ROM already ships a `privapp-permissions` file there.
- Attempt a read-write mount of `/system` before probing, and resolve the real
  mountpoint when remounting.
- Size the install from a per-ABI table, since only your device's ABI is
  unpacked.
- Fix the installer exiting silently on a read-only partition.
