# =============================================
# Production environment configuration
# Replace all YOUR_* placeholders before applying
# =============================================

project     = "YOUR_PROJECT_NAME"
environment = "prod"
region      = "us-east-1"

# Networking
vpc_cidr              = "10.0.0.0/16"
azs                   = ["us-east-1a", "us-east-1b", "us-east-1c"]
public_subnet_cidrs   = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
private_subnet_cidrs  = ["10.0.10.0/24", "10.0.11.0/24", "10.0.12.0/24"]
database_subnet_cidrs = ["10.0.20.0/24", "10.0.21.0/24", "10.0.22.0/24"]

# App
app_port            = 8080
health_check_path   = "/health"
acm_certificate_arn = "arn:aws:acm:us-east-1:YOUR_ACCOUNT_ID:certificate/YOUR_CERT_ID"

# ECR
ecr_repository_names = ["app"]

# EC2 / ASG
ec2_instance_type = "t3.medium"
ec2_asg_min       = 2
ec2_asg_max       = 10
ec2_asg_desired   = 3

# ECS Fargate
ecs_container_image = "YOUR_ACCOUNT_ID.dkr.ecr.us-east-1.amazonaws.com/YOUR_PROJECT/app:latest"
ecs_task_cpu        = 512
ecs_task_memory     = 1024
ecs_desired_count   = 3

# EKS
eks_kubernetes_version  = "1.30"
eks_node_instance_types = ["t3.large"]
eks_node_desired        = 3
eks_node_min            = 2
eks_node_max            = 10

# RDS PostgreSQL
db_engine_version    = "16.3"
db_instance_class    = "db.t3.large"
db_allocated_storage = 100
db_name              = "appdb"
db_username          = "dbadmin"
# db_password is set via TF_VAR_db_password environment variable — never commit it here
