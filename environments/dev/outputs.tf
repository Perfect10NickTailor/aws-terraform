output "vpc_id" {
  value = module.networking.vpc_id
}

output "alb_dns_name" {
  description = "Point your DNS CNAME here"
  value       = module.load_balancer.alb_dns_name
}

output "eks_cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "eks_cluster_name" {
  value = module.eks.cluster_name
}

output "ecs_cluster_name" {
  value = module.ecs.cluster_name
}

output "ecr_repository_urls" {
  value = module.ecr.repository_urls
}

output "db_endpoint" {
  value     = module.database.db_endpoint
  sensitive = true
}

output "kubeconfig_command" {
  description = "Run this to configure kubectl"
  value       = "aws eks update-kubeconfig --region ${var.region} --name ${module.eks.cluster_name}"
}
