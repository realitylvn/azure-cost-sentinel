import json
import logging
import os
from datetime import datetime, timedelta, timezone

import azure.functions as func
from azure.core.exceptions import AzureError
from azure.identity import DefaultAzureCredential
from azure.mgmt.costmanagement import CostManagementClient
from azure.storage.blob import BlobServiceClient

app = func.FunctionApp()

STATE_BLOB_NAME = "last-alert.json"

# Below this trailing-average daily spend, a percentage delta is meaningless noise
# (a $0.01 -> $0.05 day reads as "400% above average" and tells us nothing real).
MINIMUM_BASELINE_USD = 1.0


def _query_daily_cost(credential, subscription_id: str, days: int = 8):
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


def _state_container(credential):
    account = os.environ["STATE_STORAGE_ACCOUNT_NAME"]
    container_name = os.environ["STATE_CONTAINER_NAME"]
    blob_service = BlobServiceClient(
        account_url=f"https://{account}.blob.core.windows.net", credential=credential
    )
    return blob_service.get_container_client(container_name)


def _get_last_alert_time(container):
    blob = container.get_blob_client(STATE_BLOB_NAME)
    if not blob.exists():
        return None
    data = json.loads(blob.download_blob().readall())
    return datetime.fromisoformat(data["last_alert_utc"])


def _set_last_alert_time(container, when: datetime) -> None:
    blob = container.get_blob_client(STATE_BLOB_NAME)
    blob.upload_blob(json.dumps({"last_alert_utc": when.isoformat()}), overwrite=True)


@app.timer_trigger(schedule="0 0 8 * * *", arg_name="timer", run_on_startup=False)
def cost_anomaly_check(timer: func.TimerRequest) -> None:
    threshold_pct = float(os.environ.get("ANOMALY_THRESHOLD_PCT", "20"))
    cooldown_days = int(os.environ.get("ALERT_COOLDOWN_DAYS", "3"))
    # Wired in by infra/resources.bicep from the azd environment. The managed
    # identity only holds Cost Management Reader on this one subscription anyway,
    # so there's nothing to "discover" - pass the ID it operates on as config and
    # skip pulling the whole ARM resource SDK just to read it back.
    subscription_id = os.environ["AZURE_SUBSCRIPTION_ID"]

    credential = DefaultAzureCredential()

    try:
        daily = _query_daily_cost(credential, subscription_id, days=8)
    except AzureError as exc:
        logging.error(f"Cost Management API call failed, skipping this run: {exc}")
        return
    except Exception as exc:  # noqa: BLE001 - any failure here must not crash the app
        logging.error(f"Unexpected error querying cost data, skipping this run: {exc}")
        return

    if len(daily) < 8:
        logging.info("Insufficient data (fewer than 8 complete days) - skipping anomaly evaluation.")
        return

    *history, latest = daily
    trailing_avg = sum(cost for _, cost in history) / len(history)
    latest_cost = latest[1]

    if trailing_avg < MINIMUM_BASELINE_USD:
        logging.info(
            "Trailing 7-day average is near zero - skipping the percentage-based "
            "check to avoid a divide-by-zero-shaped false alarm."
        )
        return

    delta_pct = ((latest_cost - trailing_avg) / trailing_avg) * 100

    if delta_pct <= threshold_pct:
        logging.info(f"No anomaly: {delta_pct:.1f}% vs {threshold_pct}% threshold.")
        return

    container = _state_container(credential)
    now = datetime.now(timezone.utc)
    last_alert = _get_last_alert_time(container)

    if last_alert and (now - last_alert) < timedelta(days=cooldown_days):
        logging.info(
            f"Anomaly detected ({delta_pct:.0f}% above average) but suppressed - "
            f"last alert was {(now - last_alert).days} day(s) ago, within the "
            f"{cooldown_days}-day cooldown."
        )
        return

    # This exact "AnomalyDetected" prefix is what infra/resources.bicep's
    # scheduledQueryRules alert watches for - keep them in sync if this changes.
    logging.warning(f"AnomalyDetected: {delta_pct:.0f}% above 7-day average")
    _set_last_alert_time(container, now)
