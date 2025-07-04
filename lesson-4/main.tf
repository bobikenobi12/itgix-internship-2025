# Блок за конфигуриране на Terraform backend за съхранение на state файла в S3
# и използване на DynamoDB за заключване на състоянието.
# terraform {
# backend "s3" {
#   # Името на S3 bucket-а, където ще се съхранява tfstate файла.
#   # ТРЯБВА да бъде глобално уникално. Моля, заменете с ваше уникално име.
#   bucket = "bborisov-state-bucket"
#   # Пътят до tfstate файла в S3 bucket-а.
#   key = "terraform/terraform.tfstate"
#   # Регионът на AWS, където се намира S3 bucket-а и DynamoDB таблицата.
#   region = "eu-central-1"
#   # Името на DynamoDB таблицата, използвана за заключване на състоянието.
#   dynamodb_table = "bborisov_tf_state_lock" # <-- Променено име тук, за да съвпада
#   # Активиране на криптиране за state файла в S3.
#   encrypt = true
#   # Премахнати са access_key и secret_key, тъй като се очаква да са конфигурирани
#   # във файла ~/.aws/credentials или чрез променливи на средата.
# }
#}

# Блок за конфигуриране на AWS provider.
provider "aws" {
  # Регионът на AWS, в който ще се разполагат ресурсите.
  region = "eu-central-1"
  # Премахнати са access_key и secret_key, тъй като се очаква да са конфигурирани
  # във файла ~/.aws/credentials или чрез променливи на средата.
}

################################################################################
# 1. Създаване на S3 Bucket и DynamoDB Table за Terraform State
################################################################################

# Ресурс за създаване на S3 bucket за съхранение на Terraform state файла.
resource "aws_s3_bucket" "progress_terraform_state_bucket" {
  # Името на bucket-а. ТРЯБВА да бъде глобално уникално.
  # Забележка: Използва се същото име като в backend конфигурацията.
  bucket = "bborisov-state-bucket"

  # Конфигурация за жизнения цикъл на bucket-а.
  # prevent_destroy = true предотвратява случайно изтриване на bucket-а от Terraform.
  lifecycle {
    prevent_destroy = true
  }

  # Тагове за bucket-а.
  tags = {
    Name = "bborisov-progress-terraform-state-bucket"
  }
}

# Ресурс за задаване на ACL (Access Control List) за S3 bucket-а.
# Забележка: За нови bucket-и, AWS препоръчва да се използва Bucket Policy вместо ACL,
# но тук следваме предоставения пример.
resource "aws_s3_bucket_acl" "state_bucket_acl" {
  bucket = aws_s3_bucket.progress_terraform_state_bucket.id
  acl    = "private" # Прави bucket-а частен.
}

# Ресурс за активиране на версия за S3 bucket-а.
# Версионирането е силно препоръчително за state bucket-и,
# тъй като позволява възстановяване на предишни версии на state файла.
resource "aws_s3_bucket_versioning" "state_bucket_versioning" {
  bucket = aws_s3_bucket.progress_terraform_state_bucket.id
  versioning_configuration {
    status = "Enabled" # Активира версионирането.
  }
}

# Ресурс за създаване на DynamoDB таблица за заключване на Terraform state.
# Това предотвратява едновременни промени от множество потребители,
# което може да доведе до повреда на state файла.
resource "aws_dynamodb_table" "tf_state_lock_table" {
  # Името на DynamoDB таблицата.
  name = "bborisov_tf_state_lock" # <-- Променено име тук, за да съвпада
  # Името на основния ключ (partition key).
  hash_key = "LockID"
  # Капацитет за четене (единици).
  read_capacity = 8
  # Капацитет за запис (единици).
  write_capacity = 8

  # Дефиниция на атрибута за основния ключ.
  attribute {
    name = "LockID"
    type = "S" # Типът на атрибута е низ (String).
  }

  # Тагове за DynamoDB таблицата.
  tags = {
    Name = "tfStateLock"
  }

  # Явна зависимост, за да се гарантира, че S3 bucket-а е създаден преди DynamoDB таблицата.
  # Въпреки че Terraform обикновено извежда зависимости, понякога е полезно да се добавят явни.
  depends_on = [
    aws_s3_bucket.progress_terraform_state_bucket
  ]
}

################################################################################
# 2. Създаване на единична AWS EC2 инстанция
################################################################################

# Ресурс за създаване на една EC2 инстанция.
resource "aws_instance" "single_example_instance" {
  # ID на Amazon Machine Image (AMI), което ще се използва за инстанцията.
  # Това е Amazon Linux 2023 AMI за eu-central-1.
  ami = "ami-016739dde2dbe1d1e"
  # Тип на инстанцията (напр. t2.micro е подходящ за безплатния слой).
  instance_type = "t3.micro"
  # Името на SSH ключовата двойка, която ще се използва за достъп до инстанцията.
  # Уверете се, че "key" съществува във вашия AWS акаунт.
  key_name = "bborisov-ssh-key"
  # ID на подмрежата, в която ще бъде разположена инстанцията.
  # Моля, уверете се, че това е валиден subnet ID във вашата VPC.
  subnet_id = "subnet-0dbaf22ea3bebb657"

  # Тагове за инстанцията.
  tags = {
    Name = "single-example-instance"
  }
}

################################################################################
# 3. Създаване на 2 Web сървъра с Load Balancer зад тях
################################################################################

# Ресурс за създаване на първия уеб сървър (EC2 инстанция).
resource "aws_instance" "webserver1" {
  ami           = "ami-016739dde2dbe1d1e"
  instance_type = "t3.micro"
  # ID на подмрежата за webserver1.
  subnet_id = "subnet-0dbaf22ea3bebb657"
  key_name  = "bborisov-ssh-key"
  # Списък с ID-та на групи за сигурност, приложени към инстанцията.
  # sg-0362be82d370c2f38 трябва да позволява входящ HTTP трафик (порт 80).
  vpc_security_group_ids = ["sg-059000f86481a593c"]

  # user_data скрипт за инсталиране и конфигуриране на Apache уеб сървър.
  user_data = <<-EOF
  #!/bin/bash
  sudo yum update -y
  sudo yum install httpd -y
  sudo systemctl start httpd
  sudo systemctl enable httpd
  sudo echo "<h1>web 1</h1>" >> /var/www/html/index.html
  EOF

  tags = {
    Name = "webserver-1"
  }
}

# Ресурс за създаване на втория уеб сървър (EC2 инстанция).
resource "aws_instance" "webserver2" {
  ami           = "ami-016739dde2dbe1d1e"
  instance_type = "t3.micro"
  # ID на подмрежата за webserver2.
  subnet_id              = "subnet-0dbaf22ea3bebb657"
  key_name               = "bborisov-ssh-key"
  vpc_security_group_ids = ["sg-059000f86481a593c"]

  user_data = <<-EOF
  #!/bin/bash
  sudo yum update -y
  sudo yum install httpd -y
  sudo systemctl start httpd
  sudo systemctl enable httpd
  sudo echo "<h1>web 2</h1>" >> /var/www/html/index.html
  EOF

  tags = {
    Name = "webserver-2"
  }
}

# Ресурс за създаване на Application Load Balancer (ALB).
resource "aws_lb" "application_lb" {
  name               = "bborisov-webapp-lb" # Името на Load Balancer-а.
  internal           = false                # false означава, че е публично достъпен.
  load_balancer_type = "application"        # Типът на Load Balancer-а е Application.
  # Списък с ID-та на подмрежи, в които ще бъде разположен Load Balancer-а.
  # Трябва да са публични подмрежи.
  subnets = ["subnet-04a6dc99f2f1ead3d", "subnet-05bf210657d62b5b1"]
  # Списък с ID-та на групи за сигурност, приложени към Load Balancer-а.
  # sg-0362be82d370c2f38 трябва да позволява входящ HTTP трафик (порт 80) от интернет.
  security_groups = ["sg-059000f86481a593c"]

  tags = {
    Name = "my-web-app-lb"
  }
}

# Ресурс за създаване на Target Group.
# Target Group-а дефинира как Load Balancer-а насочва трафика към регистрираните цели (EC2 инстанции).
resource "aws_lb_target_group" "web_target_group" {
  # ID на VPC, в която се намира Target Group-а.
  # Моля, уверете се, че това е валиден VPC ID.
  vpc_id   = "vpc-03787e796e0dcde99"
  name     = "bborisov-target-group" # Името на Target Group-а.
  port     = 80                      # Портът, на който Target Group-а слуша.
  protocol = "HTTP"                  # Протоколът, който Target Group-а използва.

  # Конфигурация за проверка на здравето (Health Check).
  health_check {
    path                = "/" # Пътят за проверка на здравето.
    protocol            = "HTTP"
    matcher             = "200" # Очаква HTTP 200 OK отговор.
    interval            = 30    # Интервал между проверките (секунди).
    timeout             = 5     # Време за изчакване на отговор (секунди).
    healthy_threshold   = 2     # Брой успешни проверки за обявяване на целта за здрава.
    unhealthy_threshold = 2     # Брой неуспешни проверки за обявяване на целта за нездрава.
  }

  tags = {
    Name = "web-tg"
  }
}

# Ресурс за създаване на Listener за Load Balancer-а.
# Listener-ът проверява за заявки за връзка от клиенти, използвайки конфигурирания протокол и порт.
resource "aws_lb_listener" "http_listener" {
  load_balancer_arn = aws_lb.application_lb.arn # ARN на Load Balancer-а.
  port              = "80"                      # Портът, на който Listener-ът слуша.
  protocol          = "HTTP"                    # Протоколът, който Listener-ът използва.

  # Действие по подразбиране, което се изпълнява, когато заявка съвпадне с Listener-а.
  default_action {
    type             = "forward"                                # Типът на действието е "forward" (насочване).
    target_group_arn = aws_lb_target_group.web_target_group.arn # ARN на Target Group-а, към който се насочва трафикът.
  }
}

# Ресурс за прикачване на webserver1 към Target Group-а.
resource "aws_lb_target_group_attachment" "webserver1_attachment" {
  target_group_arn = aws_lb_target_group.web_target_group.arn # ARN на Target Group-а.
  target_id        = aws_instance.webserver1.id               # ID на EC2 инстанцията.
  port             = 80                                       # Портът, на който Target Group-а ще изпраща трафик към инстанцията.
}

# Ресурс за прикачване на webserver2 към Target Group-а.
resource "aws_lb_target_group_attachment" "webserver2_attachment" {
  target_group_arn = aws_lb_target_group.web_target_group.arn # ARN на Target Group-а.
  target_id        = aws_instance.webserver2.id               # ID на EC2 инстанцията.
  port             = 80                                       # Портът, на който Target Group-а ще изпраща трафик към инстанцията.
}

################################################################################
# Изходи (Outputs)
################################################################################

# Изход, който показва публичния DNS на Load Balancer-а.
output "lb_dns_name" {
  description = "The DNS name of the Load Balancer"
  value       = aws_lb.application_lb.dns_name
}

# Изход, който показва публичния IP адрес на единичната EC2 инстанция.
output "single_ec2_public_ip" {
  description = "The public IP address of the single EC2 instance"
  value       = aws_instance.single_example_instance.public_ip
}
