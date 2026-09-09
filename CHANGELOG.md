<!--
Notes for the next release. They are appended to the release description below
the component table and the flashing instructions, then this file is replaced
for the release after that. Past notes stay readable on the releases page.
-->

- Fix every partition reporting "size unknown" and the install then failing.
  The size check used `awk`, which recoveries built on toybox do not have.
- Ship a static busybox for each ABI and run the installer against it, so it no
  longer depends on what the recovery provides.
- Measure the install from sizes recorded at build time instead of reading the
  zip on the device.
- Find `/system_ext` and `/product` from the kernel's mount table instead of a
  fixed list of paths, so they are no longer missed on devices where the
  recovery mounts them somewhere else.
- Accept `/product` from API 29 and `/system_ext` from API 30 even when the ROM
  ships no permission whitelist of its own there.
- Print every partition, where it was found, and the reason any of them was
  skipped.
