# Two functions. The relay moves alarm messages from the queue to n8n and can
# do nothing else. The remediation function is the only thing n8n can call in
# AWS; it carries every AWS permission the runbook needs, each scoped to the
# one resource it acts on.

data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

# --- relay ---------------------------------------------------------------------

resource "aws_iam_role" "relay" {
  name               = "${var.name}-relay"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

resource "aws_iam_role_policy_attachment" "relay_vpc" {
  role       = aws_iam_role.relay.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

resource "aws_iam_role_policy" "relay" {
  name = "consume-ops-queue"
  role = aws_iam_role.relay.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes", "sqs:ChangeMessageVisibility"]
        Resource = aws_sqs_queue.ops.arn
      },
      {
        Effect   = "Allow"
        Action   = ["kms:Decrypt"]
        Resource = aws_kms_key.queue.arn
      },
    ]
  })
}

data "archive_file" "relay" {
  type        = "zip"
  source_file = "${path.module}/../../app/relay.py"
  output_path = "${path.module}/../../build/relay.zip"
}

resource "aws_lambda_function" "relay" {
  #checkov:skip=CKV_AWS_116:Failures go back to SQS per message; the queue's redrive policy owns the DLQ.
  #checkov:skip=CKV_AWS_272:Code signing is out of scope for this portfolio stack.
  #checkov:skip=CKV_AWS_173:Environment holds an in-VPC URL only.
  #checkov:skip=CKV_AWS_50:Single-hop relay; X-Ray adds little.
  #checkov:skip=CKV_AWS_115:Reserved concurrency fails in accounts at the 10-execution default; batch size 1 bounds the relay.
  function_name    = "${var.name}-relay"
  description      = "Forward ops alarms from SQS to the private n8n webhook"
  role             = aws_iam_role.relay.arn
  runtime          = "python3.12"
  handler          = "relay.handler"
  filename         = data.archive_file.relay.output_path
  source_code_hash = data.archive_file.relay.output_base64sha256
  timeout          = 30
  memory_size      = 128

  vpc_config {
    subnet_ids         = var.app_subnet_ids
    security_group_ids = [aws_security_group.relay.id]
  }

  environment {
    variables = {
      N8N_WEBHOOK_URL = "http://${aws_service_discovery_service.n8n.name}.${aws_service_discovery_private_dns_namespace.this.name}:5678/webhook/incident"
    }
  }
}

resource "aws_cloudwatch_log_group" "relay" {
  #checkov:skip=CKV_AWS_158:Relay logs carry message ids and HTTP status only.
  #checkov:skip=CKV_AWS_338:Hourly demo stack; seven days covers a session.
  name              = "/aws/lambda/${aws_lambda_function.relay.function_name}"
  retention_in_days = 7
}

resource "aws_lambda_event_source_mapping" "relay" {
  event_source_arn        = aws_sqs_queue.ops.arn
  function_name           = aws_lambda_function.relay.arn
  batch_size              = 1
  function_response_types = ["ReportBatchItemFailures"]
}

# --- remediation ------------------------------------------------------------------

resource "aws_iam_role" "remediate" {
  name               = var.remediation_role_name
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

resource "aws_iam_role_policy_attachment" "remediate_vpc" {
  role       = aws_iam_role.remediate.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

data "aws_iam_policy_document" "remediate" {
  statement {
    sid = "ClaudeInBedrockInRegion"
    # Claude in Amazon Bedrock (Messages API on bedrock-mantle) authorizes
    # inference against the account's projects; region and account are pinned.
    actions   = ["bedrock-mantle:CreateInference"]
    resources = ["arn:aws:bedrock-mantle:${var.region}:${local.account_id}:project/*"]
  }

  statement {
    sid       = "RdsFailover"
    actions   = ["rds:DescribeDBInstances", "rds:RebootDBInstance"]
    resources = ["arn:aws:rds:${var.region}:${local.account_id}:db:${var.rds_instance_id}"]
  }

  statement {
    sid       = "EksDescribe"
    actions   = ["eks:DescribeCluster"]
    resources = ["arn:aws:eks:${var.region}:${local.account_id}:cluster/${var.eks_cluster_name}"]
  }

  statement {
    sid       = "EksScaleNodeGroup"
    actions   = ["eks:DescribeNodegroup", "eks:UpdateNodegroupConfig"]
    resources = ["arn:aws:eks:${var.region}:${local.account_id}:nodegroup/${var.eks_cluster_name}/${var.eks_node_group_name}/*"]
  }

  statement {
    sid       = "ReadCentralAlarms"
    actions   = ["sts:AssumeRole"]
    resources = [var.alarm_reader_role_arn]
  }

  statement {
    sid       = "PublishNotices"
    actions   = ["sns:Publish"]
    resources = [var.ops_topic_arn]
  }

  statement {
    sid       = "OpsTopicKey"
    actions   = ["kms:GenerateDataKey*", "kms:Decrypt"]
    resources = [var.ops_topic_kms_key_arn]
  }
}

resource "aws_iam_role_policy" "remediate" {
  name   = "remediate"
  role   = aws_iam_role.remediate.id
  policy = data.aws_iam_policy_document.remediate.json
}

# Built by scripts/build-lambdas.sh: the handler plus anthropic[bedrock] for
# Python 3.12 on x86_64. Run it before planning.
data "archive_file" "remediate" {
  type        = "zip"
  source_dir  = "${path.module}/../../build/remediate"
  output_path = "${path.module}/../../build/remediate.zip"
}

resource "aws_lambda_function" "remediate" {
  #checkov:skip=CKV_AWS_116:Invoked synchronously by n8n, which records and escalates failures.
  #checkov:skip=CKV_AWS_272:Code signing is out of scope for this portfolio stack.
  #checkov:skip=CKV_AWS_173:Environment holds names and ARNs only, no secrets.
  #checkov:skip=CKV_AWS_50:One call per runbook step; X-Ray adds little.
  #checkov:skip=CKV_AWS_115:Reserved concurrency fails in accounts at the 10-execution default; n8n calls it serially.
  function_name    = "${var.name}-remediate"
  description      = "Allow-listed remediation, Claude summaries and notices for the incident runbook"
  role             = aws_iam_role.remediate.arn
  runtime          = "python3.12"
  architectures    = ["x86_64"]
  handler          = "remediate.handler"
  filename         = data.archive_file.remediate.output_path
  source_code_hash = data.archive_file.remediate.output_base64sha256
  timeout          = 60
  memory_size      = 512

  vpc_config {
    subnet_ids         = var.app_subnet_ids
    security_group_ids = [aws_security_group.remediate.id]
  }

  environment {
    variables = {
      OPS_TOPIC_ARN         = var.ops_topic_arn
      ALARM_READER_ROLE_ARN = var.alarm_reader_role_arn
      KNOWN_ALARMS          = jsonencode(var.known_alarms)
      REMEDIATIONS          = jsonencode(var.remediations)
      RDS_INSTANCE_ID       = var.rds_instance_id
      EKS_CLUSTER_NAME      = var.eks_cluster_name
      EKS_NODEGROUP_NAME    = var.eks_node_group_name
      EKS_RESTART_TARGET    = var.eks_restart_target
      CLAUDE_MODEL          = var.claude_model
    }
  }
}

resource "aws_cloudwatch_log_group" "remediate" {
  #checkov:skip=CKV_AWS_158:Logs carry alarm names and action results only.
  #checkov:skip=CKV_AWS_338:Hourly demo stack; seven days covers a session.
  name              = "/aws/lambda/${aws_lambda_function.remediate.function_name}"
  retention_in_days = 7
}

# Kubernetes access for the rollout restart: edit rights in one namespace only,
# and only when a restart target is configured.
resource "aws_eks_access_entry" "remediate" {
  count = var.eks_restart_target == "" ? 0 : 1

  cluster_name  = var.eks_cluster_name
  principal_arn = aws_iam_role.remediate.arn
}

resource "aws_eks_access_policy_association" "remediate" {
  count = var.eks_restart_target == "" ? 0 : 1

  cluster_name  = var.eks_cluster_name
  principal_arn = aws_iam_role.remediate.arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSEditPolicy"

  access_scope {
    type       = "namespace"
    namespaces = [split("/", var.eks_restart_target)[0]]
  }

  depends_on = [aws_eks_access_entry.remediate]
}
