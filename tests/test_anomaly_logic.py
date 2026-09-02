"""Unit tests for the pure anomaly-decision logic in function_app.evaluate_anomaly.

Everything here is deterministic: no Azure, no network, no clock. The function
under test takes the daily cost series plus config and returns a Decision; all
I/O (Cost Management query, blob state, logging) stays in the timer entrypoint.
"""

from datetime import datetime, timedelta, timezone

import function_app


NOW = datetime(2026, 9, 2, 8, 0, tzinfo=timezone.utc)


def _decide(daily_costs, *, threshold_pct=25.0, minimum_baseline_usd=1.0,
            cooldown_days=3, last_alert_utc=None, now=NOW):
    return function_app.evaluate_anomaly(
        daily_costs,
        threshold_pct=threshold_pct,
        minimum_baseline_usd=minimum_baseline_usd,
        cooldown_days=cooldown_days,
        last_alert_utc=last_alert_utc,
        now=now,
    )


def test_flags_anomaly_when_latest_exceeds_threshold():
    # 7 days at $10, then a $15 day = 50% above the trailing average.
    decision = _decide([10.0] * 7 + [15.0], threshold_pct=25.0)
    assert decision.outcome == "anomaly"
    assert round(decision.delta_pct) == 50


def test_no_anomaly_when_latest_is_within_threshold():
    decision = _decide([10.0] * 7 + [11.0], threshold_pct=25.0)
    assert decision.outcome == "no_anomaly"
    assert round(decision.delta_pct) == 10


def test_skips_when_trailing_average_is_below_baseline():
    # Pennies a day: a 25x jump is still noise, not a signal.
    decision = _decide([0.02] * 7 + [0.50], minimum_baseline_usd=1.0)
    assert decision.outcome == "low_baseline"
    assert decision.delta_pct is None


def test_lower_baseline_lets_a_low_spend_anomaly_through():
    # Same series as above, but the operator has opted into a lower baseline.
    decision = _decide([0.02] * 7 + [0.50], minimum_baseline_usd=0.01,
                       threshold_pct=25.0)
    assert decision.outcome == "anomaly"


def test_suppresses_repeat_alert_inside_cooldown_window():
    decision = _decide(
        [10.0] * 7 + [20.0],
        cooldown_days=3,
        last_alert_utc=NOW - timedelta(days=1),
    )
    assert decision.outcome == "suppressed"
    assert round(decision.delta_pct) == 100


def test_alerts_again_once_cooldown_has_expired():
    decision = _decide(
        [10.0] * 7 + [20.0],
        cooldown_days=3,
        last_alert_utc=NOW - timedelta(days=5),
    )
    assert decision.outcome == "anomaly"


def test_insufficient_data_when_fewer_than_eight_days():
    decision = _decide([10.0, 10.0, 12.0])
    assert decision.outcome == "insufficient_data"
    assert decision.delta_pct is None
