output "cluster_id" {
  value = aws_eks_cluster.main.id
}

output "cluster_name" {
  value = aws_eks_cluster.main.name
}

output "cluster_endpoint" {
  value = aws_eks_cluster.main.endpoint
}

output "cluster_certificate_authority" {
  value = aws_eks_cluster.main.certificate_authority[0].data
}

output "cluster_oidc_issuer_url" {
  value = aws_eks_cluster.main.identity[0].oidc[0].issuer
}

output "node_group_arn" {
  value = aws_eks_node_group.main.arn
}

output "node_role_arn" {
  value = aws_iam_role.eks_node_group.arn
}

output "kms_key_arn" {
  value = aws_kms_key.eks.arn
}
