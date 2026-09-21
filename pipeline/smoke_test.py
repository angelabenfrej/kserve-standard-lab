"""Call the deployed InferenceService and check it returns sane predictions.

Step 3 of the KFP pipeline. `Ready` on an InferenceService only means the pods
passed their probes; it does not mean the model loaded correctly or that the
prediction path works. This step is what turns "deployed" into "serving".

Reaches the predictor by cluster DNS rather than a port-forward, since it runs
as a pod itself.
"""

import json
import sys
import time
import urllib.error
import urllib.request

NAME = "iris-pipeline"
URL = f"http://{NAME}-predictor.default.svc.cluster.local/v1/models/{NAME}:predict"

# Two iris samples that a correctly trained model classifies as versicolor (1);
# the same pair the README uses for the hand-run smoke tests.
PAYLOAD = {"instances": [[6.8, 2.8, 4.8, 1.4], [6.0, 3.4, 4.5, 1.6]]}
EXPECTED = [1, 1]


def call(attempts: int = 10, delay: int = 10) -> dict:
    body = json.dumps(PAYLOAD).encode()
    last: Exception | None = None
    for i in range(1, attempts + 1):
        req = urllib.request.Request(
            URL, data=body, headers={"Content-Type": "application/json"}
        )
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                return json.loads(resp.read())
        except (urllib.error.URLError, TimeoutError) as exc:
            # The Service can resolve slightly before endpoints are populated.
            last = exc
            print(f"attempt {i}/{attempts} failed: {exc}")
            time.sleep(delay)
    raise SystemExit(f"predictor never answered: {last}")


def main() -> None:
    print(f"POST {URL}")
    result = call()
    print(f"response: {json.dumps(result)}")

    predictions = result.get("predictions")
    if predictions is None:
        raise SystemExit(f"no 'predictions' key in response: {result}")
    if predictions != EXPECTED:
        raise SystemExit(f"expected {EXPECTED}, got {predictions}")

    print(f"smoke test passed: predictions={predictions}")


if __name__ == "__main__":
    main()
