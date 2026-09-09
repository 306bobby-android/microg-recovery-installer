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
