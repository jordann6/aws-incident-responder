"""Relay retry semantics and remediation guardrails, with AWS stubbed out."""

import importlib
import json
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "app"))


@pytest.fixture
def remediate(monkeypatch):
    monkeypatch.setenv("AWS_DEFAULT_REGION", "us-east-1")
    monkeypatch.setenv("OPS_TOPIC_ARN", "arn:aws:sns:us-east-1:111111111111:ops-alarms")
    monkeypatch.setenv("ALARM_READER_ROLE_ARN", "arn:aws:iam::111111111111:role/incident-alarm-reader")
    monkeypatch.setenv("KNOWN_ALARMS", json.dumps(["rds-cpu-high", "eks-failed-nodes", "backup-job-failed"]))
    monkeypatch.setenv("REMEDIATIONS", json.dumps({"rds-cpu-high": ["rds_failover"], "eks-failed-nodes": ["eks_scale"]}))
    monkeypatch.setenv("RDS_INSTANCE_ID", "prod-postgres")
    monkeypatch.setenv("EKS_CLUSTER_NAME", "prod")
    monkeypatch.setenv("EKS_NODEGROUP_NAME", "default")
    return importlib.reload(importlib.import_module("remediate"))


class _Rds:
    def __init__(self, status="available", multi_az=True):
        self.db = {"DBInstanceStatus": status, "MultiAZ": multi_az, "AvailabilityZone": "us-east-1a"}
        self.reboots = []

    def describe_db_instances(self, **_):
        return {"DBInstances": [self.db]}

    def reboot_db_instance(self, **kwargs):
        self.reboots.append(kwargs)


class _Eks:
    def __init__(self, desired, maximum, status="ACTIVE"):
        self.group = {"status": status, "scalingConfig": {"minSize": 1, "desiredSize": desired, "maxSize": maximum}}
        self.updates = []

    def describe_nodegroup(self, **_):
        return {"nodegroup": self.group}

    def update_nodegroup_config(self, **kwargs):
        self.updates.append(kwargs)


def _with_client(monkeypatch, module, fake):
    monkeypatch.setattr(module.boto3, "client", lambda *_a, **_k: fake)


def test_unknown_action_and_alarm_are_refused(remediate):
    with pytest.raises(ValueError):
        remediate.handler({"action": "delete_everything"}, None)
    with pytest.raises(ValueError):
        remediate.handler({"action": "remediate", "alarm_name": "not-a-central-alarm"}, None)


def test_rds_failover_only_when_available_and_multi_az(remediate, monkeypatch):
    rds = _Rds()
    _with_client(monkeypatch, remediate, rds)
    result = remediate.handler({"action": "remediate", "alarm_name": "rds-cpu-high"}, None)
    assert result["results"][0]["done"] is True
    assert rds.reboots == [{"DBInstanceIdentifier": "prod-postgres", "ForceFailover": True}]

    busy = _Rds(status="rebooting")
    _with_client(monkeypatch, remediate, busy)
    result = remediate.handler({"action": "remediate", "alarm_name": "rds-cpu-high"}, None)
    assert result["results"][0]["done"] is False and busy.reboots == []


def test_eks_scale_is_capped_at_max(remediate, monkeypatch):
    eks = _Eks(desired=2, maximum=3)
    _with_client(monkeypatch, remediate, eks)
    remediate.handler({"action": "remediate", "alarm_name": "eks-failed-nodes"}, None)
    assert eks.updates[0]["scalingConfig"]["desiredSize"] == 3

    full = _Eks(desired=3, maximum=3)
    _with_client(monkeypatch, remediate, full)
    result = remediate.handler({"action": "remediate", "alarm_name": "eks-failed-nodes"}, None)
    assert result["results"][0]["done"] is False and full.updates == []


def test_notify_only_alarm_takes_no_action(remediate):
    result = remediate.handler({"action": "remediate", "alarm_name": "backup-job-failed"}, None)
    assert result["results"] == []


def test_summary_falls_back_when_claude_fails(remediate, monkeypatch):
    def boom(_):
        raise RuntimeError("no model access")

    monkeypatch.setattr(remediate, "CLAUDE_MODEL", "anthropic.claude-opus-5-5")
    monkeypatch.setattr(remediate, "_claude", boom)
    result = remediate.summarize({"AlarmName": "rds-cpu-high", "NewStateValue": "ALARM", "NewStateReason": "forced"})
    assert result["source"] == "template" and "rds-cpu-high is ALARM" in result["summary"]
    assert "no model access" in result["error"]


def test_summary_skips_claude_when_no_model_is_configured(remediate, monkeypatch):
    def boom(_):
        raise AssertionError("the model must not be called")

    monkeypatch.setattr(remediate, "CLAUDE_MODEL", "")
    monkeypatch.setattr(remediate, "_claude", boom)
    result = remediate.summarize({"AlarmName": "rds-cpu-high", "NewStateValue": "ALARM", "NewStateReason": "forced"})
    assert result["source"] == "template" and "disabled" in result["error"]


def test_relay_reports_only_failed_messages(monkeypatch):
    monkeypatch.setenv("N8N_WEBHOOK_URL", "http://n8n.incident.internal:5678/webhook/incident")
    relay = importlib.reload(importlib.import_module("relay"))

    class _Resp:
        status = 200

        def __enter__(self):
            return self

        def __exit__(self, *_):
            return False

    monkeypatch.setattr(relay.urllib.request, "urlopen", lambda *_a, **_k: _Resp())
    event = {"Records": [
        {"messageId": "ok", "body": json.dumps({"AlarmName": "rds-cpu-high"})},
        {"messageId": "bad", "body": "not json"},
    ]}
    assert relay.handler(event, None) == {"batchItemFailures": [{"itemIdentifier": "bad"}]}
