variable "environment" {
  description = "Ambiente de destino (dev, homolog ou prod)."
  type        = string
  validation {
    condition     = contains(["dev", "homolog", "prod"], var.environment)
    error_message = "environment deve ser dev, homolog ou prod."
  }
}

variable "instance_name" {
  description = "Prefixo do nome das VMs. Ex.: kubeshop -> vm-kubeshop-app-dev e vm-kubeshop-db-dev. Alterar o nome recria as VMs."
  type        = string
  default     = "kubeshop"
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,20}$", var.instance_name))
    error_message = "instance_name: 3 a 21 caracteres, minúsculas, números e hífen."
  }
}

variable "location" {
  description = "Região do Azure."
  type        = string
  default     = "brazilsouth"
}

variable "app_vm_size" {
  description = "Tamanho da VM da aplicação (Nginx + API)."
  type        = string
  default     = "Standard_B2s"
}

variable "db_vm_size" {
  description = "Tamanho da VM exclusiva do MongoDB."
  type        = string
  default     = "Standard_B1ms"
}

variable "db_data_disk_size_gb" {
  description = "Tamanho do disco gerenciado de dados do MongoDB (persistente, independente da VM)."
  type        = number
  default     = 16
}

variable "admin_username" {
  description = "Usuário administrativo das VMs."
  type        = string
  default     = "azureops"
}

variable "vnet_cidr" {
  type    = string
  default = "10.20.0.0/16"
}

variable "app_subnet_cidr" {
  type    = string
  default = "10.20.1.0/24"
}

variable "db_subnet_cidr" {
  type    = string
  default = "10.20.2.0/24"
}

variable "backup_storage_account" {
  description = "Conta de armazenamento compartilhada (criada no bootstrap) onde ficam os backups do MongoDB."
  type        = string
}

variable "backup_resource_group" {
  description = "Resource group da conta de armazenamento compartilhada."
  type        = string
}

variable "tags" {
  type    = map(string)
  default = {}
}
