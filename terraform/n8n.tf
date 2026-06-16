# ---------------------------------------------------------------------------
# n8n control plane: ACM cert, ALB, ECS Fargate service, DNS record.
# This is the runbook engine that replaces the Lambda glue used in the
# sibling event-driven-aws-remediation project.
# ---------------------------------------------------------------------------

locals {
  n8n_fqdn = "${var.n8n_subdomain}.${var.hosted_zone_name}"
}

data "aws_route53_zone" "main" {
  name         = "${var.hosted_zone_name}."
  private_zone = false
}

# Publicly trusted TLS so SNS will accept the HTTPS subscription.
resource "aws_acm_certificate" "n8n" {
  domain_name       = local.n8n_fqdn
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }

  tags = {
    Name = "${var.project}-n8n"
  }
}

resource "aws_route53_record" "cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.n8n.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  zone_id         = data.aws_route53_zone.main.zone_id
  name            = each.value.name
  type            = each.value.type
  records         = [each.value.record]
  ttl             = 60
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "n8n" {
  certificate_arn         = aws_acm_certificate.n8n.arn
  validation_record_fqdns = [for r in aws_route53_record.cert_validation : r.fqdn]
}

# ---------------------------------------------------------------------------
# Load balancer
# ---------------------------------------------------------------------------

resource "aws_lb" "n8n" {
  name               = "${var.project}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = aws_subnet.public[*].id

  tags = {
    Name = "${var.project}-alb"
  }
}

resource "aws_lb_target_group" "n8n" {
  name        = "${var.project}-tg"
  port        = 5678
  protocol    = "HTTP"
  vpc_id      = aws_vpc.main.id
  target_type = "ip"

  health_check {
    path                = "/healthz"
    matcher             = "200"
    interval            = 30
    healthy_threshold   = 2
    unhealthy_threshold = 5
  }

  tags = {
    Name = "${var.project}-tg"
  }
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.n8n.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = aws_acm_certificate_validation.n8n.certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.n8n.arn
  }
}

resource "aws_route53_record" "n8n" {
  zone_id = data.aws_route53_zone.main.zone_id
  name    = local.n8n_fqdn
  type    = "A"

  alias {
    name                   = aws_lb.n8n.dns_name
    zone_id                = aws_lb.n8n.zone_id
    evaluate_target_health = true
  }
}

# ---------------------------------------------------------------------------
# ECS Fargate service running n8n
# ---------------------------------------------------------------------------

resource "aws_ecs_cluster" "main" {
  name = "${var.project}-cluster"
}

resource "aws_cloudwatch_log_group" "n8n" {
  name              = "/ecs/${var.project}-n8n"
  retention_in_days = 14
}

# Secrets are pulled from SSM at task start, so they never live in tfvars
# or in Terraform state. Create the parameters before applying (see README).
data "aws_ssm_parameter" "basic_auth_password" {
  name = var.ssm_password_param
}

data "aws_ssm_parameter" "encryption_key" {
  name = var.ssm_encryption_key_param
}

# Execution role: lets ECS pull the image, write logs, and read the SSM secrets.
resource "aws_iam_role" "execution" {
  name = "${var.project}-execution"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "execution_managed" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role_policy" "execution_secrets" {
  name = "${var.project}-read-ssm"
  role = aws_iam_role.execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = ["ssm:GetParameters"]
      Resource = [
        data.aws_ssm_parameter.basic_auth_password.arn,
        data.aws_ssm_parameter.encryption_key.arn,
      ]
    }]
  })
}

# Task role is intentionally permission-free: n8n calls AWS through its own
# scoped IAM-user credentials (see iam.tf) entered in the n8n UI. The README
# documents the production alternative of granting the task role directly.
resource "aws_iam_role" "task" {
  name = "${var.project}-task"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_ecs_task_definition" "n8n" {
  family                   = "${var.project}-n8n"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.n8n_task_cpu
  memory                   = var.n8n_task_memory
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn

  container_definitions = jsonencode([{
    name      = "n8n"
    image     = var.n8n_image
    essential = true

    portMappings = [{
      containerPort = 5678
      protocol      = "tcp"
    }]

    environment = [
      { name = "N8N_HOST", value = local.n8n_fqdn },
      { name = "N8N_PORT", value = "5678" },
      { name = "N8N_PROTOCOL", value = "https" },
      { name = "WEBHOOK_URL", value = "https://${local.n8n_fqdn}/" },
      { name = "N8N_BASIC_AUTH_ACTIVE", value = "true" },
      { name = "N8N_BASIC_AUTH_USER", value = var.n8n_basic_auth_user },
      { name = "GENERIC_TIMEZONE", value = "America/New_York" },
      { name = "N8N_DIAGNOSTICS_ENABLED", value = "false" },
    ]

    secrets = [
      { name = "N8N_BASIC_AUTH_PASSWORD", valueFrom = data.aws_ssm_parameter.basic_auth_password.arn },
      { name = "N8N_ENCRYPTION_KEY", valueFrom = data.aws_ssm_parameter.encryption_key.arn },
    ]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.n8n.name
        "awslogs-region"        = var.aws_region
        "awslogs-stream-prefix" = "n8n"
      }
    }
  }])
}

resource "aws_ecs_service" "n8n" {
  name            = "${var.project}-n8n"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.n8n.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = aws_subnet.public[*].id
    security_groups  = [aws_security_group.n8n.id]
    assign_public_ip = true
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.n8n.arn
    container_name   = "n8n"
    container_port   = 5678
  }

  depends_on = [aws_lb_listener.https]
}
