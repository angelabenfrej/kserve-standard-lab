CLUSTER_NAME := kserve-lab
KSERVE_VERSION := v0.19.0
CERT_MANAGER_VERSION := v1.21.0

.PHONY: up down reset \
	cluster cert-manager kserve-crd kserve-controller kserve-runtimes \
	minio postgres mlflow custom-runtime

up: cluster cert-manager kserve-crd kserve-controller kserve-runtimes \
	minio postgres mlflow custom-runtime
	@echo "Lab is up. See README.md for training + smoke-test steps."

down:
	k3d cluster delete $(CLUSTER_NAME)

reset: down up

# --- Step 1: cluster ---
cluster:
	@k3d cluster list $(CLUSTER_NAME) >/dev/null 2>&1 || \
		k3d cluster create --config k3d/cluster.yaml --wait
	k3d kubeconfig merge $(CLUSTER_NAME) --kubeconfig-merge-default --kubeconfig-switch-context

# --- Step 2: KServe ---
cert-manager:
	kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/$(CERT_MANAGER_VERSION)/cert-manager.yaml
	kubectl wait --for=condition=Available --timeout=120s deployment --all -n cert-manager

kserve-crd:
	helm upgrade --install kserve-crd oci://ghcr.io/kserve/charts/kserve-crd \
		--version $(KSERVE_VERSION) -n kserve --create-namespace

kserve-controller: kserve-crd
	helm upgrade --install kserve oci://ghcr.io/kserve/charts/kserve-resources \
		--version $(KSERVE_VERSION) -n kserve \
		--set kserve.controller.deploymentMode=Standard --wait

kserve-runtimes: kserve-controller
	helm upgrade --install kserve-runtimes oci://ghcr.io/kserve/charts/kserve-runtime-configs \
		--version $(KSERVE_VERSION) -n kserve \
		--set kserve.servingruntime.enabled=true --wait

# --- Step 3: MinIO ---
minio: cluster
	kubectl apply -f manifests/minio/namespace.yaml
	kubectl apply -f manifests/minio/secret.yaml -f manifests/minio/pvc.yaml \
		-f manifests/minio/deployment.yaml -f manifests/minio/service.yaml
	kubectl wait --for=condition=Available --timeout=120s deployment/minio -n kserve-lab
	kubectl apply -f manifests/minio/create-bucket-job.yaml
	kubectl wait --for=condition=complete --timeout=60s job/minio-create-bucket -n kserve-lab
	kubectl apply -f manifests/minio/s3-credentials.yaml

# --- Step 4: PostgreSQL + MLflow ---
postgres: minio
	kubectl apply -f manifests/postgres/secret.yaml -f manifests/postgres/pvc.yaml \
		-f manifests/postgres/deployment.yaml -f manifests/postgres/service.yaml
	kubectl wait --for=condition=Available --timeout=120s deployment/postgres -n kserve-lab

mlflow: postgres
	docker build -t mlflow-lab:latest mlflow/
	k3d image import mlflow-lab:latest -c $(CLUSTER_NAME)
	kubectl apply -f manifests/mlflow/deployment.yaml -f manifests/mlflow/service.yaml
	kubectl wait --for=condition=Available --timeout=120s deployment/mlflow -n kserve-lab

# --- Step 6: custom ServingRuntime ---
custom-runtime: kserve-runtimes
	docker build -t custom-sklearn-runtime:latest custom-runtime/
	k3d image import custom-sklearn-runtime:latest -c $(CLUSTER_NAME)
	kubectl apply -f manifests/custom-runtime/servingruntime.yaml
