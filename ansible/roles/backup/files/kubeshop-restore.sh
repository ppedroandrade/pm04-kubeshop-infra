#!/usr/bin/env bash
# Restaura o banco kubeshop a partir de um backup do Azure Blob Storage.
# Uso: kubeshop-restore.sh <nome-do-backup | latest>
# ATENÇÃO: substitui (--drop) as coleções atuais do banco kubeshop.
set -euo pipefail
# shellcheck disable=SC1091
source /etc/kubeshop/backup.env

target="${1:-latest}"
if [ "${target}" = "latest" ]; then
  target="$(/usr/local/bin/kubeshop-list-backups.sh | tail -n 1)"
fi
if [ -z "${target}" ]; then
  echo "ERRO: nenhum backup encontrado em ${BACKUP_URL}" >&2
  exit 1
fi

tmp="$(mktemp)"
trap 'rm -f "${tmp}"' EXIT

echo "[$(date -u +%FT%TZ)] baixando ${target}"
curl -sS --fail -H "x-ms-version: 2021-08-06" -o "${tmp}" "${BACKUP_URL}/${target}?${BACKUP_SAS}"

count_orders() {
  docker exec kubeshop-mongodb mongosh --quiet --norc --eval '
    const d = db.getSiblingDB("kubeshop");
    d.auth("kubeshop", require("fs").readFileSync("/run/secrets/mongo_app_password", "utf8").trim());
    print(d.orders.countDocuments());' 2>/dev/null || echo "?"
}

echo "pedidos antes da restauração: $(count_orders)"
docker exec -i kubeshop-mongodb mongorestore --quiet \
  --config /run/secrets/mongo_tools_config \
  --username admin --authenticationDatabase admin \
  --archive --gzip --drop --nsInclude 'kubeshop.*' < "${tmp}"
echo "pedidos após a restauração: $(count_orders)"
echo "[$(date -u +%FT%TZ)] restauração concluída a partir de ${target}"
