resource "aws_ecs_cluster" "main" {
  name = "${var.project_name}-cluster"
}

resource "aws_cloudwatch_log_group" "ecs_logs" {
  name              = "/ecs/${var.project_name}-extractor"
  retention_in_days = 7
}

resource "aws_security_group" "extractor_sg" {
  name        = "${var.project_name}-extractor-sg"
  description = "Deny all inbound; permit outbound web, DNS, and API"
  vpc_id      = var.vpc_id

  egress {
    description = "DNS resolution UDP"
    from_port   = 53
    to_port     = 53
    protocol    = "udp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "DNS resolution TCP"
    from_port   = 53
    to_port     = 53
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "Outbound HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "Outbound HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_iam_role" "ecs_execution_role" {
  name = "${var.project_name}-ecs-execution-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ecs_execution_standard" {
  role       = aws_iam_role.ecs_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}


resource "aws_iam_role" "ecs_task_role" {
  name = "${var.project_name}-ecs-task-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "ecs_sns_publish" {
  name = "${var.project_name}-sns-publish-policy"
  role = aws_iam_role.ecs_task_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "sns:Publish",
        "sns:GetTopicAttributes"
      ]
      Resource = var.sns_topic_arn
    }]
  })
}

resource "aws_iam_role_policy" "ecs_s3_read" {
  name = "${var.project_name}-s3-read-policy"
  role = aws_iam_role.ecs_task_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["s3:GetObject"]
      Resource = "${var.config_bucket_arn}/*"
    }]
  })
}

resource "aws_ecs_task_definition" "extractor_task" {
  family                   = "${var.project_name}-extractor"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.ecs_execution_role.arn
  task_role_arn            = aws_iam_role.ecs_task_role.arn

  container_definitions = jsonencode([{
    name      = "${var.project_name}-extractor"
    image     = "${var.ecr_repository_url}:latest"
    essential = true
    environment = [
      { name = "SNS_TOPIC_ARN", value = var.sns_topic_arn },
      { name = "CONFIG_BUCKET", value = var.config_bucket_name },
      { name = "CONFIG_KEY", value = "feeds.json" },
      { name = "MAX_ARTICLES", value = var.max_articles }
    ]

    readonlyRootFilesystem = true
    linuxParameters = {
      capabilities = {
        drop = ["ALL"]
      }
    }
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.ecs_logs.name
        "awslogs-region"        = var.aws_region
        "awslogs-stream-prefix" = "${var.project_name}-extractor"
      }
    }
  }])
}

resource "aws_iam_role" "eventbridge_ecs_role" {
  name = "${var.project_name}-eventbridge-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "events.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "eventbridge_ecs_policy" {
  name = "${var.project_name}-eventbridge-policy"
  role = aws_iam_role.eventbridge_ecs_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["ecs:RunTask"]
        Resource = aws_ecs_task_definition.extractor_task.arn
      },
      {
        Effect = "Allow"
        Action = ["iam:PassRole"]
        Resource = [
          aws_iam_role.ecs_execution_role.arn,
          aws_iam_role.ecs_task_role.arn
        ]
      }
    ]
  })
}

resource "aws_cloudwatch_event_rule" "extractor_schedule" {
  name                = "${var.project_name}-schedule"
  description         = "Triggers extractor container on Tuesday and Friday at 02:16 UTC"
  schedule_expression = "cron(16 2 ? * TUE,FRI *)"
  state               = var.is_schedule_enabled ? "ENABLED" : "DISABLED"
}


resource "aws_cloudwatch_event_target" "ecs_scheduled_target" {
  rule      = aws_cloudwatch_event_rule.extractor_schedule.name
  target_id = "${var.project_name}-ecs-target"
  arn       = aws_ecs_cluster.main.arn
  role_arn  = aws_iam_role.eventbridge_ecs_role.arn

  ecs_target {
    task_count          = 1
    task_definition_arn = aws_ecs_task_definition.extractor_task.arn
    launch_type         = "FARGATE"
    platform_version    = "LATEST"

    network_configuration {
      subnets          = var.public_subnet_ids
      security_groups  = [aws_security_group.extractor_sg.id]
      assign_public_ip = true
    }
  }
}
