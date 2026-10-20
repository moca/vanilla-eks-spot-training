# Training image for the nanochat recovery demo.
#
# The tested fork is moca/nanochat, branch iteration/observability, pinned by the
# Makefile to an exact commit. It is a sibling checkout by default (configurable
# with NANOCHAT_DIR), so it is outside the build context. It is supplied as a
# BuildKit named context:
#
#   docker build -f docker/Dockerfile \
#     --build-context nanochat=../nanochat \
#     -t <tag> .
#
# torch cu128 wheels bundle the CUDA runtime, so a slim Python base suffices --
# the host supplies the NVIDIA driver (Bottlerocket GPU AMI) and the container
# runtime. No nvidia/cuda base image needed.
FROM python:3.11-slim

ENV PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    OMP_NUM_THREADS=1

RUN apt-get update && apt-get install -y --no-install-recommends \
      git curl unzip ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# awscli v2 for checkpoint sync. The pod reaches S3 via EKS Pod Identity.
RUN ARCH="$(uname -m)" \
    && curl -sL "https://awscli.amazonaws.com/awscli-exe-linux-${ARCH}.zip" -o /tmp/awscli.zip \
    && unzip -q /tmp/awscli.zip -d /tmp \
    && /tmp/aws/install \
    && rm -rf /tmp/awscli.zip /tmp/aws

WORKDIR /opt/nanochat

# torch first and pinned, from the CUDA 12.8 index nanochat's pyproject targets.
# Its own layer so source changes do not re-download ~3GB.
RUN pip install --index-url https://download.pytorch.org/whl/cu128 torch==2.9.1

# Mirrors nanochat's pyproject dependencies (minus torch, installed above).
RUN pip install \
      "filelock>=3.19.0" \
      "kernels>=0.11.7" \
      "numpy>=1.26.0" \
      "psutil>=7.1.0" \
      "pyarrow>=21.0.0" \
      "rustbpe>=0.1.0" \
      "tiktoken>=0.11.0" \
      "wandb>=0.21.3"

# gcc/g++ for Triton. torch.compile builds a CUDA utils module AT RUNTIME and
# shells out to a C compiler; without one the first forward pass dies with
# "InductorError: Failed to find C compiler". python:3.11-slim ships none.
#
# Deliberately placed AFTER the pip layers rather than merged into the apt-get
# block near the top: putting it there invalidates the ~4 GB torch download layer
# and turns a 1-minute rebuild into a full re-pull and re-push.
RUN apt-get update && apt-get install -y --no-install-recommends \
      gcc g++ \
    && rm -rf /var/lib/apt/lists/*

COPY --from=nanochat . /opt/nanochat/
COPY docker/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
