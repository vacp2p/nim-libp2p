when defined(perf_reliability):
  import ./tests/scenarios_reliability as scenarios
else:
  import ./tests/scenarios_base as scenarios
