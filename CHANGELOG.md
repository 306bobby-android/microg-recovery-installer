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
- Find `/system_ext` and `/product` on devices with dynamic partitions, where
  they are separate partitions that the recovery has not mounted and that show
  up as symlinks inside `/system`. Only `/system` was offered before.
- Clear the read-only flag on logical block devices with `blockdev --setrw`
  before mounting or remounting them. Without it no mount option can make a
  dynamic partition writable.
- Resolve block devices through the recovery's own fstab, with the A/B slot
  suffix taken from the kernel command line when the property is missing.
- Accept `/product` from API 29 and `/system_ext` from API 30 even when the ROM
  ships no permission whitelist of its own there.
- Print the partition layout, where each partition was found, and the reason
  any of them was skipped.
