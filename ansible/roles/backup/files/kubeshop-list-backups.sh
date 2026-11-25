#!/usr/bin/env bash
# Lista os backups guardados no Azure Blob Storage (mais recentes por último).
set -euo pipefail
# shellcheck disable=SC1091
source /etc/kubeshop/backup.env

curl -sS --fail -H "x-ms-version: 2021-08-06" \
  "${BACKUP_URL}?restype=container&comp=list&${BACKUP_SAS}" \
  | grep -o '<Name>[^<]*</Name>' | sed -e 's/<Name>//' -e 's/<\/Name>//' | sort
