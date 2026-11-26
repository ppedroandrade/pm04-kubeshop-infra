#!/usr/bin/env bash
# Converte os outputs do Terraform em inventário + variáveis do Ansible.
# Segredos vão apenas para arquivos 0600 em $RUNNER_TEMP e são mascarados nos logs.
# Uso: render-inventory.sh <tf-outputs.json>
set -euo pipefail
tf_json="${1:?arquivo de outputs do terraform}"
out_dir="${RUNNER_TEMP:-/tmp}/kubeshop"
mkdir -p "${out_dir}" ~/.ssh
chmod 700 "${out_dir}" ~/.ssh

val() { jq -r --arg k "$1" '.[$k].value' "${tf_json}"; }

# Mascarar segredos (defesa extra: eles nunca são impressos)
for k in mongo_root_password mongo_app_password backup_sas; do
  echo "::add-mask::$(val "$k")"
done

key_file=~/.ssh/kubeshop_admin
umask 077
val ssh_private_key > "${key_file}"
chmod 600 "${key_file}"

app_ip="$(val app_public_ip)"
db_ip="$(val db_private_ip)"
user="$(val admin_username)"
app_name="$(val app_vm_name)"
db_name="$(val db_vm_name)"

cat > "${out_dir}/hosts.ini" <<EOF
[app]
${app_name} ansible_host=${app_ip}

[db]
${db_name} ansible_host=${db_ip}

[all:vars]
ansible_user=${user}
ansible_ssh_private_key_file=${key_file}

[db:vars]
ansible_ssh_common_args=-o ProxyCommand="ssh -W %h:%p -q -i ${key_file} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ${user}@${app_ip}"
EOF

jq -n \
  --arg db_private_ip "${db_ip}" \
  --arg app_fqdn "$(val app_fqdn)" \
  --arg mongo_root_password "$(val mongo_root_password)" \
  --arg mongo_app_password "$(val mongo_app_password)" \
  --arg backup_container_url "$(val backup_container_url)" \
  --arg backup_sas "$(val backup_sas)" \
  '{db_private_ip: $db_private_ip, app_fqdn: $app_fqdn, mongo_root_password: $mongo_root_password,
    mongo_app_password: $mongo_app_password, backup_container_url: $backup_container_url,
    backup_sas: $backup_sas}' > "${out_dir}/tf-vars.json"
chmod 600 "${out_dir}/tf-vars.json"

{
  echo "APP_PUBLIC_IP=${app_ip}"
  echo "APP_FQDN=$(val app_fqdn)"
  echo "STORE_URL=$(val store_url)"
  echo "RESOURCE_GROUP=$(val resource_group)"
  echo "APP_NSG=$(val app_nsg_name)"
  echo "INVENTORY=${out_dir}/hosts.ini"
  echo "TF_VARS_FILE=${out_dir}/tf-vars.json"
} >> "${GITHUB_ENV:-/dev/null}"

echo "Inventário gerado: app=${app_name} (${app_ip}) db=${db_name} (${db_ip}, privado via app)"
