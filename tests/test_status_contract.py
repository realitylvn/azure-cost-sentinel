"""Unit tests for build_status_dict - the pure Decision -> status.json contract
mapping - plus the non-fatal _publish_status helper. No Azure, no clock.
Headlines carry percentages only, never dollar figures (the Cost Sentinel rule)."""

from datetime import datetime, timezone

from function_app import Decision, build_status_dict

NOW = datetime(2026, 9, 4, 8, 0, 0, tzinfo=timezone.utc)
TS = "2026-09-04T08:00:00Z"


def _assert_fixed(d):
    assert d["schema_version"] == 1
    assert d["project"] == "azure-cost-sentinel"
    assert d["cadence"] == "scheduled-daily"
    assert d["repo_url"] == "https://github.com/realitylvn/azure-cost-sentinel"
    assert d["generated_at"] == TS
    assert d["last_run_at"] == TS


def _no_dollar(d):
    assert "$" not in d["headline"]


def test_no_anomaly_is_ok():
    d = build_status_dict(Decision("no_anomaly", 4.1), NOW, threshold_pct=25)
    _assert_fixed(d)
    _no_dollar(d)
    assert d["status"] == "ok"
    assert d["detail"] == {
        "delta_pct": 4.1,
        "threshold_pct": 25,
        "suppressed_by_cooldown": False,
        "baseline_too_low": False,
    }


def test_low_baseline_is_ok_with_null_delta_and_the_flag():
    d = build_status_dict(Decision("low_baseline"), NOW, threshold_pct=25)
    assert d["status"] == "ok"
    assert d["detail"]["delta_pct"] is None
    assert d["detail"]["baseline_too_low"] is True


def test_insufficient_data_is_ok():
    d = build_status_dict(Decision("insufficient_data"), NOW, threshold_pct=25)
    assert d["status"] == "ok"
    assert "history" in d["headline"].lower() or "warming up" in d["headline"].lower()
    assert d["detail"]["delta_pct"] is None


def test_suppressed_is_a_finding_with_the_cooldown_flag():
    d = build_status_dict(Decision("suppressed", 40.0), NOW, threshold_pct=25)
    _no_dollar(d)
    assert d["status"] == "finding"
    assert d["detail"]["suppressed_by_cooldown"] is True
    assert d["detail"]["delta_pct"] == 40.0


def test_anomaly_is_a_finding():
    d = build_status_dict(Decision("anomaly", 63.2), NOW, threshold_pct=25)
    _no_dollar(d)
    assert d["status"] == "finding"
    assert d["detail"]["delta_pct"] == 63.2
    assert d["detail"]["suppressed_by_cooldown"] is False


def test_error_reason_is_an_error():
    d = build_status_dict(
        None, NOW, threshold_pct=25, error_reason="Cost Management API call failed"
    )
    _assert_fixed(d)
    assert d["status"] == "error"
    assert d["headline"] == "Cost Management API call failed"
    assert d["detail"] == {
        "delta_pct": None,
        "threshold_pct": 25,
        "suppressed_by_cooldown": False,
        "baseline_too_low": False,
    }


def test_result_is_json_serializable():
    import json

    json.dumps(build_status_dict(Decision("no_anomaly", 4.1), NOW, threshold_pct=25))


def test_web_container_uses_the_connection_string_and_web_container(monkeypatch):
    import function_app

    captured = {}

    class FakeBlobService:
        @classmethod
        def from_connection_string(cls, conn_str):
            captured["conn_str"] = conn_str
            return cls()

        def get_container_client(self, name):
            captured["container"] = name
            return "cc"

    monkeypatch.setattr(function_app, "BlobServiceClient", FakeBlobService)
    monkeypatch.setenv(
        "STATE_STORAGE_CONNECTION_STRING",
        "DefaultEndpointsProtocol=https;AccountName=x;AccountKey=k;EndpointSuffix=core.windows.net",
    )
    assert function_app._web_container() == "cc"
    assert "AccountKey=" in captured["conn_str"]
    assert captured["container"] == "$web"


def test_publish_status_swallows_a_storage_failure(monkeypatch):
    import function_app

    def boom():
        raise RuntimeError("down")

    monkeypatch.setattr(function_app, "_web_container", boom)
    function_app._publish_status({"schema_version": 1})
