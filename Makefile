CLUSTER_NAME := kserve-lab
KSERVE_VERSION := v0.19.0
CERT_MANAGER_VERSION := v1.21.0

# Step 8-10 pins. The SDK version is the one the committed pipeline/iris_pipeline.yaml
# was compiled with; keep it in step with the KFP backend's minor version.
K3S_CUDA_IMAGE := k3s-cuda:v1.35.5-k3s1
TRAINER_VERSION := v2.3.0
KFP_VERSION := 2.17.2
KFP_SDK_VERSION := 2.17.0
KFP_PORT ?= 8888
VENV := .venv

# Step 11. The placement demos run 4 replicas; with 4 fake GPUs per node the
# expected result is 2 + 2 (spread) and 4 + 0 (bin packing).
FAKE_GPUS_PER_NODE := 4

.PHONY: up down reset \
	cluster cert-manager kserve-crd kserve-controller kserve-runtimes \
	minio postgres mlflow custom-runtime \
	gpu-up gpu-image gpu-cluster gpu-plugin llm llm-down \
	kubeflow kubeflow-trainer kubeflow-pipelines trainer-image trainjob \
	venv pipeline-image pipeline-prereqs pipeline-compile pipeline-run \
	sched-up sched-demo sched-down

up: cluster cert-manager kserve-crd kserve-controller kserve-runtimes \
	minio postgres mlflow custom-runtime
	@echo "Lab is up. See docs/walkthrough.md for training + smoke-test steps."

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

# --- Step 8: GPU passthrough + LLM ---
# Requires nvidia-container-toolkit on the host (Step 8a); that part needs root
# and is deliberately not automated here.
#
# `up` is re-entered with $(MAKE) rather than listed as a prerequisite so the
# GPU cluster is guaranteed to exist first even under `make -j`; `up`'s own
# `cluster` target then sees an existing cluster and skips creation.
gpu-up: gpu-plugin
	$(MAKE) up

gpu-image:
	docker build --load -t $(K3S_CUDA_IMAGE) gpu/

# A bare existence check (as `cluster` uses) is not enough here: a CPU cluster
# of the same name would satisfy it, and the lab would come up without a GPU and
# without an error. Check the node image, and refuse rather than guess.
gpu-cluster: gpu-image
	@if k3d cluster list $(CLUSTER_NAME) >/dev/null 2>&1; then \
		img=$$(docker inspect k3d-$(CLUSTER_NAME)-server-0 --format '{{.Config.Image}}'); \
		case "$$img" in \
			*$(K3S_CUDA_IMAGE)*) echo "GPU cluster $(CLUSTER_NAME) already exists";; \
			*) echo "Cluster $(CLUSTER_NAME) exists but its nodes run $$img, not $(K3S_CUDA_IMAGE)."; \
			   echo "Run 'make down' first, then 'make gpu-up'."; exit 1;; \
		esac; \
	else \
		k3d cluster create --config k3d/cluster-gpu.yaml --wait; \
	fi
	k3d kubeconfig merge $(CLUSTER_NAME) --kubeconfig-merge-default --kubeconfig-switch-context

# Waits on the nodes' advertised capacity, not just the DaemonSet rollout: the
# plugin pods can be Running while the kubelet has yet to register the resource.
gpu-plugin: gpu-cluster
	kubectl apply -f gpu/runtimeclass.yaml -f gpu/device-plugin.yaml
	kubectl rollout status ds/nvidia-device-plugin-daemonset -n kube-system --timeout=180s
	kubectl wait node --all --for=jsonpath='{.status.capacity.nvidia\.com/gpu}'=1 --timeout=180s

# First start is ~10 min (a >10 GB image pull, ~3 GB of weights, vLLM init);
# later starts skip the image pull.
llm:
	kubectl apply -f manifests/llm/qwen-gpu.yaml
	kubectl wait --for=condition=Ready --timeout=1200s isvc/qwen-llm

# Frees the ~7 GB of VRAM vLLM holds for the pod's lifetime.
llm-down:
	kubectl delete -f manifests/llm/qwen-gpu.yaml --ignore-not-found

# --- Step 9: Kubeflow Trainer + Pipelines ---
kubeflow: kubeflow-trainer kubeflow-pipelines

# The runtimes overlay is validated by the trainer's own webhook, so the
# controller must be Available before it is applied.
kubeflow-trainer:
	kubectl apply --server-side -k "https://github.com/kubeflow/trainer.git/manifests/overlays/manager?ref=$(TRAINER_VERSION)"
	kubectl wait --for=condition=Available --timeout=300s deployment --all -n kubeflow-system
	kubectl apply --server-side -k "https://github.com/kubeflow/trainer.git/manifests/overlays/runtimes?ref=$(TRAINER_VERSION)"

kubeflow-pipelines:
	kubectl apply -k "github.com/kubeflow/pipelines/manifests/kustomize/cluster-scoped-resources?ref=$(KFP_VERSION)"
	kubectl wait --for condition=established --timeout=120s crd/applications.app.k8s.io
	kubectl apply -k "github.com/kubeflow/pipelines/manifests/kustomize/env/platform-agnostic?ref=$(KFP_VERSION)"
	kubectl wait --for=condition=Available --timeout=1200s deployment --all -n kubeflow

# Tagged :v1, never :latest -- TrainJob exposes no imagePullPolicy, and :latest
# defaults to Always, which cannot succeed for a side-loaded image.
trainer-image:
	docker build -t iris-trainer:v1 train/
	k3d image import iris-trainer:v1 -c $(CLUSTER_NAME)

# A TrainJob cannot be restarted in place, so each run replaces the last. Polls
# for either terminal condition: `kubectl wait` can only wait on one, and waiting
# on Complete alone would sit out the full timeout on a failed run.
trainjob: trainer-image
	kubectl delete -f manifests/kubeflow/trainjob-iris.yaml --ignore-not-found
	kubectl apply -f manifests/kubeflow/trainjob-iris.yaml
	@for i in $$(seq 1 60); do \
		st=$$(kubectl get trainjob iris-train -o jsonpath='{range .status.conditions[?(@.status=="True")]}{.type} {end}' 2>/dev/null); \
		case "$$st" in \
			*Complete*) echo "TrainJob complete"; break;; \
			*Failed*) echo "TrainJob failed:"; \
			          kubectl logs -l jobset.sigs.k8s.io/jobset-name=iris-train --tail=30; exit 1;; \
		esac; \
		[ $$i -eq 60 ] && { echo "TrainJob not finished after 600s"; exit 1; }; \
		sleep 10; \
	done
	@kubectl logs -l jobset.sigs.k8s.io/jobset-name=iris-train --tail=-1 \
		| grep -E '^(run_id|accuracy|model artifact_path)'

# --- Step 10: KFP pipeline ---
# The SDK is only needed on the laptop, to compile and submit; kept out of the
# system Python.
venv: $(VENV)/bin/python

$(VENV)/bin/python:
	python3 -m venv $(VENV)
	$(VENV)/bin/pip install -q kfp==$(KFP_SDK_VERSION) kfp-kubernetes==$(KFP_SDK_VERSION)

pipeline-image:
	docker build -t iris-pipeline-ops:v1 pipeline/
	k3d image import iris-pipeline-ops:v1 -c $(CLUSTER_NAME)

pipeline-prereqs:
	kubectl apply -f manifests/kubeflow/pipeline-prereqs.yaml

# A real file target: recompiles only when the pipeline definition changes.
pipeline-compile: pipeline/iris_pipeline.yaml

pipeline/iris_pipeline.yaml: pipeline/iris_pipeline.py | $(VENV)/bin/python
	$(VENV)/bin/python pipeline/iris_pipeline.py

# The KFP API has no ingress, so the port-forward is opened for the length of the
# run and torn down on exit (success or not). Waits on the API's healthz rather
# than a fixed sleep. Override the local port with `make pipeline-run KFP_PORT=...`
# if 8888 is taken (e.g. by Jupyter).
pipeline-run: pipeline-compile pipeline-image trainer-image pipeline-prereqs
	@kubectl port-forward -n kubeflow svc/ml-pipeline $(KFP_PORT):8888 >/dev/null 2>&1 & pf=$$!; \
	trap 'kill $$pf 2>/dev/null' EXIT; \
	for i in $$(seq 1 30); do \
		curl -sf http://localhost:$(KFP_PORT)/apis/v1beta1/healthz >/dev/null && break; \
		sleep 1; \
	done; \
	KFP_HOST=http://localhost:$(KFP_PORT) $(VENV)/bin/python pipeline/run_pipeline.py

# --- Step 11: scheduling -- bin packing vs spreading ---
# Advertises a made-up extended resource on every node and runs a second
# kube-scheduler with a spread profile and a bin-packing profile. Nothing else in
# the cluster changes: all other pods stay on the default scheduler, and the real
# GPU is never touched.
sched-up:
	@for n in $$(kubectl get nodes -o name); do \
		kubectl patch $$n --subresource=status --type=json \
			-p '[{"op":"add","path":"/status/capacity/example.com~1fake-gpu","value":"$(FAKE_GPUS_PER_NODE)"}]'; \
	done
	kubectl apply -f manifests/scheduling/scheduler.yaml
	kubectl rollout status deploy/lab-scheduler -n kube-system --timeout=180s

# Runs each profile in turn and prints pods per node. Each run waits for its
# pods -- not just the Deployment -- to be gone before the next starts: deleting
# a Deployment returns while its pods are still terminating and holding their
# fake GPUs, which is enough to turn a 4 + 0 bin-packing result into 2 + 2.
sched-demo: sched-up
	@for mode in spread binpack; do \
		kubectl apply -f manifests/scheduling/placement-$$mode.yaml >/dev/null; \
		kubectl rollout status deploy/placement-$$mode --timeout=120s >/dev/null; \
		printf '%-18s ' "$$mode-scheduler:"; \
		kubectl get pods -l app=placement-$$mode \
			-o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' \
			| sort | uniq -c | awk '{printf "%s=%s  ", $$2, $$1} END {print ""}'; \
		kubectl delete -f manifests/scheduling/placement-$$mode.yaml >/dev/null; \
		kubectl wait --for=delete pod -l app=placement-$$mode --timeout=60s >/dev/null 2>&1; \
	done

# Removes the demo, the scheduler, and the fake resource from every node.
#
# `capacity` and `allocatable` are removed separately, and both are needed. When
# the resource is added, the kubelet copies capacity into allocatable, but it does
# not remove that copy when capacity goes: clearing capacity alone leaves the node
# still offering 4 fake GPUs to the scheduler, which reads allocatable. Two
# patches rather than one because a JSON patch fails whole if any path is absent.
sched-down:
	kubectl delete -f manifests/scheduling/placement-spread.yaml \
		-f manifests/scheduling/placement-binpack.yaml --ignore-not-found
	kubectl delete -f manifests/scheduling/scheduler.yaml --ignore-not-found
	@for n in $$(kubectl get nodes -o name); do \
		for field in capacity allocatable; do \
			kubectl patch $$n --subresource=status --type=json \
				-p "[{\"op\":\"remove\",\"path\":\"/status/$$field/example.com~1fake-gpu\"}]" >/dev/null 2>&1 || true; \
		done; \
	done
	@kubectl get nodes -o custom-columns='NODE:.metadata.name,FAKE-GPU-ALLOCATABLE:.status.allocatable.example\.com/fake-gpu'
