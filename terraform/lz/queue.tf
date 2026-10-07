# Ops alarms reach the responder through a queue, not an HTTPS endpoint: the
# monitoring account's ops-alarms topic delivers to this prod queue, which
# holds and retries a message until the relay hands it to n8n. Nothing about
# the responder is reachable from outside the VPC.

data "aws_iam_policy_document" "queue_key" {
  #checkov:skip=CKV_AWS_356:KMS key policies scope by principal/condition; Resource "*" means "this key".
  #checkov:skip=CKV_AWS_111:The root kms:* statement is the standard key-admin anchor so the key is never orphaned.
  #checkov:skip=CKV_AWS_109:The SNS statement is bounded by the ops topic's source ARN.
  statement {
    sid       = "AccountRootAdmin"
    actions   = ["kms:*"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${local.account_id}:root"]
    }
  }

  # SNS encrypts what it delivers into the queue with this key.
  statement {
    sid       = "OpsTopicDelivery"
    actions   = ["kms:GenerateDataKey*", "kms:Decrypt"]
    resources = ["*"]
    principals {
      type        = "Service"
      identifiers = ["sns.amazonaws.com"]
    }
    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [var.ops_topic_arn]
    }
  }
}

resource "aws_kms_key" "queue" {
  description             = "Incident responder queue and dead-letter queue"
  deletion_window_in_days = 7
  enable_key_rotation     = true
  policy                  = data.aws_iam_policy_document.queue_key.json
}

resource "aws_kms_alias" "queue" {
  name          = "alias/${var.name}-queue"
  target_key_id = aws_kms_key.queue.key_id
}

resource "aws_sqs_queue" "dlq" {
  name                      = "${var.name}-ops-dlq"
  kms_master_key_id         = aws_kms_key.queue.arn
  message_retention_seconds = 1209600
}

resource "aws_sqs_queue" "ops" {
  # The topic policy allows only queues named incident-responder-* to subscribe.
  name                       = "${var.name}-ops"
  kms_master_key_id          = aws_kms_key.queue.arn
  visibility_timeout_seconds = 60
  message_retention_seconds  = 86400

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq.arn
    maxReceiveCount     = 3
  })
}

data "aws_iam_policy_document" "ops_queue" {
  statement {
    sid       = "OpsTopicSend"
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.ops.arn]
    principals {
      type        = "Service"
      identifiers = ["sns.amazonaws.com"]
    }
    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [var.ops_topic_arn]
    }
  }
}

resource "aws_sqs_queue_policy" "ops" {
  queue_url = aws_sqs_queue.ops.id
  policy    = data.aws_iam_policy_document.ops_queue.json
}

# Created from the queue's account, so SNS confirms it without a handshake.
# Raw delivery makes each message body the alarm JSON itself. The body filter
# admits CloudWatch alarm notifications only, so the responder's own notices,
# published to the same topic for the email subscribers, never loop back.
resource "aws_sns_topic_subscription" "ops" {
  topic_arn            = var.ops_topic_arn
  protocol             = "sqs"
  endpoint             = aws_sqs_queue.ops.arn
  raw_message_delivery = true
  filter_policy_scope  = "MessageBody"
  filter_policy        = jsonencode({ AlarmName = [{ exists = true }] })

  depends_on = [aws_sqs_queue_policy.ops]
}
