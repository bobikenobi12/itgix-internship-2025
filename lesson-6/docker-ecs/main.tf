# Конфигуриране на AWS провайдъра
provider "aws" {
  region = "eu-central-1" # Можете да промените региона според нуждите си
}

# --- 1. Създаване на IAM роля за ECS Task Execution ---
# Тази роля позволява на ECS Fargate задачите да изтеглят образи от ECR (или DockerHub в този случай)
# и да изпращат логове до CloudWatch.
resource "aws_iam_role" "ecs_task_execution_role" {
  name = "ecs-task-execution-role-for-nginx-app"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Action = "sts:AssumeRole",
        Effect = "Allow",
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
      }
    ]
  })
}

# Прикачване на политиката AmazonECSTaskExecutionRolePolicy към ролята
resource "aws_iam_role_policy_attachment" "ecs_task_execution_role_policy_attachment" {
  role       = aws_iam_role.ecs_task_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# --- 2. Създаване на ECS Cluster използвайки Fargate (Serverless) ---
resource "aws_ecs_cluster" "nginx_cluster" {
  name = "nginx-static-website-cluster"
  # Fargate е "Networking only", така че не е необходимо да дефинираме EC2 инстанции
}

# --- 3. Създаване на Task Definition на вашето приложение ---
# Тази дефиниция описва какъв Docker образ да се използва, какви ресурси да се разпределят и т.н.
resource "aws_ecs_task_definition" "nginx_task_definition" {
  family                   = "nginx-static-website-task"
  cpu                      = "256"    # Дефиниране на CPU (напр. 256 единици = 0.25 vCPU)
  memory                   = "512"    # Дефиниране на Memory (напр. 512MiB)
  network_mode             = "awsvpc" # За Fargate е задължително да е awsvpc
  requires_compatibilities = ["FARGATE"]
  execution_role_arn       = aws_iam_role.ecs_task_execution_role.arn # Използваме създадената IAM роля
  task_role_arn            = aws_iam_role.ecs_task_execution_role.arn # В този случай, същата роля е достатъчна

  container_definitions = jsonencode([
    {
      name      = "nginx-container",
      image     = "lowkeyfaint/docker-ecs:latest", # Заменете с вашия DockerHub образ
      cpu       = 256,
      memory    = 512,
      essential = true,
      portMappings = [
        {
          containerPort = 80, # Портът, който Nginx експонира
          hostPort      = 80,
          protocol      = "tcp"
        }
      ],
      logConfiguration = {
        logDriver = "awslogs",
        options = {
          "awslogs-group"         = "/ecs/nginx-static-website",
          "awslogs-region"        = "eu-central-1", # Можете да промените региона
          "awslogs-stream-prefix" = "ecs"
        }
      }
    }
  ])
}

# Създаване на CloudWatch Log Group за логовете на ECS задачата
resource "aws_cloudwatch_log_group" "nginx_log_group" {
  name              = "/ecs/nginx-static-website"
  retention_in_days = 7 # Колко дни да се пазят логовете
}

# --- 4. Създаване на Service базиран на вашия Task Definition ---
# Този Service поддържа желания брой задачи работещи в клъстера.
resource "aws_ecs_service" "nginx_service" {
  name            = "nginx-static-website-service"
  cluster         = aws_ecs_cluster.nginx_cluster.id
  task_definition = aws_ecs_task_definition.nginx_task_definition.arn
  desired_count   = 1 # Желан брой работещи инстанции на приложението
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = ["subnet-04a6dc99f2f1ead3d", "subnet-05bf210657d62b5b1"] # Заменете с ID-тата на вашите публични подмрежи
    security_groups  = [aws_security_group.nginx_sg.id]
    assign_public_ip = true # Задайте true, за да получи задачата публичен IP адрес
  }

  # Опционално: За да се избегне прекъсване при промени в Task Definition
  # deployment_minimum_healthy_percent = 50
  # deployment_maximum_percent         = 200

  # Зависимост, за да се гарантира, че CloudWatch Log Group е създадена преди Task Definition да я използва
  depends_on = [
    aws_cloudwatch_log_group.nginx_log_group
  ]
}

# --- 5. Създаване на Security Group за ECS Service ---
# Тази Security Group позволява входящ трафик на порт 80 (HTTP)
resource "aws_security_group" "nginx_sg" {
  name        = "nginx-static-website-sg"
  description = "Allow HTTP traffic to ECS Fargate tasks"
  vpc_id      = "vpc-03787e796e0dcde99" # Заменете с ID-то на вашето VPC

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] # Позволява достъп от всякакъв IP адрес (внимавайте в продукционна среда)
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1" # Позволява целия изходящ трафик
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "nginx-static-website-sg"
  }
}

# Изходни данни (outputs)
output "ecs_cluster_name" {
  description = "Името на ECS клъстера"
  value       = aws_ecs_cluster.nginx_cluster.name
}

output "ecs_service_name" {
  description = "Името на ECS Service"
  value       = aws_ecs_service.nginx_service.name
}

output "task_definition_arn" {
  description = "ARN на Task Definition"
  value       = aws_ecs_task_definition.nginx_task_definition.arn
}

# Забележка: Получаването на публичния IP адрес на Fargate задачата директно от Terraform outputs
# е предизвикателство, тъй като IP адресът се присвоява след стартиране на задачата.
# Можете да го намерите в AWS ECS Console -> Your Cluster -> Tasks -> Кликнете на задачата -> Network.

