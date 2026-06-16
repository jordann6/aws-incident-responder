# Dedicated, least-privilege identity for n8n to act on AWS during a runbook.
# The access key is created out of band (aws iam create-access-key) and entered
# into the n8n UI as an AWS credential, so no secret is written to state.

resource "aws_iam_user" "n8n" {
  name = "${var.project}-n8n"
  path = "/service/"
}

resource "aws_iam_user_policy" "n8n" {
  name = "${var.project}-remediation"
  user = aws_iam_user.n8n.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "RebootTargetOnly"
        Effect   = "Allow"
        Action   = ["ec2:RebootInstances"]
        Resource = "arn:aws:ec2:${var.aws_region}:${data.aws_caller_identity.current.account_id}:instance/${aws_instance.target.id}"
      },
      {
        Sid    = "ReadOnlyEnrichment"
        Effect = "Allow"
        Action = [
          "ec2:DescribeInstances",
          "ec2:DescribeInstanceStatus",
          "cloudwatch:DescribeAlarms",
          "cloudwatch:GetMetricStatistics",
          "cloudwatch:GetMetricData",
        ]
        Resource = "*"
      },
    ]
  })
}
