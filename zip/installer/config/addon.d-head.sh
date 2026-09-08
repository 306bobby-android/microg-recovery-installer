#!/sbin/sh
# ADDOND_VERSION=3
# microG recovery installer -- keeps the install alive across dirty ROM flashes.
# Generated at install time; do not edit by hand.
# shellcheck shell=sh
# shellcheck source=/dev/null

. /tmp/backuptool.functions || {
  echo 'microG addon.d: backuptool.functions is missing' >&2
  return 1 2>/dev/null || exit 1
}

