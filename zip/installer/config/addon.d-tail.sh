MICROG_ADDOND_LIST
}

SELF="${S}/addon.d/50-microg.sh"

case "$1" in
  backup)
    echo "Backing up microG from ${MICROG_ROOT}..."
    backup_file "${SELF}"
    list_files | while read -r FILE; do
      [ -n "${FILE}" ] || continue
      backup_file "${MICROG_ROOT}/${FILE}"
    done
    ;;
  restore)
    echo "Restoring microG to ${MICROG_ROOT}..."
    [ -f "${C}/${SELF}" ] && restore_file "${SELF}"
    list_files | while read -r FILE; do
      [ -n "${FILE}" ] || continue
      [ -f "${C}/${MICROG_ROOT}/${FILE}" ] && restore_file "${MICROG_ROOT}/${FILE}"
    done
    ;;
  pre-backup|post-backup|pre-restore|post-restore)
    ;;
  *)
    echo "microG addon.d: unknown phase $1" >&2
    ;;
esac
