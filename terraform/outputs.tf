output "resource_group" {
  value = azurerm_resource_group.main.name
}

output "app_vm_name" {
  value = azurerm_linux_virtual_machine.app.name
}

output "db_vm_name" {
  value = azurerm_linux_virtual_machine.db.name
}

output "app_public_ip" {
  value = azurerm_public_ip.app.ip_address
}

output "app_fqdn" {
  value = local.app_fqdn
}

output "store_url" {
  value = "https://${local.app_fqdn}/"
}

output "store_url_http" {
  value = "http://${local.app_fqdn}/"
}

output "app_private_ip" {
  value = azurerm_network_interface.app.private_ip_address
}

output "db_private_ip" {
  value = azurerm_network_interface.db.private_ip_address
}

output "app_nsg_name" {
  value = azurerm_network_security_group.app.name
}

output "admin_username" {
  value = var.admin_username
}

output "ssh_private_key" {
  value     = tls_private_key.admin.private_key_openssh
  sensitive = true
}

output "mongo_root_password" {
  value     = random_password.mongo_root.result
  sensitive = true
}

output "mongo_app_password" {
  value     = random_password.mongo_app.result
  sensitive = true
}

output "backup_container_url" {
  value = "${data.azurerm_storage_account.shared.primary_blob_endpoint}backups-${var.environment}"
}

output "backup_sas" {
  value     = data.azurerm_storage_account_blob_container_sas.backups.sas
  sensitive = true
}

output "admin_panel_private_key" {
  value     = tls_private_key.admin_panel.private_key_openssh
  sensitive = true
}

output "admin_panel_public_key" {
  value = trimspace(tls_private_key.admin_panel.public_key_openssh)
}

output "admin_url" {
  value = "https://${local.app_fqdn}/admin/"
}
