"""
Reads test-result Cloud Logging entries (written as JSON to runner pod stdout
by TearDownDistTest) and writes a Markdown summary to $GITHUB_STEP_SUMMARY.

Expected env vars (all set by the workflow before calling this script):
  ENTRIES_FILE       - path to a JSON file containing gcloud logging read output
  RUNID              - the test run ID (e.g. 20260430-060144)
  CLUSTER_NAME       - GKE cluster name
  GCP_PROJECT        - GCP project ID
  JOB_START_TIME     - ISO timestamp used as the Cloud Logging URL startTime
  JOB_START          - job startTime from kubectl (for duration calc)
  JOB_END            - job completionTime from kubectl (for duration calc)
  GITHUB_STEP_SUMMARY - path to the GHA step summary file
"""

import json, os, sys, urllib.parse
from datetime import datetime

with open(os.environ["ENTRIES_FILE"]) as f:
    entries = json.load(f)

runid   = os.environ["RUNID"]
cluster = os.environ["CLUSTER_NAME"]
project = os.environ["GCP_PROJECT"]
start   = os.environ["JOB_START_TIME"]

if not entries:
    with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as f:
        f.write(f"No test results found for run `{runid}`\n")
    sys.exit(0)

# Aggregate by fixture in run order; mark Failed if any method failed.
fixtures, order = {}, []
for entry in entries:
    p = entry.get("jsonPayload", {})
    fixture, status = p.get("fixture", ""), p.get("status", "")
    if not fixture:
        continue
    if fixture not in fixtures:
        order.append(fixture)
        fixtures[fixture] = status
    elif status == "Failed":
        fixtures[fixture] = status

# Job duration
duration = ""
try:
    fmt = "%Y-%m-%dT%H:%M:%SZ"
    secs = int(
        (
            datetime.strptime(os.environ["JOB_END"], fmt)
            - datetime.strptime(os.environ["JOB_START"], fmt)
        ).total_seconds()
    )
    duration = f" in {secs // 60}m {secs % 60}s"
except Exception:
    pass


def log_url(fixture):
    query = "\n".join([
        'resource.type="k8s_container"',
        f'resource.labels.cluster_name="{cluster}"',
        f'labels."k8s-pod/runid"="{runid}"',
        f'labels."k8s-pod/fixturename"="{fixture.lower()}"',
    ])
    encoded = urllib.parse.quote(query, safe="")
    return (
        f"https://console.cloud.google.com/logs/query"
        f";query={encoded}"
        f";startTime={start}"
        f"?project={project}"
    )


passed = sum(1 for s in fixtures.values() if s == "Passed")
total  = len(fixtures)

lines = ["## Test Results", ""]
for fixture in order:
    icon = "✅" if fixtures[fixture] == "Passed" else "❌"
    lines.append(f"- {icon} [{fixture}]({log_url(fixture)})")
lines += ["", f"**{passed}/{total} tests passed{duration}**"]

with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as f:
    f.write("\n".join(lines) + "\n")
