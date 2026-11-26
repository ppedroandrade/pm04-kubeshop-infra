# Manual de operação · KubeShop na Azure

Todas as rotinas rodam em **GitHub → Actions → (workflow) → Run workflow**. Ninguém precisa acessar as VMs por SSH nem guardar senha: a pipeline entra na Azure por OIDC, lê as credenciais do Terraform State e abre o SSH só para o próprio runner durante a execução.

## Rotinas cotidianas

| Rotina | Workflow e parâmetros | Resultado esperado | Se falhar |
|---|---|---|---|
| Publicar nova versão da aplicação | **App: publicar imagens** · `version=1.0.1` · `app_ref=main` | imagens `ghcr.io/<dono>/kubeshop-api:1.0.1` e `-frontend:1.0.1` | Ver o passo "Build e push". Erro de build vem do código do cliente |
| Implantar / atualizar | **Infra** · `operation=apply` · `docker_tag=1.0.1` | Terraform `No changes` ou mudanças listadas; PLAY RECAP sem `failed`; smoke `PASS` | Ver a seção "Diagnóstico de falhas" |
| Só conferir o que mudaria | **Infra** · `operation=plan` | resumo do plan no topo da execução | — |
| Mudar tamanho de VM | **Infra** · `app_vm_size` / `db_vm_size` | `1 to change` (a VM reinicia; os dados ficam) | Cota de vCPU: escolha um tamanho menor |
| Atualizar SO e pacotes | **Infra** · `update_os=true` · `extra_packages=...` | `apt dist-upgrade`; reboot automático se necessário | Rodar de novo (o apt pode estar travado por unattended-upgrades) |
| Saúde | **Operações** · `routine=health` | estado dos contêineres, `/api/health/ready` = 200, uso do disco | 503 = API sem banco → `restart` do mongodb |
| Logs | **Operações** · `routine=logs` · `service=api` (ou all/frontend/mongodb) | últimas 100 linhas | — |
| Reiniciar | **Operações** · `routine=restart` · `service=...` | contêiner reiniciado e API pronta de novo | `logs` do serviço |
| Backup agora | **Operações** · `routine=backup` | `BACKUP_NAME=kubeshop-dev-<data>.archive.gz` + lista | Ver se a SAS venceu: rodar **Infra** `apply` |
| Listar backups | **Operações** · `routine=list-backups` | nomes no container `backups-<env>` | — |

O backup automático roda todo dia às 03:00 UTC (cron na VM do banco) e às 05:30 UTC (schedule do workflow Operações). As cópias ficam na Azure por 30 dias e no disco de dados por 7 dias.

## Rotinas que removem ou substituem dados (separadas de propósito)

| Rotina | Workflow e parâmetros | Efeito |
|---|---|---|
| Restaurar backup | **Operações** · `routine=restore` · `backup_name=latest` (ou nome exato) · `confirm=RESTAURAR` | Substitui (`--drop`) os pedidos atuais pelo backup. Mostra a contagem antes e depois |
| Desativar ambiente | **Desativar ambiente** · `environment=dev` · `backup_before=true` · `confirm=DESTRUIR-dev` | Faz um backup final e destrói o resource group do ambiente (VMs, discos, IP, rede) |

**Depois de desativar:** o resource group `rg-kubeshop-shared` continua existindo. Ele guarda o estado Terraform e os backups e custa centavos por mês. Para recriar o ambiente: **Infra** `apply` e depois **Operações** `restore` com `latest`. Para apagar tudo de vez, exclua `rg-kubeshop-shared` no portal. Isso remove os backups de todos os ambientes.

## Integração com o CI/CD da aplicação

O ponto de integração é a **tag da imagem**. O CI/CD da aplicação (aqui representado pelo workflow *App: publicar imagens*) publica `ghcr.io/<dono>/kubeshop-{api,frontend}:<versão>`. A pipeline de infraestrutura recebe essa versão em `docker_tag` e o Ansible atualiza só os contêineres que mudaram.

| Item | Valor |
|---|---|
| Registro | GitHub Container Registry (`ghcr.io`) |
| Imagens | `kubeshop-api`, `kubeshop-frontend` |
| Credencial de pull | token temporário do próprio GitHub Actions (`GITHUB_TOKEN`), passado à VM só durante o deploy e removido em seguida (`docker logout`) |
| Destino | VM `vm-kubeshop-app-<env>`, projeto Compose em `/opt/kubeshop/app` |
| Variáveis de ambiente da API | `MONGO_HOST=10.20.2.10`, `MONGO_DATABASE=kubeshop`, `MONGO_USERNAME=kubeshop`, `MONGO_PASSWORD_FILE` (segredo em arquivo) |

## Segredos e credenciais

| Credencial | Onde fica | Quem acessa |
|---|---|---|
| Login da pipeline na Azure | federação OIDC (App Registration `gh-pm04-kubeshop-infra`) com o branch `main` deste repositório. Não existe segredo | GitHub Actions |
| Chave SSH das VMs | gerada pelo Terraform (`tls_private_key`), só no state | pipeline (arquivo 0600 apagado no fim) |
| Senhas root/app do MongoDB | geradas pelo Terraform (`random_password`), no state; na VM em arquivos 0400 montados como *Docker secrets* | contêineres |
| SAS dos backups | gerada pelo Terraform, restrita ao container do ambiente, rotação a cada 90 dias | VM do banco (`/etc/kubeshop/backup.env`, 0600) |
| Variáveis do repositório | `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID` (identificadores, não segredos) | workflows |

O **Terraform State** fica em `rg-kubeshop-shared/stkubeshop<hash>/tfstate/<env>.tfstate`. Proteções: lock por *blob lease*, versionamento de blobs, *soft delete* de 14 dias, TLS 1.2 e sem acesso público. Para recuperar uma versão anterior: portal → conta de armazenamento → container `tfstate` → blob → *Versões*.

## Procedimento administrativo do banco (REQ-03)

Não existe acesso público ao MongoDB. Para administração manual (exceção):

1. Rode **Operações** `health` para confirmar o ambiente.
2. Com permissão de Owner na assinatura, no portal: VM `vm-kubeshop-app-<env>` → *Executar comando* → `RunShellScript`, ou adicione temporariamente seu IP/32 no NSG `nsg-kubeshop-<env>-app` para a porta 22.
3. A partir da VM da aplicação: `ssh azureops@10.20.2.10` (só a sub-rede da aplicação alcança o banco) e `sudo docker exec -it kubeshop-mongodb mongosh -u admin --authenticationDatabase admin`.
4. Remova a regra temporária do NSG ao terminar.

## Diagnóstico de falhas comuns

| Sintoma | Causa provável | Ação |
|---|---|---|
| `AADSTS700213 No matching federated identity` | workflow rodado de outro branch | rodar do `main` (a federação é só para `main`) |
| `SkuNotAvailable` / `QuotaExceeded` no apply | tamanho de VM sem capacidade/cota na região (limite de 4 vCPUs na avaliação gratuita) | escolher outro tamanho no parâmetro |
| `Could not get lock /var/lib/dpkg/lock` | unattended-upgrades rodando no primeiro boot | rodar de novo (as tarefas apt esperam até 10 min) |
| HTTPS sem certificado (aviso no navegador) | emissão do Let's Encrypt pendente ou limitada | a loja segue por `http://`; **Operações** `logs` (service=all) e conferir `kubeshop-caddy`; o Caddy tenta de novo sozinho |
| `/api/health/ready` = 503 | API não alcança o MongoDB | **Operações** `health`/`logs` (mongodb) → `restart` mongodb |
| `denied` ao baixar imagem do GHCR | tag inexistente ou workflow rodado de um fork | publicar a tag com **App: publicar imagens** |
| Plan quer recriar as VMs | `instance_name` foi alterado | voltar o nome anterior se não for intencional |
