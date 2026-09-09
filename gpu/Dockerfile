# syntax=docker/dockerfile:1.7-labs
#
# CUDA-enabled k3s node image for k3d.
#
# k3d runs each Kubernetes node as a Docker container, so the GPU has to be
# plumbed through three layers: host NVIDIA driver -> Docker `nvidia` runtime
# (via nvidia-container-toolkit on the host) -> containerd inside this node
# image -> pod. The stock `rancher/k3s` image carries no NVIDIA container
# runtime, so containerd inside it cannot hand /dev/nvidia* to a pod even when
# the node container itself was started with `--gpus all`.
#
# This image is the standard fix: take the CUDA base (which brings the
# userspace CUDA libraries), install nvidia-container-toolkit into it, then
# overlay the entire k3s filesystem on top. k3s detects `nvidia-container-
# runtime` on PATH at startup and registers it with containerd as a runtime
# handler named "nvidia", which the RuntimeClass in gpu/runtimeclass.yaml
# then targets.

ARG K3S_TAG="v1.35.5-k3s1"
ARG CUDA_TAG="13.0.1-base-ubuntu24.04"

FROM rancher/k3s:$K3S_TAG AS k3s

FROM nvidia/cuda:$CUDA_TAG

RUN apt-get update && apt-get install -y --no-install-recommends \
        curl ca-certificates gnupg2 \
    && rm -rf /var/lib/apt/lists/*

# NVIDIA container toolkit, from NVIDIA's distribution-agnostic stable repo.
RUN curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
        | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg \
    && curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
        | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
        > /etc/apt/sources.list.d/nvidia-container-toolkit.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends nvidia-container-toolkit \
    && rm -rf /var/lib/apt/lists/*

# Overlay the k3s filesystem. /bin is copied separately because the CUDA base
# image needs its own /bin contents preserved during the first copy.
COPY --from=k3s / / --exclude=/bin
COPY --from=k3s /bin /bin

VOLUME /var/lib/kubelet
VOLUME /var/lib/rancher/k3s
VOLUME /var/lib/cni
VOLUME /var/log

ENV PATH="$PATH:/bin/aux"

ENTRYPOINT ["/bin/k3s"]
CMD ["agent"]
