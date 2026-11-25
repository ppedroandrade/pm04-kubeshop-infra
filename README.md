# PM-04 · KubeShop na Azure (Terraform + Ansible + GitHub Actions)

Infraestrutura do **KubeShop** (Zibiska Korp) na Microsoft Azure, provisionada com **Terraform**, configurada e mantida com **Ansible** e operada só por **pipelines do GitHub Actions**, sem ajuste manual nos servidores.

- Aplicação (código do cliente): <https://github.com/LaercioMLB/kube-shop-v2>
- Documento de demanda: `escopo.pdf` (KubeShop · Implantação e operação de infraestrutura em nuvem)

## Arquitetura

```
                Internet (HTTP 80)
                       │
          ┌────────────▼─────────────┐   VNet 10.20.0.0/16 (brazilsouth)
          │ snet-app 10.20.1.0/24    │
          │ VM app  (Standard_B2s)   │   NSG app: 80 liberada · 22 só p/ IP do runner, temporário
          │  ├ kubeshop-frontend      │   (React + Nginx, porta 80 -> 8080)
          │  └ kubeshop-api           │   (Node.js/Express :3000, só na rede Docker)
          └────────────┬─────────────┘
                       │ 27017 (rede privada)
          ┌────────────▼─────────────┐
          │ snet-db 10.20.2.0/24     │   NSG db: 27017 e 22 SÓ a partir de snet-app; resto negado
          │ VM db (Standard_B1ms)    │   sem IP público
          │  └ kubeshop-mongodb       │   (mongo 8.0.17 autenticado)
          │ Disco gerenciado 16 GB ──┼── /data/mongo (dados + backups locais)
          └────────────┬─────────────┘
                       │ HTTPS (SAS só do container do ambiente)
          ┌────────────▼─────────────┐
          │ rg-kubeshop-shared       │   fora do ciclo de vida do ambiente
          │ Storage stkubeshop<hash> │   tfstate/ (estado Terraform, versionado)
          │                          │   backups-<env>/ (retenção 30 dias)
          └──────────────────────────┘
```

| Requisito do escopo | Como foi atendido |
|---|---|
| REQ-01 · 2 VMs, MongoDB exclusivo | `azurerm_linux_virtual_machine.app` e `.db`; MongoDB roda só na VM db |
| REQ-02 · Banco isolado | VM db sem IP público; porta publicada apenas no IP privado `10.20.2.10` |
| REQ-03 · Rede privada | NSG db libera 27017/22 só de `10.20.1.0/24` e nega o resto (prioridade 4096) |
| REQ-04 · Acessos | Pipeline autentica na Azure por **OIDC** (sem segredo guardado); chave SSH e senhas geradas pelo Terraform, guardadas só no state; SSH aberto só para o IP do runner durante a execução; `no_log` e `::add-mask::` nos logs |
| REQ-05 · Persistência | Dados no **disco gerenciado separado** da VM: reinício, troca de tamanho e até recriação da VM preservam os pedidos |
| §9 Backup/restauração | `mongodump` diário (cron na VM + schedule da pipeline) → Azure Blob; restauração pelo workflow Operações |
| §9 Desativar | workflow `destroy` com confirmação, backup antes e resumo do que continua gerando custo |

## Pipelines

| Workflow | Para quê | Tipo |
|---|---|---|
| **App: publicar imagens** (`app-images.yml`) | Representa o CI/CD existente da aplicação: build das imagens `kubeshop-api` e `kubeshop-frontend` a partir do repo do cliente e push para `ghcr.io/<dono>/kubeshop-*:<tag>` | cotidiano |
| **Infra: provisionar e configurar** (`infra.yml`) | Bootstrap do estado → `terraform fmt/validate/plan/apply` → Ansible (SO, pacotes, Docker, MongoDB, app, backup) → testes | cotidiano |
| **Operações** (`operations.yml`) | `health`, `logs`, `restart`, `backup`, `list-backups`, `restore` (pede `RESTAURAR`) | cotidiano / restore é destrutivo |
| **Desativar ambiente** (`destroy.yml`) | Backup final + `terraform destroy` (pede `DESTRUIR-<env>`) | destrutivo |

### Parâmetros do workflow Infra

| Parâmetro | Exemplo | Efeito |
|---|---|---|
| `operation` | `apply` / `plan` | `plan` só mostra as mudanças |
| `environment` | `dev` / `homolog` / `prod` | resource group, rede e estado (`<env>.tfstate`) próprios |
| `instance_name` | `kubeshop` | nome das VMs `vm-<nome>-app-<env>` (mudar recria as VMs) |
| `app_vm_size` | `Standard_B2s` | instance_type da VM app (redimensiona sem recriar) |
| `db_vm_size` | `Standard_B1ms` | instance_type da VM db (dados preservados no disco separado) |
| `docker_image` | vazio = `ghcr.io/<dono>/kubeshop` | prefixo das imagens `-api` / `-frontend` |
| `docker_tag` | `1.0.0` | versão da aplicação (atualização controlada dos contêineres) |
| `mongo_tag` | `8.0.17` | versão do MongoDB |
| `update_os` | `true` / `false` | `apt dist-upgrade` + reboot se necessário |
| `extra_packages` | `curl,git,unzip` | pacotes adicionais nas duas VMs |

## Como executar

Pré-requisitos (uma vez, já configurado): App Registration com credencial federada para este repositório (branch `main`), função *Contributor* na assinatura e as variáveis de repositório `AZURE_CLIENT_ID`, `AZURE_TENANT_ID` e `AZURE_SUBSCRIPTION_ID` (Settings → Secrets and variables → Actions → *Variables*). Não existe nenhum *secret* com senha ou chave.

1. **Actions → App: publicar imagens → Run workflow** com `version=1.0.0`.
2. **Actions → Infra: provisionar e configurar → Run workflow** com os parâmetros padrão.
3. Abrir a URL da loja mostrada no resumo da execução (`http://kubeshop-dev-xxxxx.brazilsouth.cloudapp.azure.com/`).

### Cenários da apresentação

| Cenário | Como demonstrar | O que esperar |
|---|---|---|
| 1 · Criação inicial | Infra com padrões | `Plan: N to add`; Ansible instala Docker, sobe MongoDB e app; smoke test `PASS` |
| 2 · Atualização | Publicar imagens `1.0.1`; Infra com `app_vm_size=Standard_B2ms`, `docker_tag=1.0.1`, `extra_packages=curl,git,unzip,htop`, `update_os=true` | `Plan: 0 to add, 1 to change, 0 to destroy` (resize in-place); Ansible recria só api/frontend; `/api/info` mostra `1.0.1`; pedidos anteriores continuam lá |
| 3 · Reexecução | Repetir o cenário 2 com os mesmos parâmetros | `No changes.` no Terraform; `changed=0` no PLAY RECAP |
| Persistência | Criar pedido → Operações `restart` (mongodb) → pedido continua; alterar `db_vm_size` → pedido continua | |
| Backup/restauração | Operações `backup` → criar pedido novo → `restore` com `RESTAURAR` → contagem volta | |

## Estrutura

```
.github/workflows/   infra.yml · app-images.yml · operations.yml · destroy.yml
.github/actions/     azure-terraform (login OIDC + init do backend)
terraform/           providers · backend · variables · main · outputs
ansible/             playbook.yml · operations.yml · group_vars/ · roles/
                     os_updates · packages · docker · data_disk · mongodb · backup · app · verify
scripts/             bootstrap-state.sh · render-inventory.sh · ssh-access.sh
docs/                arquitetura, custos e manual de operação
evidencias/          prints e links das execuções
```

Detalhes: [docs/OPERACAO.md](docs/OPERACAO.md) · [docs/CUSTOS.md](docs/CUSTOS.md)
