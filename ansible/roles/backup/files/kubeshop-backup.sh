#!/usr/bin/env bash
# Backup do banco kubeshop: mongodump (gzip) -> disco local -> Azure Blob Storage.
# A senha é lida dentro do contêiner a partir de um secret (não aparece em argv/logs).
set -euo pipefail
# shellcheck disable=SC1091
source /etc/kubeshop/backup.env

ts="$(date -u +%Y%m%dT%H%M%SZ)"
name="kubeshop-${ENVIRONMENT}-${ts}.archive.gz"
file="${LOCAL_DIR}/${name}"
mkdir -p "${LOCAL_DIR}"

echo "[$(date -u +%FT%TZ)] iniciando backup ${name}"
docker exec kubeshop-mongodb mongodump --quiet \
  --config /run/secrets/mongo_tools_config \
  --username admin --authenticationDatabase admin \
  --db kubeshop --archive --gzip > "${file}"

size="$(stat -c %s "${file}")"
if [ "${size}" -lt 100 ]; then
  echo "ERRO: arquivo de backup vazio ou inválido (${size} bytes)" >&2
  exit 1
fi

curl -sS --fail --retry 3 -X PUT \
  -H "x-ms-blob-type: BlockBlob" \
  -H "x-ms-version: 2021-08-06" \
  --upload-file "${file}" \
  "${BACKUP_URL}/${name}?${BACKUP_SAS}" > /dev/null

find "${LOCAL_DIR}" -name 'kubeshop-*.archive.gz' -mtime "+${RETENTION_DAYS}" -delete

echo "[$(date -u +%FT%TZ)] backup concluído: ${name} (${size} bytes) enviado para ${BACKUP_URL}"
echo "BACKUP_NAME=${name}"
