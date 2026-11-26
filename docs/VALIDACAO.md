# Relatório de validação · KubeShop na Azure (ambiente `dev`)

Período dos testes: 25 e 26/11/2026. Todas as execuções abaixo estão em **Actions** neste repositório. O link de cada uma é `https://github.com/ppedroandrade/pm04-kubeshop-infra/actions/runs/<id>`. Nenhuma credencial aparece nos logs: senhas, chave SSH e SAS são mascaradas (`::add-mask::`, `no_log`) e a varredura **Gitleaks** passa a cada push.

## Cenários obrigatórios do PM-04

| Cenário | Execução (run id) | Parâmetros | Resultado observado |
|---|---|---|---|
| Publicação das imagens (CI/CD da aplicação) | 45724312403 · 45727539511 | `version=1.0.0` · `1.0.1` | `ghcr.io/ppedroandrade/kubeshop-{api,frontend}` publicadas |
| **1 · Criação inicial** | 45724593073 (rede/NSG/disco) + **45726050455** (VMs + Ansible) | padrão (`D2s_v4`, `1.0.0`) | A 1ª execução falhou nas VMs por `SkuNotAvailable` (série B bloqueada na assinatura). O padrão mudou para `D2s_v4` e a 2ª criou o restante. Ansible: Docker, MongoDB, app; smoke test **PASS** |
| **3 · Reexecução** | 45727021157 | mesmos parâmetros | Terraform **`No changes.`** · Ansible **`changed=0`** nas duas VMs |
| HTTPS (melhoria) | 45729945836 → 45730517663 | — | `Plan: 1 to add` (regra 443), certificado Let's Encrypt emitido; reexecução: `No changes` / `changed=0` |
| **2 · Atualização** | **45808482400** | `app_vm_size=Standard_E2s_v4`, `docker_tag=1.0.1`, `extra_packages=curl,git,unzip,htop`, `update_os=true` | Terraform: `~ size "Standard_D2s_v4" -> "Standard_E2s_v4"` · **`Plan: 0 to add, 1 to change, 0 to destroy`** (in-place). Ansible: `apt dist-upgrade` nas 2 VMs; compose da app atualizado e api/frontend recriados; `/api/info` → `"version":"1.0.1"` |
| **3 · Reexecução após o cenário 2** | **45809376371** | mesmos do cenário 2 | Terraform **`No changes.`** · Ansible app `changed=0`, db `changed=0` |

> `htop` já vem na imagem Ubuntu 24.04, por isso o Ansible reportou `ok` (estado já atendido). Para mostrar a instalação de um pacote novo na apresentação, use por exemplo `extra_packages=curl,git,unzip,nmap`.

## Critérios de aceite do escopo (ACE)

| Critério | Evidência |
|---|---|
| ACE-01 · Reprodução | Execuções acima, a partir do código e dos workflows. Pré-requisitos e parâmetros no `README.md` |
| ACE-02 · Duas VMs | `vm-kubeshop-app-dev` (10.20.1.10, IP público) e `vm-kubeshop-db-dev` (10.20.2.10, **sem IP público**, só MongoDB). Ver o inventário abaixo |
| ACE-03 · Isolamento | Toda execução de Infra testa `nc <ip público> 27017` (recusado) e `/api/health/ready` = `{"ready":true,"database":true}`, com a API falando com o banco por 10.20.2.10 |
| ACE-04 · Aplicação | **45808198914** · **45810920354** (E2E com Chromium fora do Azure): loja aberta em HTTPS, catálogo carregado, pedido criado (`#692620`, `#a33128`), página recarregada e pedido consultado em *Meus pedidos*. Prints em `evidencias/e2e/` |
| ACE-05 · Persistência | Pedido `#692620` (criado antes) conferido **após a mudança de infraestrutura** (resize da VM, run **45809372627**) e **após reiniciar o MongoDB** (restart **45810141044** → E2E **45810424824**) |
| ACE-06 · CI/CD | Workflow `app-images.yml` publica a tag e `infra.yml` implanta `docker_tag`. Integração documentada em `docs/OPERACAO.md` |
| ACE-07 · Recuperação | Backup automático pelo cron da VM às 03:00 UTC (`kubeshop-dev-20261126T030001Z.archive.gz`, listado no run 45807391487). Teste completo: backup **45810688585** (`…T112814Z`) → novo pedido `#a33128` (45810920354, 11 pedidos) → restore **45811159462**: *"pedidos antes: 11 · após: 10"* → E2E **45811373365** confirma `#692620` presente |
| ACE-08 · Administração | Workflows `infra`, `operations` (health/logs/restart/backup/restore) e `destroy` (com confirmação e backup prévio). Login OIDC, sem segredo no GitHub; Gitleaks em todo push |
| ACE-09 · Custos | `docs/CUSTOS.md` |
| ACE-10 · Transferência | `docs/OPERACAO.md` (rotinas, parâmetros, resultado esperado, falhas comuns) |

## Inventário dos recursos (Azure · Brazil South)

| Resource group | Recurso | Nome |
|---|---|---|
| `rg-kubeshop-dev` | VM aplicação | `vm-kubeshop-app-dev` · Ubuntu 24.04 · 10.20.1.10 |
| | VM banco | `vm-kubeshop-db-dev` · Ubuntu 24.04 · 10.20.2.10 |
| | Disco de dados MongoDB | `disk-kubeshop-dev-mongo-data` (16 GB StandardSSD, LUN 0 → `/data/mongo`) |
| | Discos de SO | `osdisk-vm-kubeshop-{app,db}-dev` |
| | Rede | `vnet-kubeshop-dev` 10.20.0.0/16 · `snet-app` 10.20.1.0/24 · `snet-db` 10.20.2.0/24 |
| | NSGs | `nsg-kubeshop-dev-app` (80/443 da internet) · `nsg-kubeshop-dev-db` (27017/22 só de `snet-app`, resto negado) |
| | IP público + DNS | `pip-kubeshop-dev-app` · `kubeshop-dev-<sufixo>.brazilsouth.cloudapp.azure.com` |
| | NICs | `nic-vm-kubeshop-{app,db}-dev` |
| `rg-kubeshop-shared` | Storage | `stkubeshop<hash>`: `tfstate/` (estado, versionado) e `backups-{dev,homolog,prod}/` (30 dias) |
| Entra ID | App Registration | `gh-pm04-kubeshop-infra` (OIDC, função Contributor) |

| Contêiner | VM | Imagem |
|---|---|---|
| `kubeshop-caddy` | app | `caddy:2.10.2-alpine` (TLS, :80/:443) |
| `kubeshop-frontend` | app | `ghcr.io/ppedroandrade/kubeshop-frontend:<docker_tag>` |
| `kubeshop-api` | app | `ghcr.io/ppedroandrade/kubeshop-api:<docker_tag>` |
| `kubeshop-mongodb` | db | `mongo:8.0.17` |

## Pendências conhecidas

- **Desativar (`destroy.yml`)**: implementado e documentado, mas ainda não executado. Ele apaga o ambiente usado na apresentação, então deve rodar depois dela (ou como demonstração final).
- **Backup agendado pelo GitHub** (05:30 UTC): ainda não disparou, porque o GitHub atrasa ou pula agendamentos de repositório novo. O backup automático que vale é o cron da VM (03:00 UTC), comprovado acima.
