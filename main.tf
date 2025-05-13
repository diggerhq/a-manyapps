###############################################################################
# main.tf – “real-world-ish” single-file example for a small AWS workload
###############################################################################

terraform {
  required_version = ">= 1.8.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.50"
    }
  }

  ###########################################################################
  # 👉  In production you’d put this backend block in its own `backend.tf`
  #     or inject it via `-backend-config`, but it’s here for completeness.
  ###########################################################################
  backend "s3" {
    bucket         = "mycompany-tf-state-prod"
    key            = "networking/us-west-2/terraform.tfstate"
    region         = "us-west-2"
    dynamodb_table = "tf-state-locks"
    encrypt        = true
  }
}

###############################################################################
# Provider & common configuration
###############################################################################

provider "aws" {
  region              = var.aws_region
  default_tags {
    tags = {
      Owner   = "platform-team"
      Project = "example-app"
      Managed = "terraform"
      Env     = var.environment
    }
  }
}

###############################################################################
# Locals, data sources, and variables
###############################################################################

locals {
  azs         = slice(data.aws_availability_zones.available.names, 0, 2) # first 2 AZs
  instance_id = "example-${var.environment}"
}

data "aws_availability_zones" "available" {
  state = "available"
}

variable "aws_region" {
  description = "AWS region to deploy into"
  type        = string
  default     = "us-west-2"
}

variable "environment" {
  description = "Deployment stage (dev, staging, prod, etc.)"
  type        = string
  default     = "dev"
}

###############################################################################
# Networking: VPC, public & private subnets, NAT, routes
###############################################################################

resource "aws_vpc" "main" {
  cidr_block           = "10.42.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags = {
    Name = "example-vpc"
  }
}

resource "aws_subnet" "public" {
  count                   = length(local.azs)
  vpc_id                  = aws_vpc.main.id
  cidr_block              = cidrsubnet(aws_vpc.main.cidr_block, 8, count.index)
  map_public_ip_on_launch = true
  availability_zone       = local.azs[count.index]
  tags = {
    Name = "public-${local.azs[count.index]}"
  }
}

resource "aws_subnet" "private" {
  count             = length(local.azs)
  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(aws_vpc.main.cidr_block, 8, 100 + count.index)
  availability_zone = local.azs[count.index]
  tags = {
    Name = "private-${local.azs[count.index]}"
  }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id
  tags = { Name = "example-igw" }
}

resource "aws_eip" "nat" {
  count = length(local.azs)
  vpc   = true
  tags  = { Name = "nat-eip-${local.azs[count.index]}" }
}

resource "aws_nat_gateway" "nat" {
  count         = length(local.azs)
  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id
  tags          = { Name = "nat-${local.azs[count.index]}" }
}

# --- Route tables ---

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
  tags = { Name = "public-rt" }
}

resource "aws_route_table_association" "public" {
  count          = length(local.azs)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "private" {
  count  = length(local.azs)
  vpc_id = aws_vpc.main.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat[count.index].id
  }
  tags = { Name = "private-rt-${local.azs[count.index]}" }
}

resource "aws_route_table_association" "private" {
  count          = length(local.azs)
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}

###############################################################################
# Security group for a demo EC2 instance
###############################################################################

resource "aws_security_group" "web" {
  name        = "web-sg-${var.environment}"
  description = "Allow SSH and HTTPS"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "SSH from anywhere"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS from anywhere"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

###############################################################################
# IAM role + instance profile for EC2
###############################################################################

resource "aws_iam_role" "ec2" {
  name = "ec2-basic-${var.environment}"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Principal = { Service = "ec2.amazonaws.com" }
      Effect    = "Allow"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "ec2" {
  name = "ec2-basic-${var.environment}"
  role = aws_iam_role.ec2.name
}

###############################################################################
# EC2 instance (Amazon Linux 2023) in the first private subnet
###############################################################################

resource "aws_instance" "app" {
  ami                    = data.aws_ami.al2023.id
  instance_type          = "t3.micro"
  subnet_id              = aws_subnet.private[0].id
  associate_public_ip_address = false
  vpc_security_group_ids = [aws_security_group.web.id]
  iam_instance_profile   = aws_iam_instance_profile.ec2.name
  key_name               = "mycompany-prod" # <-- change to your keypair

  user_data = <<-EOF
              #!/bin/bash
              yum update -y
              yum install -y nginx
              systemctl enable nginx
              systemctl start nginx
              EOF

  tags = { Name = local.instance_id }
}

data "aws_ami" "al2023" {
  owners      = ["amazon"]
  most_recent = true
  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }
}

###############################################################################
# S3 bucket for application assets
###############################################################################

resource "aws_s3_bucket" "assets" {
  bucket = "example-assets-${var.environment}-${random_id.suffix.hex}"
  force_destroy = false
}

resource "random_id" "suffix" {
  byte_length = 4
}

###############################################################################
# CloudWatch Log Group (retention 30 days)
###############################################################################

resource "aws_cloudwatch_log_group" "app" {
  name              = "/example/${var.environment}/app"
  retention_in_days = 30
}

###############################################################################
# Outputs
###############################################################################

output "vpc_id" {
  value = aws_vpc.main.id
}

output "instance_private_ip" {
  value = aws_instance.app.private_ip
}

output "s3_bucket_name" {
  value = aws_s3_bucket.assets.id
}
