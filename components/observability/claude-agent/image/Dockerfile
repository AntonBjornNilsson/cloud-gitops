# Runtime image for the claude-agent service: Node with the Claude Agent SDK (which ships the Claude
# Code binary), kubectl, flux and git. The service code is not baked in; it comes from the
# claude-agent-app ConfigMap (../app) mounted at /app/src and runs directly via Node's type stripping.
# Built and pushed by .github/workflows/claude-agent-image.yaml, which passes the latest versions.
FROM node:26-bookworm-slim

ARG AGENT_SDK_VERSION=0.3.296
ARG KUBECTL_VERSION=v1.37.1
ARG FLUX_VERSION=2.9.6
ARG TARGETARCH=amd64

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl git jq \
 && rm -rf /var/lib/apt/lists/*

RUN curl -fsSLo /usr/local/bin/kubectl "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${TARGETARCH}/kubectl" \
 && chmod +x /usr/local/bin/kubectl \
 && curl -fsSL "https://github.com/fluxcd/flux2/releases/download/v${FLUX_VERSION}/flux_${FLUX_VERSION}_linux_${TARGETARCH}.tar.gz" \
    | tar -xz -C /usr/local/bin flux

WORKDIR /app
COPY package.json ./
RUN npm install --omit=dev "@anthropic-ai/claude-agent-sdk@${AGENT_SDK_VERSION}" \
 && npm cache clean --force

ENV DISABLE_AUTOUPDATER=1
USER node
CMD ["node", "/app/src/server.ts"]
