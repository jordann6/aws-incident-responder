# n8n on Fargate, private: no load balancer, no public IP, no inbound except the
# relay. It holds no AWS key. Its task role may only assume one role, with an
# External ID, and that role may only invoke the remediation function; n8n's
# "AWS (Assume Role)" credential with system credentials makes the hop. There is
# nothing else to keep secret: the workflow and that credential are imported at
# every start, and n8n's database lives and dies with the task.

resource "random_uuid" "n8n_external_id" {}

locals {
  external_id = random_uuid.n8n_external_id.result

  workflow = replace(
    file("${path.module}/../../workflows/lz-incident-responder.json"),
    "__REMEDIATE_FUNCTION_ARN__",
    aws_lambda_function.remediate.arn,
  )

  credentials = jsonencode([{
    id   = "lzAssumeRole0001"
    name = "AWS (incident-responder invoke)"
    type = "awsAssumeRole"
    data = {
      region                      = var.region
      useSystemCredentialsForRole = true
      roleArn                     = aws_iam_role.n8n_invoke.arn
      externalId                  = local.external_id
      roleSessionName             = "n8n-incident-responder"
    }
  }])

  # Import, publish, then serve. set -e: a failed import stops the task, and
  # the deployment circuit breaker rolls it back instead of serving no runbook.
  start_script = join(" && ", [
    "set -e",
    "echo \"$LZ_CREDENTIALS_B64\" | base64 -d > /tmp/credentials.json",
    "echo \"$LZ_WORKFLOW_B64\" | base64 -d > /tmp/workflow.json",
    "n8n import:credentials --input=/tmp/credentials.json",
    "n8n import:workflow --input=/tmp/workflow.json",
    "n8n publish:workflow --id=lzIncidentResp01",
    "rm -f /tmp/credentials.json /tmp/workflow.json",
    "exec n8n start",
  ])
}

data "aws_iam_policy_document" "ecs_tasks_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_iam_role" "execution" {
  name               = "${var.name}-execution"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
}

resource "aws_iam_role_policy_attachment" "execution" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role" "task" {
  name               = "${var.name}-n8n-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
}

resource "aws_iam_role_policy" "task" {
  #checkov:skip=CKV_AWS_290:ssmmessages channel actions (ECS Exec) do not support resource-level scoping.
  #checkov:skip=CKV_AWS_355:Same: ECS Exec requires Resource "*" for the ssmmessages actions.
  name = "assume-invoke-role-and-exec"
  role = aws_iam_role.task.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "AssumeInvokeRoleOnly"
        Effect   = "Allow"
        Action   = "sts:AssumeRole"
        Resource = aws_iam_role.n8n_invoke.arn
      },
      {
        # ECS Exec, for debugging the private task without any inbound path.
        Sid    = "EcsExec"
        Effect = "Allow"
        Action = [
          "ssmmessages:CreateControlChannel", "ssmmessages:CreateDataChannel",
          "ssmmessages:OpenControlChannel", "ssmmessages:OpenDataChannel",
        ]
        Resource = "*"
      },
    ]
  })
}

data "aws_iam_policy_document" "n8n_invoke_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "AWS"
      identifiers = [aws_iam_role.task.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "sts:ExternalId"
      values   = [local.external_id]
    }
  }
}

resource "aws_iam_role" "n8n_invoke" {
  name               = "${var.name}-n8n-invoke"
  assume_role_policy = data.aws_iam_policy_document.n8n_invoke_trust.json
}

resource "aws_iam_role_policy" "n8n_invoke" {
  name = "invoke-remediation-only"
  role = aws_iam_role.n8n_invoke.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = "lambda:InvokeFunction"
      # n8n's Lambda node invokes the qualified ARN (...:$LATEST), which an
      # unqualified resource does not match.
      Resource = [aws_lambda_function.remediate.arn, "${aws_lambda_function.remediate.arn}:*"]
    }]
  })
}

resource "aws_ecs_cluster" "this" {
  name = var.name

  setting {
    name  = "containerInsights"
    value = "enabled"
  }
}

resource "aws_cloudwatch_log_group" "n8n" {
  #checkov:skip=CKV_AWS_158:n8n logs carry execution metadata, no secrets.
  #checkov:skip=CKV_AWS_338:Hourly demo stack; seven days covers a session.
  name              = "/ecs/${var.name}-n8n"
  retention_in_days = 7
}

resource "aws_ecs_task_definition" "n8n" {
  #checkov:skip=CKV_AWS_336:n8n writes its database and config under /home/node/.n8n.
  family                   = "${var.name}-n8n"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "512"
  memory                   = "1024"
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  container_definitions = jsonencode([{
    name       = "n8n"
    image      = var.n8n_image
    essential  = true
    entryPoint = ["tini", "--", "/bin/sh", "-c"]
    command    = [local.start_script]

    portMappings = [{ containerPort = 5678, protocol = "tcp" }]

    environment = [
      { name = "N8N_PORT", value = "5678" },
      { name = "N8N_PROTOCOL", value = "http" },
      { name = "WEBHOOK_URL", value = "http://${aws_service_discovery_service.n8n.name}.${aws_service_discovery_private_dns_namespace.this.name}:5678/" },
      { name = "GENERIC_TIMEZONE", value = "UTC" },
      { name = "N8N_AWS_SYSTEM_CREDENTIALS_ACCESS_ENABLED", value = "true" },
      # Nothing calls home: every outbound name n8n would try is off the
      # firewall allowlist, and drops would page the firewall alarm.
      { name = "N8N_DIAGNOSTICS_ENABLED", value = "false" },
      { name = "N8N_VERSION_NOTIFICATIONS_ENABLED", value = "false" },
      { name = "N8N_TEMPLATES_ENABLED", value = "false" },
      { name = "N8N_PERSONALIZATION_ENABLED", value = "false" },
      { name = "N8N_COMMUNITY_PACKAGES_ENABLED", value = "false" },
      { name = "N8N_HIRING_BANNER_ENABLED", value = "false" },
      { name = "EXTERNAL_FRONTEND_HOOKS_URLS", value = "" },
      { name = "N8N_DIAGNOSTICS_CONFIG_FRONTEND", value = "" },
      { name = "N8N_DIAGNOSTICS_CONFIG_BACKEND", value = "" },
      { name = "LZ_WORKFLOW_B64", value = base64encode(local.workflow) },
      { name = "LZ_CREDENTIALS_B64", value = base64encode(local.credentials) },
    ]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.n8n.name
        "awslogs-region"        = var.region
        "awslogs-stream-prefix" = "n8n"
      }
    }
  }])
}

resource "aws_ecs_service" "n8n" {
  name                   = "${var.name}-n8n"
  cluster                = aws_ecs_cluster.this.id
  task_definition        = aws_ecs_task_definition.n8n.arn
  desired_count          = 1
  launch_type            = "FARGATE"
  enable_execute_command = true

  network_configuration {
    subnets          = var.app_subnet_ids
    security_groups  = [aws_security_group.n8n.id]
    assign_public_ip = false
  }

  service_registries {
    registry_arn = aws_service_discovery_service.n8n.arn
  }

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }
}
