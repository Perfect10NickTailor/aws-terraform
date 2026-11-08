variable "project" { type = string }
variable "environment" { type = string }
variable "private_subnet_ids" { type = list(string) }
variable "eks_sg_id" { type = string }

variable "kubernetes_version" {
  type    = string
  default = "1.30"
}

variable "enable_public_endpoint" {
  type    = bool
  default = false
}

variable "public_access_cidrs" {
  type    = list(string)
  default = []
}

variable "node_instance_types" {
  type    = list(string)
  default = ["t3.large"]
}

variable "node_desired_size" {
  type    = number
  default = 3
}

variable "node_min_size" {
  type    = number
  default = 2
}

variable "node_max_size" {
  type    = number
  default = 10
}

variable "node_volume_size" {
  type    = number
  default = 50
}
