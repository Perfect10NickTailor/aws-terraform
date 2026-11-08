terraform {
  backend "s3" {
    bucket         = "YOUR_PROJECT-prod-terraform-state"
    key            = "dev/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "YOUR_PROJECT-prod-terraform-locks"
  }
}
