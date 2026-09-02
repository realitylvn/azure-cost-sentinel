import json
import logging
import os
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone

import azure.functions as func
from azure.core.exceptions import AzureError
from azure.identity import DefaultAzureCredential
from azure.mgmt.costmanagement import CostManagementClient
from azure.storage.blob import BlobServiceClient

app = func.FunctionApp()

STATE_BLOB_NAME = "last-alert.json"

# Full days of history the check needs before it will evaluate: 7 trailing days
# to average over, plus yesterday to compare against them.
REQUIRED_DAYS = 8

# Default floor for the trailing average, overridable via the MINIMUM_BASELINE_USD
# app setting. Below this, a percentage delta is meaningless noise (a $0.01 -> $0.05
# day reads as "400% above average" and tells us nothing real).
DEFAULT_MINIMUM_BASELINE_USD = 1.0


@dataclass(frozen=True)
class Decision:
    """The outcome of evaluating one day's spend against its trailing history.

    outcome is one of: "insufficient_data", "low_baseline", "no_anomaly",
    "suppressed", "anomaly". delta_pct is the percentage above the trailing
    average, present whenever it could be computed (the last three outcomes).
    """

    outcome: str
    delta_pct: float | None = None


def evaluate_anomaly(
    daily_costs,
    *,
    threshold_pct: float,
    minimum_baseline_usd: float,
    cooldown_days: int,
    last_alert_utc: datetime | None,
    now: datetime,
    required_days: int = REQUIRED_DAYS,
) -> Decision:
    """Decide whether a run should alert. Pure: no I/O, no clock, no globals.

    daily_costs is oldest-first and its final element is yesterday's spend; the
    rest form the trailing window.
    """
    if len(daily_costs) < required_days:
        return Decision("insufficient_data")

    *history, latest_cost = daily_costs
    trailing_avg = sum(history) / len(history)

    if trailing_avg < minimum_baseline_usd:
        return Decision("low_baseline")

    delta_pct = ((latest_cost - trailing_avg) / trailing_avg) * 100

    if delta_pct <= threshold_pct:
        return Decision("no_anomaly", delta_pct)

    if last_alert_utc and (now - last_alert_utc) < timedelta(days=cooldown_days):
        return Decision("suppressed", delta_pct)

    return Decision("anomaly", delta_pct)


def _query_daily_cost(credential, subscription_id: str, days: int = REQUIRED_DAYS):
    """Trailing `days` complete days of subscription spend, oldest first.
    Never includes today - Cost Management API data lags, so today is always partial."""
    client = CostManagementClient(credential)
    today = datetime.now(timezone.utc).date()
    end = today - timedelta(days=1)
    start = end - timedelta(days=days - 1)

    result = client.query.usage(
        f"/subscriptions/{subscription_id}",
        {
            "type": "ActualCost",
            "timeframe": "Custom",
            "timePeriod": {"from": start.isoformat(), "to": end.isoformat()},
            "dataset": {
                "granularity": "Daily",
                "aggregation": {"totalCost": {"name": "Cost", "function": "Sum"}},
            },
        },
    )

    columns = [c.name for c in result.columns]
    cost_idx = columns.index("Cost")
    date_idx = columns.index("UsageDate")

    by_date = {str(row[date_idx]): float(row[cost_idx]) for row in result.rows}

    ordered = []
    for i in range(days):
        d = start + timedelta(days=i)
        ordered.append((d, by_date.get(d.strftime("%Y%m%d"), 0.0)))
    return ordered


def _state_container():
    """Container client for the dedupe-state blob, over an account-key connection
    string - NOT the managed identity. The identity holds only Cost Management
    Reader on the resource group; it has no data-plane role on this storage
    account, and granting one just to write a single timestamp would widen it for
    no reason. STATE_STORAGE_CONNECTION_STRING is wired in resources.bicep from
    the same account key as AzureWebJobsStorage."""
    container_name = os.environ["STATE_CONTAINER_NAME"]
    blob_service = BlobServiceClient.from_connection_string(
        os.environ["STATE_STORAGE_CONNECTION_STRING"]
    )
    return blob_service.get_container_client(container_name)


def _get_last_alert_time(container):
    blob = container.get_blob_client(STATE_BLOB_NAME)
    if not blob.exists():
        return None
    data = json.loads(blob.download_blob().readall())
    return datetime.fromisoformat(data["last_alert_utc"])


def _read_last_alert_time(container):
    """_get_last_alert_time, but a storage failure returns None instead of raising.

    The dedupe timestamp is a best-effort convenience: if we can't read it, the
    worst case is one duplicate email, which beats crashing a run that might need
    to alert. The read happens every run now, not just on anomaly days.
    """
    try:
        return _get_last_alert_time(container)
    except Exception as exc:  # noqa: BLE001
        logging.warning(f"Could not read dedupe state, treating as no prior alert: {exc}")
        return None


def _set_last_alert_time(container, when: datetime) -> None:
    blob = container.get_blob_client(STATE_BLOB_NAME)
    blob.upload_blob(json.dumps({"last_alert_utc": when.isoformat()}), overwrite=True)


@app.timer_trigger(schedule="0 0 8 * * *", arg_name="timer", run_on_startup=False)
def cost_anomaly_check(timer: func.TimerRequest) -> None:
    threshold_pct = float(os.environ.get("ANOMALY_THRESHOLD_PCT", "20"))
    cooldown_days = int(os.environ.get("ALERT_COOLDOWN_DAYS", "3"))
    minimum_baseline_usd = float(
        os.environ.get("MINIMUM_BASELINE_USD", str(DEFAULT_MINIMUM_BASELINE_USD))
    )
    # Wired in by infra/resources.bicep from the azd environment. The managed
    # identity only holds Cost Management Reader on this one subscription anyway,
    # so there's nothing to "discover" - pass the ID it operates on as config and
    # skip pulling the whole ARM resource SDK just to read it back.
    subscription_id = os.environ["AZURE_SUBSCRIPTION_ID"]

    credential = DefaultAzureCredential()

    try:
        daily = _query_daily_cost(credential, subscription_id, days=REQUIRED_DAYS)
    except AzureError as exc:
        logging.error(f"Cost Management API call failed, skipping this run: {exc}")
        return
    except Exception as exc:  # noqa: BLE001 - any failure here must not crash the app
        logging.error(f"Unexpected error querying cost data, skipping this run: {exc}")
        return

    now = datetime.now(timezone.utc)
    container = _state_container()
    last_alert = _read_last_alert_time(container)

    decision = evaluate_anomaly(
        [cost for _, cost in daily],
        threshold_pct=threshold_pct,
        minimum_baseline_usd=minimum_baseline_usd,
        cooldown_days=cooldown_days,
        last_alert_utc=last_alert,
        now=now,
    )

    if decision.outcome == "insufficient_data":
        logging.info(
            f"Insufficient data (fewer than {REQUIRED_DAYS} complete days) - "
            "skipping anomaly evaluation."
        )
    elif decision.outcome == "low_baseline":
        logging.info(
            f"Trailing {REQUIRED_DAYS - 1}-day average is below the "
            f"${minimum_baseline_usd:g}/day baseline - skipping the percentage-based "
            "check to avoid a divide-by-zero-shaped false alarm."
        )
    elif decision.outcome == "no_anomaly":
        logging.info(
            f"No anomaly: {decision.delta_pct:.1f}% vs {threshold_pct}% threshold."
        )
    elif decision.outcome == "suppressed":
        logging.info(
            f"Anomaly detected ({decision.delta_pct:.0f}% above average) but suppressed - "
            f"last alert was {(now - last_alert).days} day(s) ago, within the "
            f"{cooldown_days}-day cooldown."
        )
    elif decision.outcome == "anomaly":
        # This exact "AnomalyDetected" prefix is what infra/resources.bicep's
        # scheduledQueryRules alert watches for - keep them in sync if this changes.
        logging.warning(
            f"AnomalyDetected: {decision.delta_pct:.0f}% above 7-day average"
        )
        # The alert has already been raised via the trace above. A failure to
        # persist the cooldown timestamp must not fail the run - worst case is a
        # duplicate email on the next run, which beats a crash after we've alerted.
        try:
            _set_last_alert_time(container, now)
        except Exception as exc:  # noqa: BLE001
            logging.warning(f"Could not persist dedupe timestamp: {exc}")
