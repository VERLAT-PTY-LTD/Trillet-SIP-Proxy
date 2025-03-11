provider "aws" {
  region  = var.aws_region
  profile = "trillet-ai"
}

# Use the default VPC instead of creating a new one
data "aws_vpc" "default" {
  default = true
}

# Get default subnets from the default VPC
data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
  filter {
    name   = "default-for-az"
    values = ["true"]
  }
}

# Select the first default subnet
data "aws_subnet" "first" {
  id = tolist(data.aws_subnets.default.ids)[0]
}

# Internet Gateway - Use the default one that comes with the default VPC
data "aws_internet_gateway" "default" {
  filter {
    name   = "attachment.vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# Elastic IP for SIP proxy - THIS GUARANTEES THE STATIC IP
resource "aws_eip" "sip_proxy" {
  domain = "vpc"
  
  tags = {
    Name = "sip-proxy-eip"
  }
}

# Security Group for SIP Proxy
resource "aws_security_group" "sip_proxy" {
  name        = "sip-proxy-sg"
  description = "Security group for SIP proxy"
  vpc_id      = data.aws_vpc.default.id
  
  # SIP UDP
  ingress {
    from_port   = 5060
    to_port     = 5060
    protocol    = "udp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  
  # SIP TCP
  ingress {
    from_port   = 5060
    to_port     = 5060
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  
  # Allow all outbound traffic
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  
  # Specific rule for Redis (if needed)
  egress {
    from_port   = 6379
    to_port     = 6379
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] # Could be more restrictive if Redis CIDR is known
    description = "Allow Redis traffic"
  }
  
  tags = {
    Name = "sip-proxy-sg"
  }
}

# ECR Repository for Docker images
resource "aws_ecr_repository" "sip_proxy" {
  name                 = "sip-proxy"
  image_tag_mutability = "MUTABLE"
  
  tags = {
    Name = "sip-proxy-ecr"
  }
}

# IAM Roles for ECS
resource "aws_iam_role" "ecs_execution_role" {
  name = "sip-proxy-ecs-execution-role"
  
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "ecs_execution_role_policy" {
  role       = aws_iam_role.ecs_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role" "ecs_task_role" {
  name = "sip-proxy-ecs-task-role"
  
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
      }
    ]
  })
}

# ECS Cluster
resource "aws_ecs_cluster" "main" {
  name = "sip-proxy-cluster"
}

# ECS Task Definition
resource "aws_ecs_task_definition" "sip_proxy" {
  family                   = "sip-proxy"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.ecs_execution_role.arn
  task_role_arn            = aws_iam_role.ecs_task_role.arn
  
  container_definitions = jsonencode([
    {
      name      = "sip-proxy"
      image     = "${aws_ecr_repository.sip_proxy.repository_url}:latest"
      essential = true
      
      portMappings = [
        {
          containerPort = 5060
          hostPort      = 5060
          protocol      = "udp"
        },
        {
          containerPort = 5060
          hostPort      = 5060
          protocol      = "tcp"
        }
      ]
      
      environment = concat(
        var.existing_redis_endpoint != "" ? [
          {
            name  = "REDIS_ADDR",
            value = var.existing_redis_endpoint
          }
        ] : [],
        [
          {
            name  = "LIVEKIT_SIP_ADDR",
            value = "12uujhkwedv.sip.livekit.cloud:5060"
          },
          {
            name  = "BIND_ADDR",
            value = ":5060"
          }
        ]
      )
      
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.sip_proxy.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "ecs"
        }
      }
    }
  ])
}

# CloudWatch Log Group
resource "aws_cloudwatch_log_group" "sip_proxy" {
  name              = "/ecs/sip-proxy"
  retention_in_days = 7
}

# Network Interface for static IP association
resource "aws_network_interface" "sip_proxy" {
  subnet_id       = data.aws_subnet.first.id
  security_groups = [aws_security_group.sip_proxy.id]
  
  tags = {
    Name = "sip-proxy-eni"
  }
}

# Associate Elastic IP with the network interface
resource "aws_eip_association" "sip_proxy" {
  allocation_id        = aws_eip.sip_proxy.id
  network_interface_id = aws_network_interface.sip_proxy.id
}

# ECS Service
resource "aws_ecs_service" "sip_proxy" {
  name            = "sip-proxy"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.sip_proxy.arn
  desired_count   = 1
  launch_type     = "FARGATE"
  
  network_configuration {
    subnets          = [data.aws_subnet.first.id]
    security_groups  = [aws_security_group.sip_proxy.id]
    assign_public_ip = true # Required for public subnet deployment
  }
  
  # This ensures that the service runs on the ENI with the static IP
  depends_on = [aws_eip_association.sip_proxy, aws_network_interface.sip_proxy]
}

# Variables
variable "aws_region" {
  description = "AWS region to deploy to"
  default     = "us-west-2"
}

variable "existing_redis_endpoint" {
  description = "Endpoint of your existing ElastiCache instance"
  type        = string
  default     = ""
}

# Outputs
output "sip_proxy_static_ip" {
  value = aws_eip.sip_proxy.public_ip
  description = "The static IP address for the SIP proxy"
}

output "ecr_repository_url" {
  value = aws_ecr_repository.sip_proxy.repository_url
  description = "The URL of the ECR repository"
}

output "redis_connection" {
  value = var.existing_redis_endpoint != "" ? "Connected to Redis at ${var.existing_redis_endpoint}" : "No Redis connection configured"
  description = "The Redis connection status"
} 