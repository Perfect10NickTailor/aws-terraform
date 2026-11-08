terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project     = var.project
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}

module "networking" {
  source = "../../modules/networking"

  project               = var.project
  environment           = var.environment
  region                = var.region
  vpc_cidr              = var.vpc_cidr
  azs                   = var.azs
  public_subnet_cidrs   = var.public_subnet_cidrs
  private_subnet_cidrs  = var.private_subnet_cidrs
  database_subnet_cidrs = var.database_subnet_cidrs
}

module "security_groups" {
  source = "../../modules/security_groups"

  project     = var.project
  environment = var.environment
  vpc_id      = module.networking.vpc_id
  app_port    = var.app_port
  db_port     = var.db_port
}

module "ecr" {
  source = "../../modules/ecr"

  project          = var.project
  environment      = var.environment
  repository_names = var.ecr_repository_names
}

module "load_balancer" {
  source = "../../modules/load_balancer"

  project             = var.project
  environment         = var.environment
  vpc_id              = module.networking.vpc_id
  public_subnet_ids   = module.networking.public_subnet_ids
  alb_sg_id           = module.security_groups.alb_sg_id
  acm_certificate_arn = var.acm_certificate_arn
  app_port            = var.app_port
  health_check_path   = var.health_check_path
}

module "ec2" {
  source = "../../modules/compute/ec2"

  project              = var.project
  environment          = var.environment
  ec2_sg_id            = module.security_groups.ec2_sg_id
  private_subnet_ids   = module.networking.private_subnet_ids
  target_group_arn     = module.load_balancer.target_group_arn
  instance_type        = var.ec2_instance_type
  asg_min_size         = var.ec2_asg_min
  asg_max_size         = var.ec2_asg_max
  asg_desired_capacity = var.ec2_asg_desired
}

module "ecs" {
  source = "../../modules/compute/ecs"

  project            = var.project
  environment        = var.environment
  region             = var.region
  private_subnet_ids = module.networking.private_subnet_ids
  ecs_sg_id          = module.security_groups.ecs_sg_id
  target_group_arn   = module.load_balancer.target_group_arn
  container_image    = var.ecs_container_image
  container_port     = var.app_port
  task_cpu           = var.ecs_task_cpu
  task_memory        = var.ecs_task_memory
  desired_count      = var.ecs_desired_count
  health_check_path  = var.health_check_path
}

module "eks" {
  source = "../../modules/compute/eks"

  project            = var.project
  environment        = var.environment
  private_subnet_ids = module.networking.private_subnet_ids
  eks_sg_id          = module.security_groups.eks_nodes_sg_id
  kubernetes_version = var.eks_kubernetes_version
  node_instance_types = var.eks_node_instance_types
  node_desired_size  = var.eks_node_desired
  node_min_size      = var.eks_node_min
  node_max_size      = var.eks_node_max
}

module "database" {
  source = "../../modules/database"

  project              = var.project
  environment          = var.environment
  db_subnet_group_name = module.networking.db_subnet_group_name
  rds_sg_id            = module.security_groups.rds_sg_id
  db_password          = var.db_password
  engine_version       = var.db_engine_version
  instance_class       = var.db_instance_class
  allocated_storage    = var.db_allocated_storage
  db_name              = var.db_name
  db_username          = var.db_username
}
