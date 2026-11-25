# Estado remoto no Azure Storage (blob com lease = lock automático).
# Os valores (resource group, conta, container e key por ambiente) são
# informados pela pipeline em `terraform init -backend-config=...`.
terraform {
  backend "azurerm" {
    use_oidc = true
  }
}
