#!/usr/bin/env bash
# Cria (de forma idempotente) a conta de armazenamento compartilhada que guarda:
#   - tfstate          -> Terraform State de cada ambiente (dev.tfstate, homolog.tfstate, prod.tfstate)
#   - backups-<env>    -> backups do MongoDB (sobrevivem à desativação do ambiente)
# Proteções: versionamento de blobs, soft delete de 14 dias, TLS 1.2, sem acesso público.
# Requer: az CLI autenticado (azure/login) e as variáveis SHARED_RG, STATE_SA, LOCATION.
set -euo pipefail

: "${SHARED_RG:?}" "${STATE_SA:?}" "${LOCATION:?}"

echo "::group::Resource group compartilhado ${SHARED_RG}"
az group create --name "${SHARED_RG}" --location "${LOCATION}" \
  --tags project=kubeshop managed_by=bootstrap purpose=tfstate-and-backups -o none
echo "::endgroup::"

echo "::group::Conta de armazenamento ${STATE_SA}"
if ! az storage account show -g "${SHARED_RG}" -n "${STATE_SA}" -o none 2>/dev/null; then
  az storage account create -g "${SHARED_RG}" -n "${STATE_SA}" -l "${LOCATION}" \
    --sku Standard_LRS --kind StorageV2 --min-tls-version TLS1_2 \
    --allow-blob-public-access false --https-only true \
    --tags project=kubeshop managed_by=bootstrap -o none
  echo "criada"
else
  echo "já existe (sem alterações)"
fi

az storage account blob-service-properties update -g "${SHARED_RG}" -n "${STATE_SA}" \
  --enable-versioning true \
  --enable-delete-retention true --delete-retention-days 14 \
  --enable-container-delete-retention true --container-delete-retention-days 14 -o none
echo "::endgroup::"

echo "::group::Containers"
for c in tfstate backups-dev backups-homolog backups-prod; do
  az storage container create --account-name "${STATE_SA}" --name "${c}" \
    --auth-mode key -o none
  echo "ok: ${c}"
done
echo "::endgroup::"

echo "::group::Retenção (lifecycle)"
policy="$(mktemp)"
cat > "${policy}" <<'JSON'
{
  "rules": [
    {
      "enabled": true,
      "name": "backups-retencao-30-dias",
      "type": "Lifecycle",
      "definition": {
        "actions": { "baseBlob": { "delete": { "daysAfterModificationGreaterThan": 30 } } },
        "filters": { "blobTypes": ["blockBlob"], "prefixMatch": ["backups-dev/", "backups-homolog/", "backups-prod/"] }
      }
    },
    {
      "enabled": true,
      "name": "tfstate-versoes-antigas-90-dias",
      "type": "Lifecycle",
      "definition": {
        "actions": { "version": { "delete": { "daysAfterCreationGreaterThan": 90 } } },
        "filters": { "blobTypes": ["blockBlob"], "prefixMatch": ["tfstate/"] }
      }
    }
  ]
}
JSON
az storage account management-policy create -g "${SHARED_RG}" --account-name "${STATE_SA}" \
  --policy "@${policy}" -o none
echo "::endgroup::"
echo "Bootstrap concluído: ${SHARED_RG}/${STATE_SA}"
