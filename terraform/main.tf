locals {
  name_prefix = "${var.instance_name}-${var.environment}"
  app_vm_name = "vm-${var.instance_name}-app-${var.environment}"
  db_vm_name  = "vm-${var.instance_name}-db-${var.environment}"

  tags = merge({
    project     = "kubeshop"
    environment = var.environment
    managed_by  = "terraform"
    course      = "pm04"
  }, var.tags)
}

# ---------------------------------------------------------------------------
# Segredos gerados (ficam apenas no Terraform State, que é privado e versionado)
# ---------------------------------------------------------------------------
resource "tls_private_key" "admin" {
  algorithm = "ED25519"
}

resource "random_password" "mongo_root" {
  length  = 32
  special = false
}

resource "random_password" "mongo_app" {
  length  = 32
  special = false
}

resource "random_string" "dns_suffix" {
  length  = 5
  upper   = false
  special = false
}

# ---------------------------------------------------------------------------
# Resource group e rede
# ---------------------------------------------------------------------------
resource "azurerm_resource_group" "main" {
  name     = "rg-${local.name_prefix}"
  location = var.location
  tags     = local.tags
}

resource "azurerm_virtual_network" "main" {
  name                = "vnet-${local.name_prefix}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  address_space       = [var.vnet_cidr]
  tags                = local.tags
}

resource "azurerm_subnet" "app" {
  name                 = "snet-app"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = [var.app_subnet_cidr]
}

resource "azurerm_subnet" "db" {
  name                 = "snet-db"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = [var.db_subnet_cidr]
}

# ---------------------------------------------------------------------------
# NSG da aplicação: só HTTP/HTTPS públicos. SSH não fica aberto: a pipeline cria uma
# regra temporária para o IP do runner e a remove ao final da execução.
# ---------------------------------------------------------------------------
resource "azurerm_network_security_group" "app" {
  name                = "nsg-${local.name_prefix}-app"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  tags                = local.tags
}

resource "azurerm_network_security_rule" "app_http" {
  name                        = "allow-http-internet"
  priority                    = 100
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "80"
  source_address_prefix       = "Internet"
  destination_address_prefix  = "*"
  resource_group_name         = azurerm_resource_group.main.name
  network_security_group_name = azurerm_network_security_group.app.name
}

resource "azurerm_network_security_rule" "app_https" {
  name                        = "allow-https-internet"
  priority                    = 110
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "443"
  source_address_prefix       = "Internet"
  destination_address_prefix  = "*"
  resource_group_name         = azurerm_resource_group.main.name
  network_security_group_name = azurerm_network_security_group.app.name
}

resource "azurerm_subnet_network_security_group_association" "app" {
  subnet_id                 = azurerm_subnet.app.id
  network_security_group_id = azurerm_network_security_group.app.id
}

# ---------------------------------------------------------------------------
# NSG do banco: MongoDB e SSH apenas a partir da sub-rede da aplicação.
# Todo o resto é negado explicitamente (inclusive o resto da VNet).
# ---------------------------------------------------------------------------
resource "azurerm_network_security_group" "db" {
  name                = "nsg-${local.name_prefix}-db"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  tags                = local.tags
}

resource "azurerm_network_security_rule" "db_mongo_from_app" {
  name                        = "allow-mongodb-from-app-subnet"
  priority                    = 100
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "27017"
  source_address_prefix       = var.app_subnet_cidr
  destination_address_prefix  = var.db_subnet_cidr
  resource_group_name         = azurerm_resource_group.main.name
  network_security_group_name = azurerm_network_security_group.db.name
}

resource "azurerm_network_security_rule" "db_ssh_from_app" {
  name                        = "allow-ssh-from-app-subnet"
  priority                    = 110
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "22"
  source_address_prefix       = var.app_subnet_cidr
  destination_address_prefix  = var.db_subnet_cidr
  resource_group_name         = azurerm_resource_group.main.name
  network_security_group_name = azurerm_network_security_group.db.name
}

resource "azurerm_network_security_rule" "db_deny_all" {
  name                        = "deny-all-inbound"
  priority                    = 4096
  direction                   = "Inbound"
  access                      = "Deny"
  protocol                    = "*"
  source_port_range           = "*"
  destination_port_range      = "*"
  source_address_prefix       = "*"
  destination_address_prefix  = "*"
  resource_group_name         = azurerm_resource_group.main.name
  network_security_group_name = azurerm_network_security_group.db.name
}

resource "azurerm_subnet_network_security_group_association" "db" {
  subnet_id                 = azurerm_subnet.db.id
  network_security_group_id = azurerm_network_security_group.db.id
}

# ---------------------------------------------------------------------------
# IP público (somente na VM da aplicação) com rótulo DNS do Azure
# ---------------------------------------------------------------------------
resource "azurerm_public_ip" "app" {
  name                = "pip-${local.name_prefix}-app"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  allocation_method   = "Static"
  sku                 = "Standard"
  domain_name_label   = "${local.name_prefix}-${random_string.dns_suffix.result}"
  tags                = local.tags
}

resource "azurerm_network_interface" "app" {
  name                = "nic-${local.app_vm_name}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  tags                = local.tags

  ip_configuration {
    name                          = "primary"
    subnet_id                     = azurerm_subnet.app.id
    private_ip_address_allocation = "Static"
    private_ip_address            = cidrhost(var.app_subnet_cidr, 10)
    public_ip_address_id          = azurerm_public_ip.app.id
  }
}

resource "azurerm_network_interface" "db" {
  name                = "nic-${local.db_vm_name}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  tags                = local.tags

  ip_configuration {
    name                          = "primary"
    subnet_id                     = azurerm_subnet.db.id
    private_ip_address_allocation = "Static"
    private_ip_address            = cidrhost(var.db_subnet_cidr, 10)
  }
}

# ---------------------------------------------------------------------------
# Máquinas virtuais (Ubuntu 24.04 LTS, só chave SSH)
# ---------------------------------------------------------------------------
resource "azurerm_linux_virtual_machine" "app" {
  name                            = local.app_vm_name
  computer_name                   = local.app_vm_name
  location                        = azurerm_resource_group.main.location
  resource_group_name             = azurerm_resource_group.main.name
  size                            = var.app_vm_size
  admin_username                  = var.admin_username
  disable_password_authentication = true
  network_interface_ids           = [azurerm_network_interface.app.id]
  tags                            = merge(local.tags, { role = "app" })

  admin_ssh_key {
    username   = var.admin_username
    public_key = tls_private_key.admin.public_key_openssh
  }

  os_disk {
    name                 = "osdisk-${local.app_vm_name}"
    caching              = "ReadWrite"
    storage_account_type = "StandardSSD_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }

  boot_diagnostics {}
}

resource "azurerm_linux_virtual_machine" "db" {
  name                            = local.db_vm_name
  computer_name                   = local.db_vm_name
  location                        = azurerm_resource_group.main.location
  resource_group_name             = azurerm_resource_group.main.name
  size                            = var.db_vm_size
  admin_username                  = var.admin_username
  disable_password_authentication = true
  network_interface_ids           = [azurerm_network_interface.db.id]
  tags                            = merge(local.tags, { role = "db" })

  admin_ssh_key {
    username   = var.admin_username
    public_key = tls_private_key.admin.public_key_openssh
  }

  os_disk {
    name                 = "osdisk-${local.db_vm_name}"
    caching              = "ReadWrite"
    storage_account_type = "StandardSSD_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }

  boot_diagnostics {}
}

# Disco de dados do MongoDB: recurso separado da VM. Redimensionar ou até
# recriar a VM do banco não apaga os pedidos gravados aqui.
resource "azurerm_managed_disk" "mongo_data" {
  name                 = "disk-${local.name_prefix}-mongo-data"
  location             = azurerm_resource_group.main.location
  resource_group_name  = azurerm_resource_group.main.name
  storage_account_type = "StandardSSD_LRS"
  create_option        = "Empty"
  disk_size_gb         = var.db_data_disk_size_gb
  tags                 = merge(local.tags, { role = "db-data" })
}

resource "azurerm_virtual_machine_data_disk_attachment" "mongo_data" {
  managed_disk_id    = azurerm_managed_disk.mongo_data.id
  virtual_machine_id = azurerm_linux_virtual_machine.db.id
  lun                = 0
  caching            = "ReadOnly"
}

# ---------------------------------------------------------------------------
# Backups: container por ambiente na conta compartilhada (fora deste estado,
# para sobreviver à desativação do ambiente). A VM do banco recebe uma SAS
# restrita ao container, com rotação a cada 90 dias.
# ---------------------------------------------------------------------------
data "azurerm_storage_account" "shared" {
  name                = var.backup_storage_account
  resource_group_name = var.backup_resource_group
}

resource "time_rotating" "backup_sas" {
  rotation_days = 90
}

data "azurerm_storage_account_blob_container_sas" "backups" {
  connection_string = data.azurerm_storage_account.shared.primary_connection_string
  container_name    = "backups-${var.environment}"
  https_only        = true
  start             = time_rotating.backup_sas.rfc3339
  expiry            = timeadd(time_rotating.backup_sas.rfc3339, "2880h")

  permissions {
    read   = true
    add    = true
    create = true
    write  = true
    delete = false
    list   = true
  }
}
