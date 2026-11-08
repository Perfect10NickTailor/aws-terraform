variable "project" { type = string }
variable "environment" { type = string }
variable "vpc_id" { type = string }
variable "public_subnet_ids" { type = list(string) }
variable "alb_sg_id" { type = string }
variable "acm_certificate_arn" { type = string }

variable "app_port" {
  type    = number
  default = 8080
}

variable "target_type" {
  description = "ALB target type: instance, ip, or lambda"
  type        = string
  default     = "ip"
}

variable "health_check_path" {
  type    = string
  default = "/health"
}
