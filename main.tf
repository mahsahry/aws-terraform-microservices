# VPC Module
module "pagopa_pr_api_ms_vpc" {
  source = "terraform-aws-modules/vpc/aws"

  name                 = "${var.general_name}-vpc"
  cidr                 = var.vpc_cidr
  azs                  = var.availability_zone
  enable_dns_support   = var.vpc_dns_support
  enable_dns_hostnames = var.vpc_dns_hostnames

  public_subnets  = [var.public_cidr_1, var.public_cidr_2]
  private_subnets = [var.private_cidr_1, var.private_cidr_2]

  enable_nat_gateway = true
  create_igw         = true

  tags = {
    Name = "${var.general_name}-vpc"
  }
}

# Create an s3 bucket that is using in python scripts to save their output
resource "aws_s3_bucket" "logs_bucket" {
  bucket = "pr-microservices-logs-mhmdrza" # Change this to your desired bucket name
}

# ECR Repositories
resource "aws_ecr_repository" "fastapi" {
  name = "${var.general_name}-fastapi-service"
}

resource "aws_ecr_repository" "authentication" {
  name = "${var.general_name}-authentication-service"
}

resource "aws_ecr_repository" "authorization" {
  name = "${var.general_name}-authorization-service"
}

resource "aws_ecr_repository" "content" {
  name = "${var.general_name}-content-service"
}

resource "docker_image" "fastapi" {
  name = aws_ecr_repository.fastapi.repository_url
  build {
    context    = "${path.module}/microservice-api/api"
    dockerfile = "Dockerfile"
  }
}

resource "docker_image" "authentication" {
  name = aws_ecr_repository.authentication.repository_url
  build {
    context    = "${path.module}/microservice-api/authentication"
    dockerfile = "Dockerfile"
  }
}

resource "docker_image" "authorization" {
  name = aws_ecr_repository.authorization.repository_url
  build {
    context    = "${path.module}/microservice-api/authorization"
    dockerfile = "Dockerfile"
  }
}

resource "docker_image" "content" {
  name = aws_ecr_repository.content.repository_url
  build {
    context    = "${path.module}/microservice-api/content"
    dockerfile = "Dockerfile"
  }
}

resource "docker_registry_image" "fastapi_service" {
  name = docker_image.fastapi.name
}

resource "docker_registry_image" "authentication_service" {
  name = docker_image.authentication.name
}

resource "docker_registry_image" "authorization_service" {
  name = docker_image.authorization.name
}

resource "docker_registry_image" "content_service" {
  name = docker_image.content.name
}

# ECS Cluster
resource "aws_ecs_cluster" "my_cluster" {
  name = "${var.general_name}-ecs-cluster"
}

# Create a security group for the ALB.
resource "aws_security_group" "ecs_sg" {
  name        = "ecs-sg"
  description = "ECS security group for the ALB."
  vpc_id      = module.pagopa_pr_api_ms_vpc.vpc_id

  ingress {
    protocol    = "tcp"
    from_port   = 80
    to_port     = 80
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    protocol    = "tcp"
    from_port   = 8000
    to_port     = 8000
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    protocol    = "-1"
    from_port   = 0
    to_port     = 0
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Create the Application Load Balancer.
resource "aws_lb" "main" {
  name                       = "ecsalb"
  internal                   = false
  load_balancer_type         = "application"
  security_groups            = [aws_security_group.ecs_sg.id]
  subnets                    = module.pagopa_pr_api_ms_vpc.public_subnets
  idle_timeout               = 30
  enable_deletion_protection = false
}

# Create the ALB target group.
resource "aws_lb_target_group" "ecs_rest_api_tg" {
  name        = "ecs-tg"
  port        = 8000
  protocol    = "HTTP"
  vpc_id      = module.pagopa_pr_api_ms_vpc.vpc_id
  target_type = "ip"

  health_check {
    path                = "/"
    protocol            = "HTTP"
    healthy_threshold   = 2
    unhealthy_threshold = 2
    timeout             = 2
    interval            = 10
    matcher             = "200"
  }
}

# Create the ALB listener.
resource "aws_lb_listener" "alb_listener" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80 # Can be redirected to 443 to improve security
  protocol          = "HTTP"
  default_action {
    target_group_arn = aws_lb_target_group.ecs_rest_api_tg.arn
    type             = "forward"
  }
}

# IAM Role for ECS Execution
resource "aws_iam_role" "ecs_execution_role" {
  name = "${var.general_name}-ecs-execution-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Action = "sts:AssumeRole",
        Effect = "Allow",
        Principal = {
          Service = ["ecs.amazonaws.com", "ecs-tasks.amazonaws.com"], # "ec2.amazonaws.com"
        },
      },
    ],
  })
}

# IAM Policy for ECS Execution Role
resource "aws_iam_policy" "ecs_execution_policy" {
  name        = "${var.general_name}-ecs-execution-policy"
  description = "Policy for ECS Execution Role"

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Action = [
          "elasticloadbalancing:DeregisterInstancesFromLoadBalancer",
          "elasticloadbalancing:DeregisterTargets",
          "elasticloadbalancing:DescribeTargetGroups",
          "elasticloadbalancing:DescribeTargetHealth",
          "elasticloadbalancing:RegisterInstancesWithLoadBalancer",
          "elasticloadbalancing:RegisterTargets",
          "ecr:GetAuthorizationToken",
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer", # Action for pulling images
          "ecr:BatchGetImage",
          "ecs:DescribeServices",
          "ecs:UpdateService",
          "cloudwatch:PutMetricAlarm",
          "cloudwatch:DescribeAlarms",
          "cloudwatch:DeleteAlarms",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
        ],
        Resource = "*" #should be tuned to specific resources.
      },
    ],
  })
}

# Create an IAM Policy for S3 Access
resource "aws_iam_policy" "ecs_s3_access_policy" {
  name        = "${var.general_name}-ecs-s3-access-policy"
  description = "IAM policy for ECS tasks to access S3"

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Action = [
          "s3:PutObject",
          "s3:GetObject",
          "s3:ListBucket"
        ],
        Resource = "*" # For the S3 bucket
      },
    ],
  })
}

# Create an IAM Role for ECS S3 Access
resource "aws_iam_role" "ecs_s3_access_role" {
  name = "ecs-s3-access-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Action = "sts:AssumeRole",
        Effect = "Allow",
        Principal = {
          Service = "ecs-tasks.amazonaws.com",
        },
      },
    ],
  })
}

# Attach IAM Policy to ECS S3 Access Role
resource "aws_iam_role_policy_attachment" "ecs_s3_access_attachment" {
  policy_arn = aws_iam_policy.ecs_s3_access_policy.arn
  role       = aws_iam_role.ecs_s3_access_role.name
}


# Attach Policy to ECS Execution Role
resource "aws_iam_role_policy_attachment" "ecs_execution_attachment" {
  policy_arn = aws_iam_policy.ecs_execution_policy.arn
  role       = aws_iam_role.ecs_execution_role.name
}

resource "aws_ssm_parameter" "api_host" {
  name  = "/pr_microservices/API_HOST"
  type  = "String"
  value = aws_lb.main.*.dns_name[0]
}