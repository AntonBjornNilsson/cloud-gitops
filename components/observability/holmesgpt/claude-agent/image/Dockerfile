# Tooling image for the claude-agent CronJobs. Scripts are not baked in; they come from the
# ConfigMap generated in ../kustomization.yaml so they can change without a rebuild.
# Built and pushed by .github/workflows/claude-agent-image.yaml, which passes the latest versions.
FROM node:26-bookworm-slim

ARG CLAUDE_CODE_VERSION=2.1.289
ARG KUBECTL_VERSION=v1.37.1
ARG FLUX_VERSION=2.9.6
# Version lookups for the updates run (scripts/check-updates.sh)
ARG HELM_VERSION=4.3.0
ARG CRANE_VERSION=0.22.1
ARG YQ_VERSION=4.54.1
ARG TARGETARCH=amd64

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl git jq openssl \
 && rm -rf /var/lib/apt/lists/*

RUN curl -fsSLo /usr/local/bin/kubectl "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${TARGETARCH}/kubectl" \
 && chmod +x /usr/local/bin/kubectl \
 && curl -fsSL "https://github.com/fluxcd/flux2/releases/download/v${FLUX_VERSION}/flux_${FLUX_VERSION}_linux_${TARGETARCH}.tar.gz" \
    | tar -xz -C /usr/local/bin flux \
 && curl -fsSL "https://get.helm.sh/helm-v${HELM_VERSION}-linux-${TARGETARCH}.tar.gz" \
    | tar -xz -C /usr/local/bin --strip-components=1 "linux-${TARGETARCH}/helm" \
 && curl -fsSL "https://github.com/google/go-containerregistry/releases/download/v${CRANE_VERSION}/go-containerregistry_Linux_$( [ "$TARGETARCH" = amd64 ] && echo x86_64 || echo arm64 ).tar.gz" \
    | tar -xz -C /usr/local/bin crane \
 && curl -fsSLo /usr/local/bin/yq "https://github.com/mikefarah/yq/releases/download/v${YQ_VERSION}/yq_linux_${TARGETARCH}" \
 && chmod +x /usr/local/bin/yq

RUN npm install -g "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}" \
 && npm cache clean --force

ENV DISABLE_AUTOUPDATER=1
USER node
WORKDIR /home/node
