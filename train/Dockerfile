# Training image for the in-cluster TrainJob (Step 9).
#
# Bakes in the same train.py used for the local walkthrough in Step 5. The
# script calls load_dotenv(), which is a no-op when no .env file is present, so
# it reads its configuration from the environment either way: a local .env when
# run by hand, or the TrainJob's env block when run as a pod.
#
# Build with an explicit non-`latest` tag. TrainJob.spec.trainer exposes no
# imagePullPolicy field, and Kubernetes defaults `:latest` to Always, which
# fails for an image side-loaded into k3d with no registry behind it. Any other
# tag defaults to IfNotPresent.
FROM python:3.12-slim

RUN pip install --no-cache-dir \
        mlflow \
        scikit-learn \
        boto3 \
        python-dotenv

WORKDIR /app
COPY train.py .

ENTRYPOINT ["python", "train.py"]
