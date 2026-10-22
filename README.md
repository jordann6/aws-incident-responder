# AWS Incident Responder

An automated incident response pipeline where the runbook is an n8n workflow, not glue code. A CloudWatch alarm on a target EC2 instance fires into an SNS topic, which delivers over HTTPS to n8n running on ECS Fargate. The workflow confirms its own SNS subscription, asks Claude Haiku for a plain-English incident summary, posts an incident card to Slack, reboots the instance, then waits and re-checks the alarm to decide whether to mark the incident resolved or escalate.

## Architecture

![Standalone architecture](docs/architecture.png)

The standalone deploy. An alarm on the target fans out through SNS to n8n behind
an ALB with a public TLS certificate, because SNS only delivers HTTPS to a trusted
endpoint. n8n summarizes the alarm, posts to Slack, reboots the instance, waits,
and reads the alarm again before it calls the incident resolved. The landing
zone version, with no public endpoint, is [below](#landing-zone-mode).

## The problem

An alarm at 3 a.m. depends on a person waking up, finding the runbook and
following it the same way every time. Automating that with a Lambda works, but
the runbook then lives inside code that only its author reads. This project
keeps the runbook as a visual workflow anyone on call can inspect, and makes
it check its own work before it closes an incident.

## Why n8n instead of Lambda

This is the deliberate contrast to the sibling [event-driven-aws-remediation](https://github.com/jordann6/event-driven-aws-remediation) project, which uses a Python Lambda as the glue between alarm and action. Here the same incident class is handled by a visual, auditable runbook running as a real service on AWS. The runbook is version controlled as JSON, the remediation steps are inspectable without reading code, and adding a step (enrichment, an approval gate, a second remediation) is a node rather than a redeploy. Claude Haiku adds a human-readable summary so the Slack card reads like an on-call note rather than a raw alarm payload.

## Landing zone mode

![Landing zone mode](docs/architecture-lz.png)

The alarm arrives from the shared-services ops topic through SQS, so a slow or
restarting n8n never loses an event; anything that fails lands in the DLQ. n8n has
no public endpoint. The remediate Lambda does the work through role sessions, and the
alarm re-check reads through a read-only role in shared-services.

`terraform/lz` runs the responder privately in the prod account of the
[aws-landing-zone](https://github.com/jordann6/aws-landing-zone) organization: no ALB or
public endpoint. A forced alarm goes to SQS, a relay Lambda delivers it to n8n on Fargate in
the private app subnets, and the workflow remediates through role sessions. The central
alarm re-check assumes a read-only role in the monitoring account. Notices go to the
ops-alarms email topic, not Slack. n8n is pinned by digest and mirrored into a private ECR
repository, because Docker Hub is off the hub firewall's allowlist.

Proven live on 2026-10-06: a forced alarm triggered remediation x3 and an RDS Multi-AZ
failover (started and completed in about 35 seconds), the alarm returned to OK, and the
DLQ stayed empty. A control run with the alarm forced OK triggered nothing.

In this mode the incident summary comes from Amazon Nova Lite (`amazon.nova-lite-v1:0`) on
bedrock-runtime in us-east-1, and IAM allows that one model ARN. `summary_model` rejects
profile ids; empty skips the call and uses the template note.

Proven live on 2026-10-17: a forced standing uptime alarm (`uptime-monitor-site-down`)
reached n8n, got a Nova Lite summary (one `Converse` call in CloudTrail, 99 output tokens,
no errors) and a single notice, and took no action because it has no remediation. The OK
recovery event triggered nothing. DLQ 0.

Trivy reports two CRITICAL AWS-0104 findings on this root (`0.0.0.0/0` egress on the
remediation and n8n security groups). A security group cannot name a domain; the prod VPC
has no internet route, and the hub firewall's default-deny domain allowlist is the control.

## What broke along the way

1. **SNS refused to subscribe before n8n existed.** SNS validates an HTTPS
   endpoint at subscribe time, so creating the subscription on the first apply
   failed. It now sits behind `enable_sns_subscription`, off until the workflow
   is imported and serving.
2. **The demo instance could never be reached.** It had no instance profile and
   an egress-only security group, so `aws ssm start-session` had nothing to
   connect to, and `stress-ng` is not in the AL2023 default repos. Fixed with an
   SSM role and a self-contained CPU burner.
3. **An AMI wildcard picked the wrong image.** `al2023-ami-*-x86_64` could
   resolve to the minimal AMI, which ships without the SSM agent. The filter now
   pins the standard image.
4. **A qualified ARN broke the invoke permission.** n8n's Lambda node calls the
   qualified function ARN, and the policy allowed only the unqualified one, so
   the first landing zone run got a 403. The policy now allows both.
5. **A VPC Lambda held its security group for 21 minutes.** Lambda keeps its
   network interface after the function is deleted, so teardown waited on it.
6. **Claude never worked in the landing zone account.** bedrock-mantle returned
   403 "not available for this account", and Claude on bedrock-runtime needs a
   cross-region inference profile that the region-lockdown SCP denies. The
   summary moved to Amazon Nova Lite, which runs in-region.

## How it works

```
Target EC2  CPUUtilization >= 80% (2 x 5 min)
  -> CloudWatch Alarm
    -> SNS topic (incident-alerts)
      -> HTTPS subscription
        -> ALB (ACM TLS, n8n.jordandesigns.io)
          -> n8n on ECS Fargate

n8n runbook:
  confirm SNS subscription
  -> parse alarm
  -> Claude Haiku incident summary
  -> Slack incident card
  -> EC2 RebootInstances (SigV4)
  -> wait 60s
  -> DescribeAlarms
  -> resolved  -> Slack resolved
     not yet   -> Slack escalate
```

## Components

| Layer | Resource | Role |
|---|---|---|
| Detection | **EC2 target** (t3.micro, AL2023) | Demo workload; ships a self-contained CPU-burn unit and an SSM instance role so it is reachable via Session Manager |
| Detection | **CloudWatch alarm** | `CPUUtilization >= 80%`, 2 evaluation periods of 5 minutes |
| Routing | **SNS topic** | Fans the alarm state change out to the n8n HTTPS endpoint |
| Control plane | **ALB + ACM** | Publicly trusted TLS so SNS accepts the HTTPS subscription |
| Control plane | **ECS Fargate** | Runs `n8nio/n8n`, the runbook engine; tasks accept traffic only from the ALB (SG-restricted) |
| Runbook | **Claude Haiku** | Generates the incident summary and recommended next step |
| Runbook | **Slack** | Incident, resolved, and escalation messages to `#incidents` |
| Remediation | **Scoped IAM user** | `ec2:RebootInstances` on the target only, plus read-only enrichment |
| IaC | **Terraform** | VPC, ALB, ECS, alarm, SNS, IAM, DNS; S3 remote state |

## Prerequisites

- Terraform >= 1.6, AWS CLI configured for account `692859913278`
- The S3 state backend bucket `tf-backend-jord-projs`
- A public Route 53 hosted zone for `jordandesigns.io` (the registrar-delegated zone)
- An Anthropic API key and a Slack bot token with `chat:write`

## Deploy

Secrets are kept out of Terraform state. Create the n8n SSM parameters first:

```bash
aws ssm put-parameter --name /incident-responder/n8n-basic-auth-password \
  --type SecureString --value "$(openssl rand -base64 18)"
aws ssm put-parameter --name /incident-responder/n8n-encryption-key \
  --type SecureString --value "$(openssl rand -hex 24)"
```

Then provision the infrastructure:

```bash
cd terraform
terraform init
terraform apply
```

Note the outputs (`n8n_url`, `n8n_webhook_endpoint`, `target_instance_id`, `alarm_name`, `n8n_iam_user`).

### Configure n8n

1. Open `n8n_url`, log in with the basic auth user (`admin`) and the SSM password.
2. Import `workflows/incident-responder.json`.
3. Create an access key for the scoped IAM user and add it as the workflow's AWS credential:
   ```bash
   aws iam create-access-key --user-name incident-responder-n8n
   ```
4. Add the Anthropic credential as HTTP Header Auth: header `x-api-key`, value = your API key.
5. Add the Slack credential (bot token) and confirm the bot is in `#incidents`.
6. Activate the workflow.

### Connect SNS to the live workflow

The SNS subscription is gated behind `enable_sns_subscription` (default `false`) because SNS rejects an unreachable endpoint at subscribe time, which would fail the first apply before n8n is serving the webhook. Once the workflow is imported and active, enable it so SNS delivers the confirmation to a live endpoint that n8n auto-confirms:

```bash
terraform apply -var="enable_sns_subscription=true"
```

Confirm it moved out of `PendingConfirmation`:

```bash
aws sns list-subscriptions-by-topic --topic-arn "$(terraform output -raw sns_topic_arn)" \
  --query 'Subscriptions[].SubscriptionArn'
```

## Validate

Drive CPU on the target so the alarm trips (the target has an SSM role, so Session Manager works with no inbound access; requires the `session-manager-plugin` locally):

```bash
aws ssm start-session --target "$(terraform output -raw target_instance_id)"
sudo systemctl start incident-stress   # burns every vCPU for 10 minutes
```

Within two evaluation periods the alarm enters ALARM and the runbook runs end to end. Confirm:

- Slack `#incidents` shows the incident card with the Haiku summary, then a resolved or escalation message.
- The n8n execution log shows the full path including the reboot and DescribeAlarms steps.
- The target instance shows a recent reboot in its system log.

## Destroy

```bash
cd terraform
terraform destroy
aws ssm delete-parameter --name /incident-responder/n8n-basic-auth-password
aws ssm delete-parameter --name /incident-responder/n8n-encryption-key
```

Teardown is clean. The ALB and its ENIs can take a minute to deregister, so a destroy retry occasionally clears a lingering ENI dependency. Confirm the SNS subscription and the IAM access key are gone afterward.

## Cost

About `$0.05/hour` while running (ALB, one 0.25 vCPU Fargate task, one t3.micro), roughly `$1/day`. Built to deploy, demo, and destroy the same day for well under a dollar. ACM and the existing hosted zone add nothing.

## Hardening notes

- In production the ECS task role would carry the remediation permissions directly so no IAM-user access key is needed; the scoped user here keeps the n8n credential setup simple for a demo.
- n8n runs on SQLite on ephemeral Fargate storage. For persistence across task restarts, attach EFS or point n8n at RDS Postgres.
- Alarm effects are scoped to a single reboot; a production runbook would add an approval gate before destructive actions and a maximum retry budget before escalation.
