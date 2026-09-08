#!/sbin/sh
# microg-recovery-installer -- installer
# SPDX-License-Identifier: GPL-3.0-or-later
# shellcheck shell=sh
# shellcheck source=/dev/null

. "${INSTALLER_DIR}/installer/util.sh" || { echo 'Failed to load util.sh'; exit 1; }

CONFIG_DIR="${INSTALLER_DIR}/installer/config"
APPS_LIST="${INSTALLER_DIR}/installer/apps.list"
RECEIPT_DIR='etc/microg-installer'
RECEIPT="${RECEIPT_DIR}/files.list"
ADDOND_NAME='50-microg.sh'
WORK="${INSTALLER_DIR}/work"

MODULE_NAME='microG recovery installer'
MODULE_VERSION="$(grep_prop version "${INSTALLER_DIR}/installer/module.prop" 2>/dev/null || echo 'dev')"

### ------------------------------------------------------------- receipts ----

record() { printf '%s\n' "$1" >> "${WORK}/files.list"; }

read_receipt() {
  [ -f "${SYS}/${RECEIPT}" ] || return 1
  cat "${SYS}/${RECEIPT}"
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

### -------------------------------------------------------------- install ----

# apk_abi <apk> -- first ABI from the device list that the APK actually ships
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

# extract_libs <apk on device> <apk directory>
extract_libs() {
  _el_apk="$1"
  _el_dir="$2"

  if ! _el_abi="$(apk_abi "${_el_apk}")"; then
    ui_print '     no native libraries for this CPU, skipping'
    return 0
  fi
  _el_isa="$(abi_to_isa "${_el_abi}")"
  ui_print "     native libraries: ${_el_abi}"

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
      *64*) _el_libdir="${SYS}/lib64" ;;
      *) _el_libdir="${SYS}/lib" ;;
    esac
    rm -rf "${SYS:?}/.microg_libs"
    unzip -o -q "${_el_apk}" "lib/${_el_abi}/*" -d "${SYS}/.microg_libs" ||
      abort "Failed to extract native libraries from ${_el_apk}"
    mkdir -p "${_el_libdir}"
    for _el_so in "${SYS}/.microg_libs/lib/${_el_abi}"/*; do
      [ -f "${_el_so}" ] || continue
      cp -f "${_el_so}" "${_el_libdir}/" || abort 'Failed to install a native library'
      set_perm 0 0 0644 "${_el_libdir}/$(basename "${_el_so}")"
      record "${_el_libdir#"${SYS}"/}/$(basename "${_el_so}")"
    done
    rm -rf "${SYS:?}/.microg_libs"
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
    _ia_dir="${SYS}/${_ia_target}/${_ia_dest}"
    _ia_rel="${_ia_target}/${_ia_dest}"
  else
    _ia_dir="${SYS}/${_ia_target}"
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
    extract_libs "${_ia_dir}/${_ia_dest}.apk" "${_ia_dir}"
  fi
}

# install_config <source subdir> <dest subdir> <basename> <min api>
install_config() {
  [ "${API}" -ge "$4" ] || return 0
  [ -f "${CONFIG_DIR}/$1/$3" ] || return 0
  mkdir -p "${SYS}/$2" || abort "Failed to create ${SYS}/$2"
  cp -f "${CONFIG_DIR}/$1/$3" "${SYS}/$2/$3" || abort "Failed to install $3"
  set_perm_file "${SYS}/$2/$3"
  record "$2/$3"
}

### ------------------------------------------------------------ addon.d ------

install_addond() {
  [ -d "${SYS}/addon.d" ] || return 0

  # backuptool only knows how to copy individual files, so expand the
  # directories we recorded into the files they actually contain.
  : > "${WORK}/addond.list"
  while IFS= read -r _ad_path; do
    [ -n "${_ad_path}" ] || continue
    if [ -d "${SYS}/${_ad_path}" ]; then
      find "${SYS}/${_ad_path}" -type f 2>/dev/null | sed "s|^${SYS}/||" >> "${WORK}/addond.list"
    else
      # Plain file, or the addon.d script itself, which is written right after
      # this list is built and has to restore itself too.
      printf '%s\n' "${_ad_path}" >> "${WORK}/addond.list"
    fi
  done < "${WORK}/files.list"

  {
    cat "${CONFIG_DIR}/addon.d-head.sh"
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
  while IFS= read -r _du_path; do
    [ -n "${_du_path}" ] || continue
    case "${_du_path}" in
      /*|*..*) continue ;;
    esac
    rm -rf "${SYS:?}/${_du_path:?}" 2>/dev/null || true
  done < "${WORK}/old.list"
  rm -rf "${SYS:?}/${RECEIPT_DIR:?}" 2>/dev/null || true
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
detect_device

ui_print ' '
ui_print "  Device      : ${DEVICE}"
ui_print "  Android     : ${ANDROID_VER} (API ${API})"
ui_print "  ABI         : ${ABI_LIST}"
ui_print "  System path : ${SYS}"

[ "${API}" -ge 19 ] ||
  abort "Android API ${API} is too old for current microG builds (API 19+ required)."

remount_system_rw
preseed_init
keys_init

if [ "${KEYS_USABLE}" != 1 ]; then
  ui_print ' '
  ui_print '  ! Volume keys are not readable here; defaults will be used.'
fi

### --- what to do -------------------------------------------------------------

ALREADY_INSTALLED=0
[ -f "${SYS}/${RECEIPT}" ] && ALREADY_INSTALLED=1

if [ "${ALREADY_INSTALLED}" = 1 ]; then
  ui_print ' '
  ui_print '  A previous installation was found.'
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

### --- space check ------------------------------------------------------------

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
  # native libraries are extracted on top of the apk, so allow ~40% extra
  [ "${LIBS}" = 1 ] && size=$((size + size * 40 / 100))
  NEEDED_KB=$((NEEDED_KB + size / 1024))
done < "${APPS_LIST}"

NEEDED_MIB=$((NEEDED_KB / 1024 + 8))
FREE_MIB="$(system_free_mib)"
ui_print ' '
ui_print "  Space needed: ~${NEEDED_MIB} MiB   available: ${FREE_MIB:-?} MiB"
case "${FREE_MIB}" in
  ''|*[!0-9]*) ;;
  *)
    if [ "${FREE_MIB}" -lt "${NEEDED_MIB}" ]; then
      abort "Not enough free space on ${SYS} (need ~${NEEDED_MIB} MiB, have ${FREE_MIB} MiB)."
    fi
    ;;
esac

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

mkdir -p "${SYS}/${RECEIPT_DIR}" || abort 'Failed to create the receipt directory'
record "${RECEIPT_DIR}"
[ -d "${SYS}/addon.d" ] && record "addon.d/${ADDOND_NAME}"

cp -f "${WORK}/files.list" "${SYS}/${RECEIPT}" || abort 'Failed to write the receipt'
set_perm_file "${SYS}/${RECEIPT}"
printf 'version=%s\ninstalled=%s\n' "${MODULE_VERSION}" "$(date 2>/dev/null || echo unknown)" \
  > "${SYS}/${RECEIPT_DIR}/info.prop" 2>/dev/null || true
set_perm_file "${SYS}/${RECEIPT_DIR}/info.prop"
set_perm_dir "${SYS}/${RECEIPT_DIR}"

install_addond

### --- done -------------------------------------------------------------------

ui_print ' '
ui_rule
ui_print '  Installed:'
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
