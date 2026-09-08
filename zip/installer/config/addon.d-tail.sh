MICROG_ADDOND_LIST
}

case "$1" in
  backup)
    echo 'Backing up microG...'
    list_files | while read -r FILE; do
      [ -n "${FILE}" ] || continue
      backup_file "${S}/${FILE}"
    done
    ;;
  restore)
    echo 'Restoring microG...'
    list_files | while read -r FILE; do
      [ -n "${FILE}" ] || continue
      [ -f "${C}/${S}/${FILE}" ] && restore_file "${S}/${FILE}"
    done
    ;;
  pre-backup|post-backup|pre-restore|post-restore)
    ;;
  *)
    echo "microG addon.d: unknown phase $1" >&2
    ;;
esac
