# =============================================
# Dev environment configuration
# Replace all YOUR_* placeholders before applying
# =============================================

project     = "YOUR_PROJECT_NAME"
environment = "dev"
region      = "us-east-1"

# Networking
vpc_cidr              = "10.1.0.0/16"
azs                   = ["us-east-1a", "us-east-1b"]
public_subnet_cidrs   = ["10.1.1.0/24", "10.1.2.0/24"]
private_subnet_cidrs  = ["10.1.10.0/24", "10.1.11.0/24"]
database_subnet_cidrs = ["10.1.20.0/24", "10.1.21.0/24"]

# App
app_port            = 8080
health_check_path   = "/health"
acm_certificate_arn = "arn:aws:acm:us-east-1:YOUR_ACCOUNT_ID:certificate/YOUR_CERT_ID"

# ECR
ecr_repository_names = ["app"]

# EC2 / ASG
ec2_instance_type = "t3.small"
ec2_asg_min       = 1
ec2_asg_max       = 2
ec2_asg_desired   = 1

# ECS Fargate
ecs_container_image = "YOUR_ACCOUNT_ID.dkr.ecr.us-east-1.amazonaws.com/YOUR_PROJECT/app:latest"
ecs_task_cpu        = 256
ecs_task_memory     = 512
ecs_desired_count   = 1

# EKS
eks_kubernetes_version  = "1.30"
eks_node_instance_types = ["t3.medium"]
eks_node_desired        = 1
eks_node_min            = 1
eks_node_max            = 3

# RDS PostgreSQL
db_engine_version    = "16.3"
db_instance_class    = "db.t3.micro"
db_allocated_storage = 20
db_name              = "appdb"
db_username          = "dbadmin"
# db_password is set via TF_VAR_db_password environment variable — never commit it here
