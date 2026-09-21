"""KFP pipeline: train -> deploy -> smoke-test, for the iris model.

Compile with:

    python pipeline/iris_pipeline.py          # writes pipeline/iris_pipeline.yaml

Every step is a *container component*: an image plus a command. Values move
between steps as files -- KFP allocates a path, the producing step writes to it,
and the consuming step receives the contents as an argument. Here the value that
flows is the MLflow storageUri, which only exists once training has run.

The training step deliberately reuses train/train.py unmodified. Rather than
teaching the script to emit a machine-readable output, the pipeline parses the
line it already prints:

    model artifact_path (storageUri): s3://...

That keeps train.py the single canonical training script for both the local
walkthrough (Step 5) and in-cluster execution.
"""

from kfp import compiler, dsl, kubernetes

TRAINER_IMAGE = "iris-trainer:v1"
OPS_IMAGE = "iris-pipeline-ops:v1"

MLFLOW_URI = "http://mlflow.kserve-lab.svc.cluster.local:5000"
S3_ENDPOINT = "http://minio.kserve-lab.svc.cluster.local:9000"

# Run train.py, echo its output so it appears in the KFP log, then lift the
# storageUri out of it. Written against `sh` (no pipefail in dash), so the exit
# status is captured explicitly rather than relying on a pipeline's status.
TRAIN_SCRIPT = r"""
set -e
python /app/train.py > /tmp/train.log 2>&1 || { cat /tmp/train.log; exit 1; }
cat /tmp/train.log
mkdir -p "$(dirname "$1")"
sed -n 's/^model artifact_path (storageUri): //p' /tmp/train.log | tr -d '\n' > "$1"
test -s "$1" || { echo "no storageUri found in training output"; exit 1; }
echo "extracted storageUri: $(cat "$1")"
"""


@dsl.container_component
def train_iris(storage_uri: dsl.OutputPath(str)):
    """Train the model and emit the MLflow storageUri of the logged artifact."""
    return dsl.ContainerSpec(
        image=TRAINER_IMAGE,
        command=["sh", "-c", TRAIN_SCRIPT, "sh"],
        args=[storage_uri],
    )


@dsl.container_component
def deploy_isvc(storage_uri: str):
    """Point an InferenceService at the trained model and wait for Ready."""
    return dsl.ContainerSpec(
        image=OPS_IMAGE,
        command=["python", "/app/deploy_isvc.py"],
        args=[storage_uri],
    )


@dsl.container_component
def smoke_test():
    """Call the deployed predictor and assert it returns the expected classes."""
    return dsl.ContainerSpec(
        image=OPS_IMAGE,
        command=["python", "/app/smoke_test.py"],
        args=[],
    )


@dsl.pipeline(
    name="iris-train-deploy",
    description="Train iris, log to MLflow/MinIO, serve it with KServe, verify it answers.",
)
def iris_train_deploy():
    train = train_iris()
    train.set_env_variable("MLFLOW_TRACKING_URI", MLFLOW_URI)
    train.set_env_variable("MLFLOW_S3_ENDPOINT_URL", S3_ENDPOINT)
    # Credentials come from the Secret copied into the kubeflow namespace by
    # manifests/kubeflow/pipeline-prereqs.yaml.
    kubernetes.use_secret_as_env(
        train,
        secret_name="s3-credentials",
        secret_key_to_env={
            "AWS_ACCESS_KEY_ID": "AWS_ACCESS_KEY_ID",
            "AWS_SECRET_ACCESS_KEY": "AWS_SECRET_ACCESS_KEY",
        },
    )
    # Training is not idempotent -- each run should produce a new MLflow run
    # rather than replaying a cached result.
    train.set_caching_options(False)

    deploy = deploy_isvc(storage_uri=train.outputs["storage_uri"])
    deploy.set_caching_options(False)

    # No data dependency on deploy, so declare the ordering explicitly;
    # otherwise KFP would be free to run the smoke test first.
    test = smoke_test()
    test.after(deploy)
    test.set_caching_options(False)


if __name__ == "__main__":
    compiler.Compiler().compile(
        pipeline_func=iris_train_deploy,
        package_path="pipeline/iris_pipeline.yaml",
    )
    print("compiled -> pipeline/iris_pipeline.yaml")
