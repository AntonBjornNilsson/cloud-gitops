# Tooling image for the claude-agent CronJobs. Scripts are not baked in; they come from the
# ConfigMap generated in ../kustomization.yaml so they can change without a rebuild.
# Built and pushed by .github/workflows/claude-agent-image.yaml, which passes the latest versions.
FROM node:22-bookworm-slim

ARG CLAUDE_CODE_VERSION=2.1.289
ARG KUBECTL_VERSION=v1.37.1
ARG FLUX_VERSION=2.9.6
ARG TARGETARCH=amd64

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl git jq openssl \
 && rm -rf /var/lib/apt/lists/*

RUN curl -fsSLo /usr/local/bin/kubectl "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${TARGETARCH}/kubectl" \
 && chmod +x /usr/local/bin/kubectl \
 && curl -fsSL "https://github.com/fluxcd/flux2/releases/download/v${FLUX_VERSION}/flux_${FLUX_VERSION}_linux_${TARGETARCH}.tar.gz" \
    | tar -xz -C /usr/local/bin flux

RUN npm install -g "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}" \
 && npm cache clean --force

ENV DISABLE_AUTOUPDATER=1
USER node
WORKDIR /home/node
