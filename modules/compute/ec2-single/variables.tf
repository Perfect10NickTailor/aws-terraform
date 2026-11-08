variable "project" { type = string }
variable "environment" { type = string }
variable "ec2_sg_id" { type = string }
variable "subnet_id" { type = string }
variable "target_group_arn" { type = string }

variable "instance_type" {
  type    = string
  default = "t3.small"
}

variable "root_volume_size" {
  type    = number
  default = 20
}

variable "user_data" {
  type    = string
  default = null
}
