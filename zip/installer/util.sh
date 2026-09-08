#!/sbin/sh
# microg-recovery-installer -- helpers
# SPDX-License-Identifier: GPL-3.0-or-later
# shellcheck shell=sh

### ---------------------------------------------------------------- output ----

ui_print() {
  if [ "${BOOTMODE}" = 'true' ]; then
    printf '%s\n' "$1"
  elif [ -n "${OUTFD_PATH}" ]; then
    printf 'ui_print %s\nui_print\n' "$1" >> "${OUTFD_PATH}"
  else
    printf '%s\n' "$1"
  fi
}

ui_rule() { ui_print '- - - - - - - - - - - - - - - - - - - - - - - -'; }

abort() {
  ui_print ' '
  ui_print "! $1"
  ui_print ' '
  cleanup
  # Read by update-binary after this file's caller returns.
  # shellcheck disable=SC2034
  INSTALL_STATUS=1
  exit 1
}

### ------------------------------------------------------------ environment ----

detect_bootmode() {
  BOOTMODE=false

  # Definitive in a booted system, absent in every recovery.
  if [ "$(getprop sys.boot_completed 2>/dev/null)" = '1' ]; then
    BOOTMODE=true
    return 0
  fi
  # Definitive the other way round.
  if [ -e /sbin/recovery ] || [ -e /system/bin/recovery ] || [ -e /etc/recovery.fstab ]; then
    return 0
  fi
  if pgrep -x zygote >/dev/null 2>&1 || pgrep -x zygote64 >/dev/null 2>&1; then
    BOOTMODE=true
  fi
}

# grep_prop <key> <file...>
grep_prop() {
  _gp_key="$1"
  shift
  for _gp_file in "$@"; do
    [ -f "${_gp_file}" ] || continue
    _gp_val="$(grep -m1 "^${_gp_key}=" "${_gp_file}" 2>/dev/null | cut -d= -f2-)"
    if [ -n "${_gp_val}" ]; then
      printf '%s\n' "${_gp_val}"
      return 0
    fi
  done
  return 1
}

### ---------------------------------------------------------------- mounts ----

# Prints the directory that holds build.prop for a given mountpoint, or fails.
_sys_dir_of() {
  if [ -f "$1/system/build.prop" ]; then printf '%s\n' "$1/system"; return 0; fi
  if [ -f "$1/build.prop" ]; then printf '%s\n' "$1"; return 0; fi
  return 1
}

mount_system() {
  SYS_MOUNTPOINT=''
  SYS=''
  WE_MOUNTED_SYSTEM=0

  # 1. Already mounted, or mountable by name (recovery fstab).
  for _mp in /system_root /system /mnt/system; do
    [ -d "${_mp}" ] || continue
    if _sys_dir_of "${_mp}" >/dev/null 2>&1; then SYS_MOUNTPOINT="${_mp}"; break; fi
    mount "${_mp}" >/dev/null 2>&1
    if _sys_dir_of "${_mp}" >/dev/null 2>&1; then
      SYS_MOUNTPOINT="${_mp}"
      WE_MOUNTED_SYSTEM=1
      break
    fi
  done

  # 2. Straight from the block device, for recoveries without a usable fstab.
  if [ -z "${SYS_MOUNTPOINT}" ]; then
    _slot="$(getprop ro.boot.slot_suffix 2>/dev/null)"
    mkdir -p /mnt/microg_system 2>/dev/null
    for _dev in \
      "/dev/block/mapper/system${_slot}" \
      "/dev/block/by-name/system${_slot}" \
      "/dev/block/bootdevice/by-name/system${_slot}" \
      /dev/block/platform/*/by-name/system"${_slot}" \
      /dev/block/platform/*/*/by-name/system"${_slot}"; do
      [ -e "${_dev}" ] || continue
      mount -o rw "${_dev}" /mnt/microg_system >/dev/null 2>&1 ||
        mount "${_dev}" /mnt/microg_system >/dev/null 2>&1 || continue
      if _sys_dir_of /mnt/microg_system >/dev/null 2>&1; then
        SYS_MOUNTPOINT='/mnt/microg_system'
        WE_MOUNTED_SYSTEM=1
        break
      fi
      umount /mnt/microg_system >/dev/null 2>&1
    done
  fi

  [ -n "${SYS_MOUNTPOINT}" ] ||
    abort 'Could not find or mount the system partition. Mount /system in your recovery and retry.'

  SYS="$(_sys_dir_of "${SYS_MOUNTPOINT}")"
}

remount_system_rw() {
  mount -o rw,remount "${SYS_MOUNTPOINT}" >/dev/null 2>&1 ||
    mount -o remount,rw "${SYS_MOUNTPOINT}" >/dev/null 2>&1 ||
    mount -o rw,remount / >/dev/null 2>&1 || true

  if ! : > "${SYS}/.microg_rw_test" 2>/dev/null; then
    abort "Cannot write to ${SYS}. Disable dm-verity / mount system read-write and retry."
  fi
  rm -f "${SYS}/.microg_rw_test"
}

unmount_system() {
  if [ "${WE_MOUNTED_SYSTEM:-0}" = 1 ] && [ -n "${SYS_MOUNTPOINT:-}" ]; then
    umount "${SYS_MOUNTPOINT}" >/dev/null 2>&1 || true
  fi
}

# Free space on the system partition, in MiB.
system_free_mib() {
  df -k "${SYS}" 2>/dev/null | awk 'NR>1 && NF>=4 { print int($(NF-2)/1024); exit }'
}

### ------------------------------------------------------------ permissions ----

set_perm() {
  chown "$1:$2" "$4" 2>/dev/null || chown "$1.$2" "$4" 2>/dev/null || true
  chmod "$3" "$4" 2>/dev/null || true
  chcon -h u:object_r:system_file:s0 "$4" >/dev/null 2>&1 || true
}

set_perm_dir() { set_perm 0 0 0755 "$1"; }
set_perm_file() { set_perm 0 0 0644 "$1"; }

### ---------------------------------------------------------- volume  keys ----
# 0 = Volume Up, 1 = Volume Down, 2 = no usable input

KEYS_USABLE=0

keys_init() {
  if command -v getevent >/dev/null 2>&1; then
    KEYS_USABLE=1
  else
    KEYS_USABLE=0
  fi
}

_getevent_chunk() {
  getevent -lqc 3 2>/dev/null || getevent -lc 3 2>/dev/null
}

key_read() {
  [ "${KEYS_USABLE}" = 1 ] || return 2
  _kr_empty=0
  _kr_loops=0
  while [ "${_kr_loops}" -lt 4000 ]; do
    _kr_loops=$((_kr_loops + 1))
    if ! _kr_out="$(_getevent_chunk)"; then
      KEYS_USABLE=0
      return 2
    fi
    if [ -z "${_kr_out}" ]; then
      _kr_empty=$((_kr_empty + 1))
      # getevent returning nothing over and over means there is no input device.
      [ "${_kr_empty}" -lt 20 ] || { KEYS_USABLE=0; return 2; }
      continue
    fi
    # getevent -l prints either the DOWN/UP labels or the raw value.
    if printf '%s\n' "${_kr_out}" | grep -qE 'KEY_VOLUMEUP[[:space:]]+(DOWN|0*1)[[:space:]]*$'; then
      return 0
    fi
    if printf '%s\n' "${_kr_out}" | grep -qE 'KEY_VOLUMEDOWN[[:space:]]+(DOWN|0*1)[[:space:]]*$'; then
      return 1
    fi
  done
  return 2
}

# ask <question> <label for Vol+> <label for Vol-> <default: 0|1>
# Returns 0 when Vol+ was chosen, 1 when Vol- was chosen.
ask() {
  _ask_default="$4"

  # A preseed file wins over the prompt, so the zip can be used unattended.
  if [ -n "${ASK_KEY:-}" ]; then
    _ask_preseed="$(preseed_get "${ASK_KEY}")"
    case "${_ask_preseed}" in
      1|y|yes|true)  ui_print "  ${1}  -> ${2} (preseeded)"; return 0 ;;
      0|n|no|false)  ui_print "  ${1}  -> ${3} (preseeded)"; return 1 ;;
      *) ;;
    esac
  fi

  ui_print ' '
  ui_print "  ${1}"
  ui_print "     Volume UP   = ${2}"
  ui_print "     Volume DOWN = ${3}"

  key_read
  _ask_answer=$?

  if [ "${_ask_answer}" = 2 ]; then
    if [ "${_ask_default}" = 0 ]; then
      ui_print "     no key input available -> ${2}"
    else
      ui_print "     no key input available -> ${3}"
    fi
    return "${_ask_default}"
  fi

  if [ "${_ask_answer}" = 0 ]; then
    ui_print "     -> ${2}"
  else
    ui_print "     -> ${3}"
  fi
  return "${_ask_answer}"
}

### --------------------------------------------------------------- preseed ----
# Optional, for unattended flashing: put a file next to the zip (or on
# /sdcard) with lines such as  AURORA_SERVICES=1

preseed_init() {
  PRESEED_FILE=''
  for _ps in \
    "$(dirname "${ZIPFILE}")/microg-installer.prop" \
    /sdcard/microg-installer.prop \
    /data/media/0/microg-installer.prop \
    /external_sd/microg-installer.prop; do
    if [ -f "${_ps}" ]; then PRESEED_FILE="${_ps}"; break; fi
  done
  [ -n "${PRESEED_FILE}" ] && ui_print "  Using settings from ${PRESEED_FILE}"
  return 0
}

preseed_get() {
  [ -n "${PRESEED_FILE}" ] || return 0
  grep_prop "$1" "${PRESEED_FILE}" 2>/dev/null || true
}

### ----------------------------------------------------------------- misc -----

cleanup() {
  rm -rf "${INSTALLER_DIR:-/nonexistent}/work" 2>/dev/null || true
  unmount_system
}
