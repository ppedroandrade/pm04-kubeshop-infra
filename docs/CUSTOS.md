# Estimativa mensal de custos

## Premissas

| Item | Valor |
|---|---|
| Provedor / região | Microsoft Azure · Brazil South (`brazilsouth`) |
| Moeda | USD (a Azure fatura em USD; conversão para BRL varia com o câmbio) |
| Data de referência | novembro de 2026 |
| Período | 730 horas/mês (ambiente ligado 24×7) |
| Modelo de preço | pay-as-you-go, Linux, sem reserva |
| Ambientes | 1 ambiente (`dev`), que também foi usado na apresentação |

## Composição

| Recurso | Qtde | Especificação | Motivo do dimensionamento | USD/mês (aprox.) |
|---|---|---|---|---|
| VM aplicação `Standard_D2s_v4` | 1 | 2 vCPU, 8 GB | Nginx + API Node.js e folga para pull/recriação de contêineres | 111,69 |
| VM banco `Standard_D2s_v4` | 1 | 2 vCPU, 8 GB | MongoDB exclusivo (cache WiredTiger limitado a 0,25 GB, como no compose do cliente) | 111,69 |
| Disco SO StandardSSD (E4, 32 GiB) | 2 | 30 GB cada | imagem Ubuntu 24.04 | ~5 |
| Disco de dados StandardSSD (E3, 16 GiB) | 1 | 16 GB | dados do MongoDB + backups locais (7 dias) | ~1,5 |
| IP público Standard estático | 1 | com rótulo DNS `*.brazilsouth.cloudapp.azure.com` | endereço fixo para a loja | ~3,7 |
| Storage Account (LRS) | 1 | tfstate + backups (30 dias) | estado versionado e cópias fora das VMs | < 1 |
| Tráfego de saída | — | primeiros 100 GB/mês gratuitos | loja com poucos acessos | 0 |
| GitHub Actions / GHCR | — | repositório público | minutos e pacotes gratuitos para repositório público | 0 |
| **Total estimado** | | | | **≈ 235 USD/mês** (≈ 7,7 USD/dia) |

### Por que não a série B (mais barata)?

O dimensionamento ideal para esta demanda seria `Standard_B2s` (app, 49 USD/mês) + `Standard_B1ms` (banco, 25 USD/mês), total ≈ 85 USD/mês. Mas a assinatura de avaliação usada **bloqueia toda a série B** em Brazil South e East US 2 (`NotAvailableForSubscription`, verificado com `az vm list-skus` em 25/11/2026). A cota regional também é de 4 vCPUs. Por isso a escolha foi o menor tamanho liberado com controlador SCSI: `D2s_v4` (2 vCPU) nas duas VMs, que usa exatamente as 4 vCPUs. Em uma assinatura pay-as-you-go, basta trocar os parâmetros `app_vm_size`/`db_vm_size` para B2s/B1ms. O código não muda.

Na demonstração do cenário 2 (`app_vm_size=Standard_E2s_v4`, 2 vCPU/16 GB, 0,201 USD/h), a VM da aplicação passa a ~146,7 USD/mês enquanto o tamanho maior estiver ativo.

## Créditos (não ocultam o custo recorrente)

A assinatura usada tem crédito de avaliação gratuita (R$ 1.075,17, válido até 11/12/2026). O valor acima é o **custo recorrente real** depois que o crédito acabar. No ritmo de ~7,7 USD/dia, o crédito cobre o período do trabalho, mas o ambiente deve ser desativado (workflow `destroy`) depois da apresentação.

## Como reduzir

- Desligar o ambiente fora do horário de uso, ou usar o workflow `destroy` e recriar depois com `apply` + `restore`. O estado e os backups ficam preservados.
- Reserva de 1 ano das VMs B-series: cerca de 40% de desconto.
- Em assinatura paga: série B (`B2s` + `B1ms`) reduz o total para ≈ 85 USD/mês.

## Fatores que alteram o consumo

Aumentar o tamanho das VMs, o crescimento do volume de pedidos (disco/backup), o tráfego de saída acima de 100 GB e manter vários ambientes (`homolog`/`prod`) ligados ao mesmo tempo. Cada ambiente duplica VMs, discos e IP.

## Fontes

- Preços de VMs na região Brazil South (pay-as-you-go Linux): azurespeed.com/AzureVmPricing/Regions/brazilsouth (consulta em 25/11/2026)
- Calculadora oficial para conferência: https://azure.microsoft.com/pricing/calculator/
- Discos, IP e storage: valores aproximados das tabelas oficiais de Managed Disks, IP Addresses e Blob Storage (região Brazil South). Confira na calculadora antes de usar em uma proposta formal.
