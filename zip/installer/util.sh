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

PART_MOUNTS=''
DYNAMIC_PARTITIONS=''
BLK_PATH=''
SLOT_SUFFIX=''
SYSTEM_BLOCK=''
EXTRA_MP=''
MOUNTED_BLOCK=''

# Prints the directory that holds build.prop for a given mountpoint, or fails.
_sys_dir_of() {
  if [ -f "$1/system/build.prop" ]; then printf '%s\n' "$1/system"; return 0; fi
  if [ -f "$1/build.prop" ]; then printf '%s\n' "$1"; return 0; fi
  return 1
}

_looks_like_partition() {
  [ -d "$1/priv-app" ] || [ -d "$1/app" ] || [ -d "$1/etc" ]
}

is_mounted() {
  grep -q "[[:space:]]$1[[:space:]]" /proc/mounts 2>/dev/null
}

# The A/B slot this boot belongs to, as the "_a"/"_b" suffix used by partition
# names. Some recoveries do not export the property, hence the cmdline fallback.
find_slot() {
  _fs_slot="$(getprop ro.boot.slot_suffix 2>/dev/null)"
  [ -n "${_fs_slot}" ] ||
    _fs_slot="$(sed -n 's/.*androidboot\.slot_suffix=\([^ ]*\).*/\1/p' /proc/cmdline 2>/dev/null)"
  if [ -z "${_fs_slot}" ]; then
    _fs_bare="$(getprop ro.boot.slot 2>/dev/null)"
    [ -n "${_fs_bare}" ] ||
      _fs_bare="$(sed -n 's/.*androidboot\.slot=\([^ ]*\).*/\1/p' /proc/cmdline 2>/dev/null)"
    [ -n "${_fs_bare}" ] && _fs_slot="_${_fs_bare}"
  fi
  printf '%s\n' "${_fs_slot}"
}

# On a device with dynamic partitions everything lives in super and shows up
# under /dev/block/mapper, which is also where the read-only flag has to be
# cleared before any of it can be mounted read-write.
find_device_block() {
  DYNAMIC_PARTITIONS="$(getprop ro.boot.dynamic_partitions 2>/dev/null)"
  BLK_PATH='/dev/block/bootdevice/by-name'
  if [ -d /dev/block/mapper ]; then
    # shellcheck disable=SC2034  # reported by main.sh
    DYNAMIC_PARTITIONS='true'
    BLK_PATH='/dev/block/mapper'
  elif [ ! -d "${BLK_PATH}" ]; then
    for _fd_dir in /dev/block/by-name /dev/block/platform/*/by-name /dev/block/platform/*/*/by-name; do
      [ -d "${_fd_dir}" ] && BLK_PATH="${_fd_dir}" && break
    done
  fi
  SLOT_SUFFIX="$(find_slot)"
}

# The block device the recovery's own fstab uses for a mountpoint. Both fstab
# layouts are in the wild, so take whichever field is a path under /dev.
fstab_block_for() {
  for _fb_tab in /etc/recovery.fstab /etc/twrp.fstab /etc/fstab /fstab.*; do
    [ -f "${_fb_tab}" ] || continue
    _fb_line="$(grep -v '^[[:space:]]*#' "${_fb_tab}" 2>/dev/null |
      grep "[[:blank:]]$1[[:blank:]]" | tail -n1 | tr -s '[:blank:]' ' ')"
    [ -n "${_fb_line}" ] || continue
    # shellcheck disable=SC2086
    set -- ${_fb_line}
    for _fb_field in "$@"; do
      case "${_fb_field}" in
        /dev/*) printf '%s\n' "${_fb_field}"; return 0 ;;
      esac
    done
  done
  return 1
}

find_block() {
  _fbk_name="$1"
  _fbk_entry="$(fstab_block_for "/${_fbk_name}")" || _fbk_entry=''
  if [ -z "${_fbk_entry}" ] && [ "${_fbk_name}" = 'system' ]; then
    _fbk_entry="$(fstab_block_for '/')" || _fbk_entry="$(fstab_block_for '/system_root')" || _fbk_entry=''
  fi
  _fbk_base="${_fbk_entry##*/}"

  for _fbk_dev in \
    "${_fbk_entry:+${_fbk_entry}${SLOT_SUFFIX}}" \
    "${_fbk_entry}" \
    "${_fbk_base:+${BLK_PATH}/${_fbk_base}${SLOT_SUFFIX}}" \
    "${_fbk_base:+${BLK_PATH}/${_fbk_base}}" \
    "${BLK_PATH}/${_fbk_name}${SLOT_SUFFIX}" \
    "${BLK_PATH}/${_fbk_name}" \
    "/dev/block/mapper/${_fbk_name}${SLOT_SUFFIX}" \
    "/dev/block/mapper/${_fbk_name}" \
    "/dev/block/by-name/${_fbk_name}${SLOT_SUFFIX}" \
    "/dev/block/by-name/${_fbk_name}" \
    "/dev/block/bootdevice/by-name/${_fbk_name}${SLOT_SUFFIX}" \
    "/dev/block/bootdevice/by-name/${_fbk_name}" \
    /dev/block/platform/*/by-name/"${_fbk_name}${SLOT_SUFFIX}" \
    /dev/block/platform/*/*/by-name/"${_fbk_name}${SLOT_SUFFIX}"; do
    [ -n "${_fbk_dev}" ] || continue
    [ -b "${_fbk_dev}" ] || continue
    printf '%s\n' "${_fbk_dev}"
    return 0
  done
  return 1
}

# Logical partitions come up read-only at the block layer, and no mount option
# gets past that. This is why remounting system read-write silently did nothing.
unlock_block() {
  [ -n "$1" ] || return 0
  blockdev --setrw "$1" >/dev/null 2>&1 || true
}

unlock_partition() {
  _up_dev="$(find_block "$1")" || return 1
  unlock_block "${_up_dev}"
  printf '%s\n' "${_up_dev}"
}

# Clears a symlink or a stray file out of the way so something can be mounted
# on the path. /product is a symlink into system on devices that have no such
# partition, and a mountpoint on devices that do.
setup_mountpoint() {
  if [ -L "$1" ]; then
    mv -f "$1" "$1_link" 2>/dev/null || rm -f "$1" 2>/dev/null
  fi
  [ -d "$1" ] && return 0
  rm -f "$1" 2>/dev/null
  mkdir -p "$1" 2>/dev/null
}

mount_system() {
  SYS_MOUNTPOINT=''
  SYS=''
  WE_MOUNTED_SYSTEM=0

  find_device_block
  SYSTEM_BLOCK="$(unlock_partition system)" || SYSTEM_BLOCK=''

  for _mp in /system_root /system /mnt/system; do
    [ -d "${_mp}" ] || continue
    if _sys_dir_of "${_mp}" >/dev/null 2>&1; then SYS_MOUNTPOINT="${_mp}"; break; fi
    mount -o rw "${_mp}" >/dev/null 2>&1 || mount "${_mp}" >/dev/null 2>&1
    if _sys_dir_of "${_mp}" >/dev/null 2>&1; then
      SYS_MOUNTPOINT="${_mp}"
      WE_MOUNTED_SYSTEM=1
      break
    fi
  done

  if [ -z "${SYS_MOUNTPOINT}" ] && [ -n "${SYSTEM_BLOCK}" ]; then
    mkdir -p /mnt/microg_system 2>/dev/null
    if mount -o rw -t auto "${SYSTEM_BLOCK}" /mnt/microg_system >/dev/null 2>&1 ||
      mount -t auto "${SYSTEM_BLOCK}" /mnt/microg_system >/dev/null 2>&1; then
      if _sys_dir_of /mnt/microg_system >/dev/null 2>&1; then
        SYS_MOUNTPOINT='/mnt/microg_system'
        WE_MOUNTED_SYSTEM=1
      else
        umount /mnt/microg_system >/dev/null 2>&1
      fi
    fi
  fi

  [ -n "${SYS_MOUNTPOINT}" ] ||
    abort 'Could not find or mount the system partition. Mount /system in your recovery and retry.'

  # shellcheck disable=SC2034  # used throughout main.sh
  SYS="$(_sys_dir_of "${SYS_MOUNTPOINT}")"
}

# Mounts a secondary partition (product, system_ext) and sets EXTRA_MP.
# It sets a variable instead of printing one because callers used to run it in a
# command substitution, which lost the PART_MOUNTS bookkeeping in the subshell.
mount_extra_partition() {
  EXTRA_MP=''
  # shellcheck disable=SC2034  # reported by main.sh
  MOUNTED_BLOCK=''
  _me_dev="$(unlock_partition "$1")" || return 1
  # shellcheck disable=SC2034  # reported by main.sh
  MOUNTED_BLOCK="${_me_dev}"
  _me_mp="/$1"

  if is_mounted "${_me_mp}" && _looks_like_partition "${_me_mp}"; then
    mount -o rw,remount -t auto "${_me_mp}" >/dev/null 2>&1 || true
    # shellcheck disable=SC2034  # read by main.sh
    EXTRA_MP="${_me_mp}"
    return 0
  fi

  setup_mountpoint "${_me_mp}" || _me_mp="/mnt/microg_$1"
  [ -d "${_me_mp}" ] || mkdir -p "${_me_mp}" 2>/dev/null || return 1

  mount -o rw -t auto "${_me_dev}" "${_me_mp}" >/dev/null 2>&1 ||
    mount -t auto "${_me_dev}" "${_me_mp}" >/dev/null 2>&1 ||
    mount "${_me_dev}" "${_me_mp}" >/dev/null 2>&1 || return 1

  if ! _looks_like_partition "${_me_mp}"; then
    umount "${_me_mp}" >/dev/null 2>&1
    return 1
  fi
  mount -o rw,remount -t auto "${_me_mp}" >/dev/null 2>&1 || true
  PART_MOUNTS="${PART_MOUNTS} ${_me_mp}"
  # shellcheck disable=SC2034  # read by main.sh
  EXTRA_MP="${_me_mp}"
  return 0
}

# Every mountpoint whose last path component is $1, straight from the kernel.
# Recoveries mount system_ext and product wherever they like, so asking is more
# reliable than guessing at a list of paths.
mounted_paths_named() {
  [ -r /proc/mounts ] || return 0
  while read -r _mp_dev _mp_path _mp_junk; do
    case "${_mp_path}" in
      */"$1") printf '%s\n' "${_mp_path}" ;;
    esac
  done < /proc/mounts
}

# Remounts the filesystem holding a path read-write. The path is usually a
# directory inside the mount (/system_root/system, /system/product), and
# remounting a plain directory is a no-op, so resolve the mountpoint first.
remount_rw() {
  # shellcheck disable=SC2046
  set -- $(df_info "$1") "$1"
  if [ "$#" -ge 4 ]; then
    _rr_dev="$1"
    _rr_mp="$3"
    _rr_path="$4"
  else
    _rr_dev=''
    _rr_mp="$1"
    _rr_path="$1"
  fi
  unlock_block "${_rr_dev}"
  mount -o rw,remount -t auto "${_rr_mp}" >/dev/null 2>&1 ||
    mount -o remount,rw "${_rr_mp}" >/dev/null 2>&1 ||
    mount -o rw,remount "${_rr_path}" >/dev/null 2>&1 || true
}

# The redirect runs in a subshell on purpose: ":" is a POSIX special builtin,
# and a redirection error on one aborts the whole shell instead of returning.
is_writable() {
  ( : > "$1/.microg_rw_test" ) 2>/dev/null || return 1
  rm -f "$1/.microg_rw_test"
}

remount_system_rw() {
  remount_rw "${SYS}"
  remount_rw "${SYS_MOUNTPOINT}"
  [ "${SYS_MOUNTPOINT}" = '/' ] || remount_rw /
  is_writable "${SYS}"
}

unmount_system() {
  for _um in ${PART_MOUNTS}; do
    umount "${_um}" >/dev/null 2>&1 || true
  done
  PART_MOUNTS=''
  if [ "${WE_MOUNTED_SYSTEM:-0}" = 1 ] && [ -n "${SYS_MOUNTPOINT:-}" ]; then
    umount "${SYS_MOUNTPOINT}" >/dev/null 2>&1 || true
  fi
}

# Prints "<filesystem> <free MiB> <mountpoint>" for the fs holding a path.
# Collapsing every field after the header copes with df wrapping a long device
# name onto its own line. Deliberately free of awk: this has to keep working
# even if the bundled busybox could not be started.
df_info() {
  _di_row=''
  _di_skip=1
  while IFS= read -r _di_line; do
    if [ "${_di_skip}" = 1 ]; then
      _di_skip=0
      continue
    fi
    _di_row="${_di_row} ${_di_line}"
  done <<DF_EOF
$(df -k "$1" 2>/dev/null)
DF_EOF

  # shellcheck disable=SC2086
  set -- ${_di_row}
  [ "$#" -ge 5 ] || return 1
  _di_fs="$1"
  while [ "$#" -gt 3 ]; do shift; done
  case "$1" in
    '' | *[!0-9]*) return 1 ;;
  esac
  printf '%s %s %s\n' "${_di_fs}" "$(($1 / 1024))" "$3"
}

mountpoint_of() {
  # shellcheck disable=SC2046
  set -- $(df_info "$1")
  [ "$#" -ge 3 ] && printf '%s\n' "$3"
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
