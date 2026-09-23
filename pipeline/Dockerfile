# Image for the KFP pipeline's deploy and smoke-test steps (Step 10).
#
# Only the Kubernetes client is needed beyond the standard library: the smoke
# test uses urllib rather than requests, so there is nothing else to install.
#
# Tagged :v1 rather than :latest for the same reason as train/Dockerfile --
# Kubernetes defaults :latest to imagePullPolicy Always, which cannot succeed
# for an image side-loaded into k3d with no registry behind it.
FROM python:3.12-slim

RUN pip install --no-cache-dir kubernetes

WORKDIR /app
COPY deploy_isvc.py smoke_test.py ./
