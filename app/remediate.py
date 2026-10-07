"""Remediation actions for the landing zone incident responder.

n8n orchestrates the runbook; this function is the only thing it may call in
AWS, through an assumed role that can invoke nothing else. Every action is on a
fixed allow list, and every remediation is chosen from configuration by alarm
name, never from free text in the request:

  summarize    Claude (Amazon Bedrock, in-region) turns the alarm into an
               on-call note; a plain template stands in if the call fails.
  notify       Publish a notice to the central ops topic (its email
               subscribers get it next to the raw alarm).
  remediate    Run the configured actions for the alarm: rds_failover,
               eks_scale, eks_restart. Each one checks state first and
               declines rather than stacking a second change on a busy target.
  alarm_state  Read the central alarm through the monitoring account's
               read-only role, so the runbook can confirm recovery.
"""

import base64
import json
import os
import re
import ssl
import tempfile
import urllib.request
from datetime import datetime, timezone

import boto3
from botocore.signers import RequestSigner

REGION = os.environ.get("AWS_REGION", "us-east-1")
OPS_TOPIC_ARN = os.environ["OPS_TOPIC_ARN"]
ALARM_READER_ROLE_ARN = os.environ["ALARM_READER_ROLE_ARN"]
KNOWN_ALARMS = set(json.loads(os.environ["KNOWN_ALARMS"]))
REMEDIATIONS = json.loads(os.environ["REMEDIATIONS"])
RDS_INSTANCE_ID = os.environ.get("RDS_INSTANCE_ID", "")
EKS_CLUSTER_NAME = os.environ.get("EKS_CLUSTER_NAME", "")
EKS_NODEGROUP_NAME = os.environ.get("EKS_NODEGROUP_NAME", "")
EKS_RESTART_TARGET = os.environ.get("EKS_RESTART_TARGET", "")  # namespace/deployment
# Empty means the Claude call is skipped and the template note is used.
CLAUDE_MODEL = os.environ.get("CLAUDE_MODEL", "")

ALARM_NAME = re.compile(r"^[A-Za-z0-9._-]{1,255}$")


def handler(event, _context):
    action = event.get("action")
    if action == "summarize":
        return summarize(event.get("alarm") or {})
    if action == "notify":
        return notify(str(event.get("subject", "")), str(event.get("message", "")))
    if action == "remediate":
        return remediate(_alarm_name(event))
    if action == "alarm_state":
        return alarm_state(_alarm_name(event))
    raise ValueError(f"unsupported action {action!r}")


def _alarm_name(event):
    name = str(event.get("alarm_name", ""))
    if not ALARM_NAME.match(name) or name not in KNOWN_ALARMS:
        raise ValueError(f"unknown alarm {name!r}")
    return name


# --- summarize ---------------------------------------------------------------------

SYSTEM_PROMPT = (
    "You write the first note an on-call engineer reads about a CloudWatch alarm in "
    "an AWS landing zone (prod EKS cluster, Multi-AZ PostgreSQL on RDS, a central "
    "Network Firewall, AWS Backup). Using only the alarm JSON you are given, say in "
    "under 120 words what fired, the likely impact, and the first thing to check. "
    "Plain text, no headings, no markdown."
)


def summarize(alarm):
    alarm_json = json.dumps(_alarm_fields(alarm), sort_keys=True)
    if not CLAUDE_MODEL:
        return {"summary": _template_summary(alarm), "source": "template",
                "error": "claude disabled: no model configured"}
    try:
        text = _claude(alarm_json)
        return {"summary": text, "source": "claude", "model": CLAUDE_MODEL}
    except Exception as exc:  # noqa: BLE001 - the runbook must not stall on the summary
        return {
            "summary": _template_summary(alarm),
            "source": "template",
            "error": f"{type(exc).__name__}: {exc}"[:500],
        }


def _alarm_fields(alarm):
    keys = ("AlarmName", "AlarmDescription", "NewStateValue", "OldStateValue",
            "NewStateReason", "StateChangeTime", "Region", "Trigger")
    return {k: alarm.get(k) for k in keys if k in alarm}


def _claude(alarm_json):
    # Imported here so the remediation paths do not depend on the SDK loading.
    from anthropic import AnthropicBedrockMantle

    client = AnthropicBedrockMantle(aws_region=REGION, max_retries=1, timeout=45.0)
    message = client.messages.create(
        model=CLAUDE_MODEL,
        max_tokens=2000,
        system=SYSTEM_PROMPT,
        output_config={"effort": "low"},
        messages=[{"role": "user", "content": alarm_json}],
    )
    if message.stop_reason == "refusal":
        raise RuntimeError("model declined the request")
    text = "".join(block.text for block in message.content if block.type == "text").strip()
    if not text:
        raise RuntimeError(f"no text in response (stop_reason {message.stop_reason})")
    return text


def _template_summary(alarm):
    return (
        f"{alarm.get('AlarmName', 'unknown alarm')} is {alarm.get('NewStateValue', '?')}: "
        f"{alarm.get('NewStateReason', 'no reason given')}"
    )


# --- notify ------------------------------------------------------------------------

def notify(subject, message):
    # SNS subjects are ASCII, single line, at most 100 characters. The body is
    # plain text: the responder's queue subscription only takes messages whose
    # JSON body has an AlarmName, so a notice can never loop back into the runbook.
    clean_subject = re.sub(r"[^\x20-\x7e]", " ", subject).strip()[:100] or "Incident responder"
    resp = boto3.client("sns").publish(
        TopicArn=OPS_TOPIC_ARN, Subject=clean_subject, Message=message[:200000] or "(empty)"
    )
    return {"published": resp["MessageId"]}


# --- remediate ---------------------------------------------------------------------

def remediate(alarm_name):
    actions = REMEDIATIONS.get(alarm_name, [])
    if not actions:
        return {"alarm": alarm_name, "results": [], "note": "notify only, no automatic remediation"}
    runners = {"rds_failover": rds_failover, "eks_scale": eks_scale, "eks_restart": eks_restart}
    results = []
    for name in actions:
        runner = runners.get(name)
        if runner is None:
            results.append({"action": name, "done": False, "reason": "not an allowed action"})
            continue
        try:
            results.append({"action": name, **runner()})
        except Exception as exc:  # noqa: BLE001 - report each action's outcome
            results.append({"action": name, "done": False, "reason": f"{type(exc).__name__}: {exc}"[:500]})
    return {"alarm": alarm_name, "results": results}


def rds_failover():
    if not RDS_INSTANCE_ID:
        return {"done": False, "reason": "no RDS instance configured"}
    rds = boto3.client("rds")
    db = rds.describe_db_instances(DBInstanceIdentifier=RDS_INSTANCE_ID)["DBInstances"][0]
    if not db.get("MultiAZ"):
        return {"done": False, "reason": "instance is not Multi-AZ; a failover is not possible"}
    if db["DBInstanceStatus"] != "available":
        return {"done": False, "reason": f"instance is {db['DBInstanceStatus']}; not stacking a failover"}
    rds.reboot_db_instance(DBInstanceIdentifier=RDS_INSTANCE_ID, ForceFailover=True)
    return {"done": True, "detail": f"reboot with failover started on {RDS_INSTANCE_ID}",
            "previous_az": db.get("AvailabilityZone")}


def eks_scale():
    if not (EKS_CLUSTER_NAME and EKS_NODEGROUP_NAME):
        return {"done": False, "reason": "no node group configured"}
    eks = boto3.client("eks")
    group = eks.describe_nodegroup(clusterName=EKS_CLUSTER_NAME, nodegroupName=EKS_NODEGROUP_NAME)["nodegroup"]
    if group["status"] != "ACTIVE":
        return {"done": False, "reason": f"node group is {group['status']}; not stacking an update"}
    scaling = group["scalingConfig"]
    if scaling["desiredSize"] >= scaling["maxSize"]:
        return {"done": False, "reason": f"already at max size {scaling['maxSize']}"}
    desired = scaling["desiredSize"] + 1
    eks.update_nodegroup_config(
        clusterName=EKS_CLUSTER_NAME,
        nodegroupName=EKS_NODEGROUP_NAME,
        scalingConfig={**scaling, "desiredSize": desired},
    )
    return {"done": True, "detail": f"desired size {scaling['desiredSize']} -> {desired}"}


def eks_restart():
    if not (EKS_CLUSTER_NAME and "/" in EKS_RESTART_TARGET):
        return {"done": False, "reason": "no restart target configured"}
    namespace, deployment = EKS_RESTART_TARGET.split("/", 1)
    cluster = boto3.client("eks").describe_cluster(name=EKS_CLUSTER_NAME)["cluster"]
    # Same patch kubectl rollout restart sends: a new pod-template annotation.
    patch = {"spec": {"template": {"metadata": {"annotations": {
        "kubectl.kubernetes.io/restartedAt": datetime.now(timezone.utc).isoformat()}}}}}
    url = f"{cluster['endpoint']}/apis/apps/v1/namespaces/{namespace}/deployments/{deployment}"
    request = urllib.request.Request(  # noqa: S310 - private EKS endpoint from DescribeCluster
        url,
        data=json.dumps(patch).encode("utf-8"),
        method="PATCH",
        headers={
            "Authorization": f"Bearer {_eks_token(EKS_CLUSTER_NAME)}",
            "Content-Type": "application/strategic-merge-patch+json",
        },
    )
    context = _cluster_tls(cluster["certificateAuthority"]["data"])
    with urllib.request.urlopen(request, timeout=10, context=context) as resp:  # noqa: S310  # nosec B310
        status = resp.status
    return {"done": 200 <= status < 300, "detail": f"rollout restart of {EKS_RESTART_TARGET}: HTTP {status}"}


def _eks_token(cluster_name):
    """The bearer token aws eks get-token produces: a presigned STS call."""
    session = boto3.session.Session()
    sts = session.client("sts", region_name=REGION)
    signer = RequestSigner(sts.meta.service_model.service_id, REGION, "sts", "v4",
                           session.get_credentials(), session.events)
    url = signer.generate_presigned_url(
        {
            "method": "GET",
            "url": f"https://sts.{REGION}.amazonaws.com/?Action=GetCallerIdentity&Version=2011-06-15",
            "body": {},
            "headers": {"x-k8s-aws-id": cluster_name},
            "context": {},
        },
        region_name=REGION,
        expires_in=60,
        operation_name="",
    )
    return "k8s-aws-v1." + base64.urlsafe_b64encode(url.encode("utf-8")).decode("utf-8").rstrip("=")


def _cluster_tls(ca_data):
    with tempfile.NamedTemporaryFile("wb", suffix=".pem", delete=False) as handle:
        handle.write(base64.b64decode(ca_data))
    return ssl.create_default_context(cafile=handle.name)


# --- alarm_state -------------------------------------------------------------------

def alarm_state(alarm_name):
    creds = boto3.client("sts").assume_role(
        RoleArn=ALARM_READER_ROLE_ARN, RoleSessionName="incident-responder"
    )["Credentials"]
    cloudwatch = boto3.client(
        "cloudwatch",
        aws_access_key_id=creds["AccessKeyId"],
        aws_secret_access_key=creds["SecretAccessKey"],
        aws_session_token=creds["SessionToken"],
    )
    alarms = cloudwatch.describe_alarms(AlarmNames=[alarm_name])["MetricAlarms"]
    if not alarms:
        return {"alarm": alarm_name, "state": "MISSING"}
    alarm = alarms[0]
    return {
        "alarm": alarm_name,
        "state": alarm["StateValue"],
        "reason": alarm.get("StateReason", ""),
        "updated": alarm["StateUpdatedTimestamp"].isoformat(),
    }
