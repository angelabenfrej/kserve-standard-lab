"""Submit the compiled pipeline to KFP and block until the run finishes.

Invoked by `make pipeline-run`, which holds a port-forward to the KFP API open
for the duration. Exits non-zero unless the run SUCCEEDED, so a failed run
fails the make target rather than printing a state and carrying on.
"""

import os
import sys
import time

import kfp

HOST = os.environ.get("KFP_HOST", "http://localhost:8888")
PACKAGE = "pipeline/iris_pipeline.yaml"
EXPERIMENT = "iris"
TIMEOUT_S = 1800
TERMINAL = {"SUCCEEDED", "FAILED", "CANCELED", "SKIPPED"}


def main() -> int:
    client = kfp.Client(host=HOST)
    # Returns the existing experiment when one with this name is already there.
    experiment = client.create_experiment(name=EXPERIMENT)
    run = client.run_pipeline(
        experiment_id=experiment.experiment_id,
        job_name=f"iris-train-deploy-{int(time.time())}",
        pipeline_package_path=PACKAGE,
    )
    print(f"run_id: {run.run_id}")

    deadline = time.time() + TIMEOUT_S
    last = None
    while time.time() < deadline:
        state = client.get_run(run_id=run.run_id).state
        if state != last:
            print(f"[{time.strftime('%H:%M:%S')}] {state}")
            last = state
        if state in TERMINAL:
            return 0 if state == "SUCCEEDED" else 1
        time.sleep(15)

    print(f"run still not finished after {TIMEOUT_S}s", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
