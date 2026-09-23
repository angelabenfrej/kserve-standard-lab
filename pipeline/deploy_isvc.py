"""Create or update the pipeline's InferenceService, then wait for it to be Ready.

Used as step 2 of the KFP pipeline. Takes the storageUri produced by the training
step and points an InferenceService at it, reusing the `kserve-s3-sa` service
account from Step 3 so the storage-initializer can authenticate to MinIO.

Applies server-side-ish semantics by hand: create, and on 409 patch the existing
object instead. That keeps repeat pipeline runs idempotent -- a second run
updates the model in place rather than failing.
"""

import sys
import time

from kubernetes import client, config

GROUP = "serving.kserve.io"
VERSION = "v1beta1"
PLURAL = "inferenceservices"
NAMESPACE = "default"
NAME = "iris-pipeline"


def build_manifest(storage_uri: str) -> dict:
    return {
        "apiVersion": f"{GROUP}/{VERSION}",
        "kind": "InferenceService",
        "metadata": {"name": NAME, "namespace": NAMESPACE},
        "spec": {
            "predictor": {
                # Grants the storage-initializer the MinIO credentials from Step 3.
                "serviceAccountName": "kserve-s3-sa",
                "model": {
                    "modelFormat": {"name": "sklearn"},
                    "storageUri": storage_uri,
                },
            }
        },
    }


def wait_ready(api: client.CustomObjectsApi, timeout: int = 900) -> None:
    deadline = time.time() + timeout
    last = ""
    while time.time() < deadline:
        isvc = api.get_namespaced_custom_object(
            GROUP, VERSION, NAMESPACE, PLURAL, NAME
        )
        conditions = (isvc.get("status") or {}).get("conditions") or []
        ready = next((c for c in conditions if c.get("type") == "Ready"), None)
        if ready and ready.get("status") == "True":
            print(f"InferenceService/{NAME} is Ready")
            return
        state = f"{(ready or {}).get('status')} {(ready or {}).get('reason', '')}".strip()
        if state != last:
            print(f"waiting: Ready={state or 'unknown'}")
            last = state
        time.sleep(10)
    raise TimeoutError(f"InferenceService/{NAME} not Ready within {timeout}s")


def main() -> None:
    storage_uri = sys.argv[1].strip()
    if not storage_uri.startswith("s3://"):
        raise SystemExit(f"expected an s3:// storageUri, got: {storage_uri!r}")
    print(f"deploying storageUri: {storage_uri}")

    # In-cluster config: uses the pipeline-runner ServiceAccount token, which the
    # Role in manifests/kubeflow/pipeline-rbac.yaml authorises for this namespace.
    config.load_incluster_config()
    api = client.CustomObjectsApi()
    manifest = build_manifest(storage_uri)

    try:
        api.create_namespaced_custom_object(
            GROUP, VERSION, NAMESPACE, PLURAL, manifest
        )
        print(f"created InferenceService/{NAME}")
    except client.ApiException as exc:
        if exc.status != 409:
            raise
        api.patch_namespaced_custom_object(
            GROUP, VERSION, NAMESPACE, PLURAL, NAME, manifest
        )
        print(f"patched existing InferenceService/{NAME}")

    wait_ready(api)


if __name__ == "__main__":
    main()
