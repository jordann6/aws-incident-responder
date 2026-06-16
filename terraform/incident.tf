# ---------------------------------------------------------------------------
# The incident path: a demo target instance, the alarm that detects the
# incident, and the SNS topic that hands it to the n8n runbook over HTTPS.
# ---------------------------------------------------------------------------

data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }
}

# Instance role so the target registers with SSM and can be reached through
# Session Manager (the SG is egress-only, so this is the only way in).
resource "aws_iam_role" "target" {
  name = "${var.project}-target-ssm"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "target_ssm" {
  role       = aws_iam_role.target.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "target" {
  name = "${var.project}-target"
  role = aws_iam_role.target.name
}

# A self-contained CPU burner is installed so the demo can trip the alarm on
# demand, with no external package dependency:
#   sudo systemctl start incident-stress   (then stop it to let the alarm clear)
resource "aws_instance" "target" {
  ami                    = data.aws_ami.al2023.id
  instance_type          = var.target_instance_type
  subnet_id              = aws_subnet.public[0].id
  vpc_security_group_ids = [aws_security_group.target.id]
  iam_instance_profile   = aws_iam_instance_profile.target.name

  user_data = <<-EOF
    #!/bin/bash
    cat >/usr/local/bin/incident-stress.sh <<'SCRIPT'
    #!/bin/bash
    # Burn every vCPU for the given seconds (default 600) to drive CPU to ~100%.
    DURATION="$${1:-600}"
    for _ in $(seq 1 "$(nproc)"); do
      timeout "$DURATION" bash -c 'while :; do :; done' &
    done
    wait
    SCRIPT
    chmod +x /usr/local/bin/incident-stress.sh
    cat >/etc/systemd/system/incident-stress.service <<'UNIT'
    [Unit]
    Description=Incident demo CPU load
    [Service]
    ExecStart=/usr/local/bin/incident-stress.sh 600
    UNIT
    systemctl daemon-reload
  EOF

  tags = {
    Name        = "${var.project}-target"
    Environment = "demo"
    ManagedBy   = "terraform"
  }
}

resource "aws_sns_topic" "incident" {
  name = "${var.project}-alerts"
}

# CloudWatch posts the alarm state change to SNS, which fans out to the
# n8n webhook. Mirrors the threshold used by event-driven-aws-remediation
# so the two projects are directly comparable.
resource "aws_cloudwatch_metric_alarm" "cpu" {
  alarm_name          = "${var.project}-target-cpu-high"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = 300
  statistic           = "Average"
  threshold           = var.cpu_alarm_threshold
  alarm_description   = "Target EC2 CPU at or above ${var.cpu_alarm_threshold}% for 10 minutes"
  treat_missing_data  = "notBreaching"

  dimensions = {
    InstanceId = aws_instance.target.id
  }

  alarm_actions = [aws_sns_topic.incident.arn]
  ok_actions    = [aws_sns_topic.incident.arn]
}

# HTTPS subscription to the n8n webhook. endpoint_auto_confirms is false
# because n8n confirms programmatically from inside the workflow (it visits
# the SubscribeURL). Create or recreate this only after the workflow is
# imported and active, so SNS delivers the confirmation to a live endpoint.
resource "aws_sns_topic_subscription" "n8n" {
  topic_arn              = aws_sns_topic.incident.arn
  protocol               = "https"
  endpoint               = "https://${local.n8n_fqdn}/webhook/incident"
  endpoint_auto_confirms = false

  depends_on = [aws_ecs_service.n8n]
}
