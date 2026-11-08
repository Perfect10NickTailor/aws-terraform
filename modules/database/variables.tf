variable "project" { type = string }
variable "environment" { type = string }
variable "db_subnet_group_name" { type = string }
variable "rds_sg_id" { type = string }
variable "db_password" {
  type      = string
  sensitive = true
}

variable "engine" {
  type    = string
  default = "postgres"
}

variable "engine_version" {
  type    = string
  default = "16.3"
}

variable "parameter_group_family" {
  type    = string
  default = "postgres16"
}

variable "instance_class" {
  type    = string
  default = "db.t3.large"
}

variable "allocated_storage" {
  type    = number
  default = 100
}

variable "max_allocated_storage" {
  type    = number
  default = 500
}

variable "db_name" {
  type    = string
  default = "appdb"
}

variable "db_username" {
  type    = string
  default = "dbadmin"
}

variable "backup_retention_period" {
  type    = number
  default = 7
}
