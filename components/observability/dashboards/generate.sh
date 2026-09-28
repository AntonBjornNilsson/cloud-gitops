#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="${SCRIPT_DIR}/src"
GEN_DIR="${SCRIPT_DIR}/generated"

mkdir -p "${GEN_DIR}"

echo "Generating GrafanaDashboard CRs from Jsonnet..."

for file in "${SRC_DIR}"/*.jsonnet; do
  [ -f "${file}" ] || continue
  base_name="$(basename "${file}" .jsonnet)"
  target_file="${GEN_DIR}/${base_name//_/-}.yaml"
  dashboard_name="${base_name//_/-}"

  echo "  -> Compiling ${base_name}.jsonnet to ${target_file}"
  
  compiled_json="$(jsonnet -J "${SCRIPT_DIR}/vendor" "${file}")"

  cat <<EOF > "${target_file}"
apiVersion: grafana.integreatly.org/v1beta1
kind: GrafanaDashboard
metadata:
  name: ${dashboard_name}
  namespace: grafana
  labels:
    app.kubernetes.io/managed-by: grafonnet
spec:
  allowCrossNamespaceImport: true
  instanceSelector:
    matchLabels:
      dashboards: "grafana"
  json: |
$(echo "${compiled_json}" | sed 's/^/    /')
EOF
done

echo "Successfully generated all dashboards!"
