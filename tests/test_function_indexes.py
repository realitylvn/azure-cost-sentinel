"""The check that a plain `azd deploy` doesn't do: confirm the worker can import
function_app and register the trigger. A broken import here registers zero
functions in Azure while the deploy still reports success (this project hit that
twice - see REVIEW.md)."""

import function_app


def test_worker_indexes_exactly_the_timer_trigger():
    functions = function_app.app.get_functions()
    names = [f.get_function_name() for f in functions]
    assert names == ["cost_anomaly_check"]

    bindings = [b.type for f in functions for b in f.get_bindings()]
    assert bindings == ["timerTrigger"]
