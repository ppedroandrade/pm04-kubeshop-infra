#!/usr/bin/env bash
# Abre/fecha SSH na VM da aplicação SOMENTE para o IP público do runner atual.
# O NSG não tem regra SSH permanente: o acesso administrativo existe só durante a execução.
# Uso: ssh-access.sh open|close   (requer RESOURCE_GROUP e APP_NSG no ambiente)
set -euo pipefail
action="${1:?open|close}"
rule="gha-runner-ssh-temporario"
: "${RESOURCE_GROUP:?}" "${APP_NSG:?}"

case "${action}" in
  open)
    ip="$(curl -fsS https://api.ipify.org)"
    az network nsg rule create -g "${RESOURCE_GROUP}" --nsg-name "${APP_NSG}" -n "${rule}" \
      --priority 300 --direction Inbound --access Allow --protocol Tcp \
      --source-address-prefixes "${ip}/32" --destination-port-ranges 22 \
      --description "Temporaria: run ${GITHUB_RUN_ID:-manual}" -o none
    echo "SSH liberado temporariamente para ${ip}/32"
    for i in $(seq 1 30); do
      if nc -z -w 5 "${APP_PUBLIC_IP}" 22; then echo "porta 22 acessível"; exit 0; fi
      sleep 10
    done
    echo "::error::SSH não ficou acessível em ${APP_PUBLIC_IP}:22"; exit 1
    ;;
  close)
    az network nsg rule delete -g "${RESOURCE_GROUP}" --nsg-name "${APP_NSG}" -n "${rule}" -o none || true
    echo "Regra SSH temporária removida"
    ;;
esac
