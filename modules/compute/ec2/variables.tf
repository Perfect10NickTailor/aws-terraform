variable "project" { type = string }
variable "environment" { type = string }
variable "ec2_sg_id" { type = string }
variable "private_subnet_ids" { type = list(string) }
variable "target_group_arn" { type = string }

variable "instance_type" {
  type    = string
  default = "t3.medium"
}

variable "root_volume_size" {
  type    = number
  default = 30
}

variable "asg_min_size" {
  type    = number
  default = 2
}

variable "asg_max_size" {
  type    = number
  default = 10
}

variable "asg_desired_capacity" {
  type    = number
  default = 3
}

variable "user_data" {
  description = "User data script for EC2 instances"
  type        = string
  default     = null
}
