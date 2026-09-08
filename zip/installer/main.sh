#!/sbin/sh
# microg-recovery-installer -- installer
# SPDX-License-Identifier: GPL-3.0-or-later
# shellcheck shell=sh
# shellcheck source=/dev/null

. "${INSTALLER_DIR}/installer/util.sh" || { echo 'Failed to load util.sh'; exit 1; }

CONFIG_DIR="${INSTALLER_DIR}/installer/config"
APPS_LIST="${INSTALLER_DIR}/installer/apps.list"
LIB_SIZES="${INSTALLER_DIR}/installer/libsizes.list"
RECEIPT_DIR='etc/microg-installer'
RECEIPT="${RECEIPT_DIR}/files.list"
ADDOND_NAME='50-microg.sh'
WORK="${INSTALLER_DIR}/work"

MODULE_NAME='microG recovery installer'
MODULE_VERSION="$(grep_prop version "${INSTALLER_DIR}/installer/module.prop" 2>/dev/null || echo 'dev')"

# Filled in once the partitions have been probed.
TARGET_NAME=''
TARGET_ROOT=''
TARGET_DEVPATH=''
OLD_ROOT=''
OLD_NAME=''

### ------------------------------------------------------------- receipts ----

record() { printf '%s\n' "$1" >> "${WORK}/files.list"; }

read_receipt() {
  [ -n "${OLD_ROOT}" ] && [ -f "${OLD_ROOT}/${RECEIPT}" ] || return 1
  cat "${OLD_ROOT}/${RECEIPT}"
}

### --------------------------------------------------------------- device ----

detect_device() {
  API="$(grep_prop ro.build.version.sdk "${SYS}/build.prop" "${SYS_MOUNTPOINT}/build.prop")" ||
    API="$(getprop ro.build.version.sdk 2>/dev/null)"
  case "${API}" in
    ''|*[!0-9]*) abort 'Could not determine the Android API level' ;;
    *) ;;
  esac

  ABI_LIST="$(grep_prop ro.product.cpu.abilist "${SYS}/build.prop")" || ABI_LIST=''
  if [ -z "${ABI_LIST}" ]; then
    _abi="$(grep_prop ro.product.cpu.abi "${SYS}/build.prop")" || _abi=''
    _abi2="$(grep_prop ro.product.cpu.abi2 "${SYS}/build.prop")" || _abi2=''
    ABI_LIST="${_abi}${_abi2:+,${_abi2}}"
  fi
  [ -n "${ABI_LIST}" ] || ABI_LIST="$(getprop ro.product.cpu.abilist 2>/dev/null)"
  [ -n "${ABI_LIST}" ] || abort 'Could not determine the CPU ABI'

  DEVICE="$(grep_prop ro.product.device "${SYS}/build.prop")" || DEVICE='unknown'
  ANDROID_VER="$(grep_prop ro.build.version.release "${SYS}/build.prop")" || ANDROID_VER='?'
}

# Maps an ABI to the instruction set directory name Android expects.
abi_to_isa() {
  case "$1" in
    arm64-v8a) printf 'arm64\n' ;;
    armeabi-v7a|armeabi|armeabi-v7a-hard) printf 'arm\n' ;;
    *) printf '%s\n' "$1" ;;
  esac
}

### ----------------------------------------------------------- partitions ----
# Android reads priv-app/app and etc/permissions out of /system, /system_ext and
# /product alike, so any of them is a valid install target. parts.list holds one
# "name|path|device path" row per usable candidate, in preference order. The
# device path is where the partition lives on a booted system and is written
# into the addon.d script verbatim, where backuptool expands $S for us.

# shellcheck disable=SC2016
ADDOND_S='${S}'

# Every root we found, whether or not it is a valid target. A previous install
# has to be findable even on a partition we would no longer install to.
_root_add() {
  printf '%s|%s\n' "$1" "$2" >> "${WORK}/roots.list"
}

_part_add() {
  remount_rw "$2"
  if ! is_writable "$2"; then
    ui_print "  ! ${1} is not writable, skipping"
    return 1
  fi
  printf '%s|%s|%s\n' "$1" "$2" "$3" >> "${WORK}/parts.list"
}

# Android only honours a privileged permission whitelist that sits on the same
# partition as the app. A whitelist the ROM itself shipped there is proof the
# platform reads them from that partition, which beats guessing from the API
# level -- some Android 10 builds carry system_ext, some Android 11 ones do not
# populate product. Below API 26 whitelists are not enforced at all.
_reads_privapp_permissions() {
  [ "${API}" -ge 26 ] || return 0
  for _rp in "$1"/etc/permissions/privapp-permissions*.xml; do
    [ -f "${_rp}" ] && return 0
  done
  return 1
}

_probe_extra_partition() {
  _pep_path=''
  _pep_dev=''
  if [ -d "${SYS}/$1" ] && [ ! -L "${SYS}/$1" ] && _looks_like_partition "${SYS}/$1"; then
    _pep_path="${SYS}/$1"
    _pep_dev="${ADDOND_S}/$1"
  elif [ "${SYS_MOUNTPOINT}" != "${SYS}" ] && [ -d "${SYS_MOUNTPOINT}/$1" ] &&
    [ ! -L "${SYS_MOUNTPOINT}/$1" ] && _looks_like_partition "${SYS_MOUNTPOINT}/$1"; then
    _pep_path="${SYS_MOUNTPOINT}/$1"
    _pep_dev="/$1"
  elif _pep_path="$(mount_extra_partition "$1")"; then
    _pep_dev="/$1"
  else
    return 1
  fi
  _root_add "$1" "${_pep_path}"

  if ! _reads_privapp_permissions "${_pep_path}"; then
    ui_print "  ! ${1} carries no privileged permission whitelist, skipping it"
    return 1
  fi
  _part_add "$1" "${_pep_path}" "${_pep_dev}"
}

probe_partitions() {
  : > "${WORK}/parts.list"
  : > "${WORK}/roots.list"
  _root_add 'system' "${SYS}"
  _part_add 'system' "${SYS}" "${ADDOND_S}"
  _probe_extra_partition 'system_ext'
  _probe_extra_partition 'product'
  [ -s "${WORK}/parts.list" ] ||
    abort 'Nothing writable to install to. Disable dm-verity / mount system read-write and retry.'
}

find_existing_install() {
  while IFS='|' read -r _fe_name _fe_path; do
    if [ -f "${_fe_path}/${RECEIPT}" ]; then
      OLD_NAME="${_fe_name}"
      OLD_ROOT="${_fe_path}"
      return 0
    fi
  done < "${WORK}/roots.list"
  return 1
}

# Picks the partition with the most free space that fits, printing the sizes as
# it goes. Candidates sharing a filesystem with an earlier one are not choices.
choose_target() {
  _ct_best_free=-1
  _ct_seen=''

  ui_print ' '
  ui_print "  Space needed: ~${NEEDED_MIB} MiB"
  while IFS='|' read -r _ct_name _ct_path _ct_dev; do
    # shellcheck disable=SC2046  # df_info prints two fields to split on
    set -- $(df_info "${_ct_path}")
    if [ "$#" -lt 2 ]; then
      ui_print "    ${_ct_name}: size unknown"
      continue
    fi
    _ct_fsid="$1"
    _ct_free="$2"

    case " ${_ct_seen} " in
      *" ${_ct_fsid} "*)
        ui_print "    ${_ct_name}: ${_ct_free} MiB free (same filesystem as an earlier one)"
        continue
        ;;
    esac
    _ct_seen="${_ct_seen} ${_ct_fsid}"
    ui_print "    ${_ct_name}: ${_ct_free} MiB free"

    [ "${_ct_free}" -ge "${NEEDED_MIB}" ] || continue
    if [ "${_ct_free}" -gt "${_ct_best_free}" ]; then
      _ct_best_free="${_ct_free}"
      TARGET_NAME="${_ct_name}"
      TARGET_ROOT="${_ct_path}"
      TARGET_DEVPATH="${_ct_dev}"
    fi
  done < "${WORK}/parts.list"

  _ct_forced="$(preseed_get PARTITION)"
  if [ -n "${_ct_forced}" ]; then
    TARGET_NAME=''
    TARGET_ROOT=''
    while IFS='|' read -r _ct_name _ct_path _ct_dev; do
      [ "${_ct_name}" = "${_ct_forced}" ] || continue
      # shellcheck disable=SC2046
      set -- $(df_info "${_ct_path}")
      if [ "$#" -ge 2 ] && [ "$2" -lt "${NEEDED_MIB}" ]; then
        abort "The preseed file asks for ${_ct_forced}, which has only $2 MiB free."
      fi
      TARGET_NAME="${_ct_name}"
      TARGET_ROOT="${_ct_path}"
      TARGET_DEVPATH="${_ct_dev}"
      ui_print "  Partition forced to ${TARGET_NAME} by the preseed file"
    done < "${WORK}/parts.list"
    [ -n "${TARGET_ROOT}" ] ||
      abort "The preseed file asks for partition ${_ct_forced}, which is not usable here."
  fi

  [ -n "${TARGET_ROOT}" ] ||
    abort "No partition has ~${NEEDED_MIB} MiB free. Free some space and retry."
  ui_print "  Installing to: ${TARGET_NAME} (${TARGET_ROOT})"
}

### -------------------------------------------------------------- install ----

# select_abi <dest> -- first device ABI the apk ships libraries for, from the
# table CI built. Only that one is installed; the others stay unpacked.
select_abi() {
  [ -f "${LIB_SIZES}" ] || return 1
  _sa_ifs="${IFS}"
  IFS=','
  for _sa_abi in ${ABI_LIST}; do
    IFS="${_sa_ifs}"
    [ -n "${_sa_abi}" ] || continue
    if grep -q "^$1|${_sa_abi}|" "${LIB_SIZES}" 2>/dev/null; then
      printf '%s\n' "${_sa_abi}"
      return 0
    fi
    IFS=','
  done
  IFS="${_sa_ifs}"
  return 1
}

lib_bytes() {
  grep -m1 "^$1|$2|" "${LIB_SIZES}" 2>/dev/null | cut -d'|' -f3
}

# apk_abi <apk> -- same choice made by reading the apk, when libsizes is absent
apk_abi() {
  _aa_have="$(unzip -l "$1" 'lib/*' 2>/dev/null | awk '{ print $NF }' | grep '^lib/' | cut -d/ -f2 | sort -u)"
  [ -n "${_aa_have}" ] || return 1
  _aa_old_ifs="${IFS}"
  IFS=','
  for _aa_abi in ${ABI_LIST}; do
    IFS="${_aa_old_ifs}"
    [ -n "${_aa_abi}" ] || continue
    if printf '%s\n' "${_aa_have}" | grep -qx "${_aa_abi}"; then
      printf '%s\n' "${_aa_abi}"
      return 0
    fi
    IFS=','
  done
  IFS="${_aa_old_ifs}"
  return 1
}

# extract_libs <apk on device> <apk directory> <dest>
extract_libs() {
  _el_apk="$1"
  _el_dir="$2"

  if ! _el_abi="$(select_abi "$3")" && ! _el_abi="$(apk_abi "${_el_apk}")"; then
    ui_print '     no native libraries for this CPU, skipping'
    return 0
  fi
  _el_isa="$(abi_to_isa "${_el_abi}")"
  ui_print "     native libraries: ${_el_abi} only"

  if [ "${API}" -ge 21 ]; then
    # Cluster install: Android looks for <apk dir>/lib/<isa>/*.so
    rm -rf "${_el_dir:?}/lib"
    unzip -o -q "${_el_apk}" "lib/${_el_abi}/*" -d "${_el_dir}" ||
      abort "Failed to extract native libraries from ${_el_apk}"
    [ -d "${_el_dir}/lib/${_el_abi}" ] || abort "Native libraries missing after extraction"
    if [ "${_el_abi}" != "${_el_isa}" ]; then
      mv "${_el_dir}/lib/${_el_abi}" "${_el_dir}/lib/${_el_isa}" ||
        abort 'Failed to name the native library directory'
    fi
    set_perm_dir "${_el_dir}/lib"
    set_perm_dir "${_el_dir}/lib/${_el_isa}"
    for _el_so in "${_el_dir}/lib/${_el_isa}"/*; do
      [ -f "${_el_so}" ] && set_perm 0 0 0644 "${_el_so}"
    done
  else
    # Pre-Lollipop bundled apps load their libraries from /system/lib[64].
    case "${_el_abi}" in
      *64*) _el_libdir="${TARGET_ROOT}/lib64" ;;
      *) _el_libdir="${TARGET_ROOT}/lib" ;;
    esac
    rm -rf "${TARGET_ROOT:?}/.microg_libs"
    unzip -o -q "${_el_apk}" "lib/${_el_abi}/*" -d "${TARGET_ROOT}/.microg_libs" ||
      abort "Failed to extract native libraries from ${_el_apk}"
    mkdir -p "${_el_libdir}"
    for _el_so in "${TARGET_ROOT}/.microg_libs/lib/${_el_abi}"/*; do
      [ -f "${_el_so}" ] || continue
      cp -f "${_el_so}" "${_el_libdir}/" || abort 'Failed to install a native library'
      set_perm 0 0 0644 "${_el_libdir}/$(basename "${_el_so}")"
      record "${_el_libdir#"${TARGET_ROOT}"/}/$(basename "${_el_so}")"
    done
    rm -rf "${TARGET_ROOT:?}/.microg_libs"
  fi
}

# install_app <name> <target> <dest> <extract_libs>
install_app() {
  _ia_name="$1"
  _ia_target="$2"
  _ia_dest="$3"
  _ia_libs="$4"

  # priv-app only exists from KitKat onwards.
  [ "${API}" -ge 19 ] || _ia_target='app'

  if [ "${API}" -ge 21 ]; then
    _ia_dir="${TARGET_ROOT}/${_ia_target}/${_ia_dest}"
    _ia_rel="${_ia_target}/${_ia_dest}"
  else
    _ia_dir="${TARGET_ROOT}/${_ia_target}"
    _ia_rel="${_ia_target}/${_ia_dest}.apk"
  fi

  ui_print "  ${_ia_name}"
  mkdir -p "${_ia_dir}" || abort "Failed to create ${_ia_dir}"
  unzip -p "${ZIPFILE}" "apps/${_ia_dest}.apk" > "${_ia_dir}/${_ia_dest}.apk" ||
    abort "Failed to write ${_ia_dest}.apk"
  [ -s "${_ia_dir}/${_ia_dest}.apk" ] || abort "${_ia_dest}.apk came out empty"

  set_perm_dir "${_ia_dir}"
  set_perm_file "${_ia_dir}/${_ia_dest}.apk"
  record "${_ia_rel}"

  if [ "${_ia_libs}" = 1 ]; then
    extract_libs "${_ia_dir}/${_ia_dest}.apk" "${_ia_dir}" "${_ia_dest}"
  fi
}

# install_config <source subdir> <dest subdir> <basename> <min api>
install_config() {
  [ "${API}" -ge "$4" ] || return 0
  [ -f "${CONFIG_DIR}/$1/$3" ] || return 0
  mkdir -p "${TARGET_ROOT}/$2" || abort "Failed to create ${TARGET_ROOT}/$2"
  cp -f "${CONFIG_DIR}/$1/$3" "${TARGET_ROOT}/$2/$3" || abort "Failed to install $3"
  set_perm_file "${TARGET_ROOT}/$2/$3"
  record "$2/$3"
}

### ------------------------------------------------------------ addon.d ------

install_addond() {
  [ -d "${SYS}/addon.d" ] || return 0
  is_writable "${SYS}/addon.d" || return 0

  # backuptool only knows how to copy individual files, so expand the
  # directories we recorded into the files they actually contain.
  : > "${WORK}/addond.list"
  while IFS= read -r _ad_path; do
    [ -n "${_ad_path}" ] || continue
    if [ -d "${TARGET_ROOT}/${_ad_path}" ]; then
      find "${TARGET_ROOT}/${_ad_path}" -type f 2>/dev/null |
        sed "s|^${TARGET_ROOT}/||" >> "${WORK}/addond.list"
    else
      printf '%s\n' "${_ad_path}" >> "${WORK}/addond.list"
    fi
  done < "${WORK}/files.list"

  {
    cat "${CONFIG_DIR}/addon.d-head.sh"
    printf 'MICROG_ROOT="%s"\n\n' "${TARGET_DEVPATH}"
    printf 'list_files() {\ncat <<%s\n' "'MICROG_ADDOND_LIST'"
    cat "${WORK}/addond.list"
    cat "${CONFIG_DIR}/addon.d-tail.sh"
  } > "${SYS}/addon.d/${ADDOND_NAME}" || abort 'Failed to install the addon.d survival script'
  set_perm 0 0 0755 "${SYS}/addon.d/${ADDOND_NAME}"
  ui_print '  addon.d survival script (survives dirty ROM updates)'
}

### ----------------------------------------------------------- uninstall -----

do_uninstall() {
  _du_quiet="${1:-0}"
  if ! read_receipt > "${WORK}/old.list" 2>/dev/null; then
    [ "${_du_quiet}" = 1 ] || ui_print '  Nothing recorded as installed.'
    return 0
  fi
  if ! is_writable "${OLD_ROOT}"; then
    ui_print "  ! ${OLD_NAME} is read-only, the old files cannot be removed"
    return 1
  fi
  while IFS= read -r _du_path; do
    [ -n "${_du_path}" ] || continue
    case "${_du_path}" in
      /*|*..*) continue ;;
    esac
    rm -rf "${OLD_ROOT:?}/${_du_path:?}" 2>/dev/null || true
  done < "${WORK}/old.list"
  rm -rf "${OLD_ROOT:?}/${RECEIPT_DIR:?}" 2>/dev/null || true
  rm -f "${SYS}/addon.d/${ADDOND_NAME}" 2>/dev/null || true
  [ "${_du_quiet}" = 1 ] || ui_print '  Removed the previous installation.'
}

### ----------------------------------------------------------------- main ----

detect_bootmode

ui_print ' '
ui_rule
ui_print "  ${MODULE_NAME} ${MODULE_VERSION}"
ui_print '  microG GmsCore + GSF + FakeStore + Aurora Store'
ui_rule

[ "${BOOTMODE}" = 'true' ] &&
  abort 'This zip must be flashed from a custom recovery, not from a booted system.'

mkdir -p "${WORK}" || abort 'Failed to create the work directory'
: > "${WORK}/files.list"

[ -f "${APPS_LIST}" ] ||
  abort 'apps.list is missing. This looks like the repo skeleton rather than a release zip.'

mount_system
if remount_system_rw; then
  SYS_ACCESS='read-write'
else
  SYS_ACCESS='READ-ONLY'
fi
detect_device

ui_print ' '
ui_print "  Device      : ${DEVICE}"
ui_print "  Android     : ${ANDROID_VER} (API ${API})"
ui_print "  ABI         : ${ABI_LIST}"
ui_print "  System path : ${SYS} (${SYS_ACCESS})"

[ "${API}" -ge 19 ] ||
  abort "Android API ${API} is too old for current microG builds (API 19+ required)."

preseed_init
probe_partitions
keys_init

if [ "${KEYS_USABLE}" != 1 ]; then
  ui_print ' '
  ui_print '  ! Volume keys are not readable here; defaults will be used.'
fi

### --- what to do -------------------------------------------------------------

if find_existing_install; then
  ui_print ' '
  ui_print "  A previous installation was found on ${OLD_NAME}."
  if ASK_KEY='ACTION' ask 'What do you want to do?' 'Reinstall / update' 'Uninstall' 0; then
    : # reinstall
  else
    ui_print ' '
    ui_print '  Uninstalling...'
    do_uninstall
    ui_print ' '
    ui_rule
    ui_print '  Done. Reboot and let the system settle.'
    ui_rule
    ui_print ' '
    cleanup
    # shellcheck disable=SC2034
    INSTALL_STATUS=0
    # main.sh is sourced by update-binary, so return; exit is the fallback.
    # shellcheck disable=SC2317
    return 0 2>/dev/null || exit 0
  fi
fi

### --- optional components ----------------------------------------------------

while IFS='|' read -r KEY NAME TARGET DEST PACKAGE OPTIONAL LIBS VERSION; do
  [ -n "${KEY}" ] || continue
  if [ "${OPTIONAL}" = 1 ]; then
    if ASK_KEY="${KEY}" ask "Install ${NAME}?" 'Yes' 'No' 0; then
      eval "WANT_${KEY}=1"
    else
      eval "WANT_${KEY}=0"
    fi
  else
    eval "WANT_${KEY}=1"
  fi
done < "${APPS_LIST}"

### --- make room -------------------------------------------------------------

ui_print ' '
ui_print '  Cleaning up any previous installation...'
do_uninstall 1

### --- sizing ----------------------------------------------------------------

NEEDED_KB=0
want=0  # set per component by the eval below
# shellcheck disable=SC2034  # PACKAGE is documentation for the manifest format
while IFS='|' read -r KEY NAME TARGET DEST PACKAGE OPTIONAL LIBS VERSION; do
  [ -n "${KEY}" ] || continue
  eval "want=\${WANT_${KEY}:-0}"
  [ "${want}" = 1 ] || continue
  size="$(unzip -l "${ZIPFILE}" "apps/${DEST}.apk" 2>/dev/null | awk '$NF ~ /\.apk$/ { print $1; exit }')"
  case "${size}" in
    ''|*[!0-9]*) size=0 ;;
  esac
  # the apk keeps every ABI; only the one we unpack alongside it adds to this
  if [ "${LIBS}" = 1 ]; then
    if abi="$(select_abi "${DEST}")"; then
      size=$((size + $(lib_bytes "${DEST}" "${abi}")))
    else
      size=$((size + size * 40 / 100))
    fi
  fi
  NEEDED_KB=$((NEEDED_KB + size / 1024))
done < "${APPS_LIST}"

NEEDED_MIB=$((NEEDED_KB / 1024 + 8))
choose_target

### --- install ----------------------------------------------------------------

ui_print ' '
ui_print '  Installing:'

INSTALLED_SUMMARY=''
want=0  # set per component by the eval below
# shellcheck disable=SC2034  # PACKAGE is documentation for the manifest format
while IFS='|' read -r KEY NAME TARGET DEST PACKAGE OPTIONAL LIBS VERSION; do
  [ -n "${KEY}" ] || continue
  eval "want=\${WANT_${KEY}:-0}"
  [ "${want}" = 1 ] || continue

  install_app "${NAME} ${VERSION}" "${TARGET}" "${DEST}" "${LIBS}"

  if [ "${TARGET}" = 'priv-app' ]; then
    install_config permissions etc/permissions "privapp-permissions-${DEST}.xml" 26
  fi
  install_config default-permissions etc/default-permissions "default-permissions-${DEST}.xml" 23

  INSTALLED_SUMMARY="${INSTALLED_SUMMARY}    ${NAME} ${VERSION}
"
done < "${APPS_LIST}"

install_config sysconfig etc/sysconfig microg.xml 21

### --- receipt + addon.d ------------------------------------------------------

mkdir -p "${TARGET_ROOT}/${RECEIPT_DIR}" || abort 'Failed to create the receipt directory'
record "${RECEIPT_DIR}"

cp -f "${WORK}/files.list" "${TARGET_ROOT}/${RECEIPT}" || abort 'Failed to write the receipt'
set_perm_file "${TARGET_ROOT}/${RECEIPT}"
printf 'version=%s\npartition=%s\ninstalled=%s\n' \
  "${MODULE_VERSION}" "${TARGET_NAME}" "$(date 2>/dev/null || echo unknown)" \
  > "${TARGET_ROOT}/${RECEIPT_DIR}/info.prop" 2>/dev/null || true
set_perm_file "${TARGET_ROOT}/${RECEIPT_DIR}/info.prop"
set_perm_dir "${TARGET_ROOT}/${RECEIPT_DIR}"

install_addond

### --- done -------------------------------------------------------------------

ui_print ' '
ui_rule
ui_print "  Installed to ${TARGET_NAME}:"
printf '%s' "${INSTALLED_SUMMARY}" | while IFS= read -r line; do
  [ -n "${line}" ] && ui_print "${line}"
done
ui_print ' '
ui_print '  Next: reboot, then open microG Settings and'
ui_print '  turn on "Google device registration" + "Cloud Messaging".'
ui_print '  Signature spoofing must be supported by your ROM.'
ui_rule
ui_print ' '

cleanup
# shellcheck disable=SC2034
INSTALL_STATUS=0
