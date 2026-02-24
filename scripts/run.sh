#!/usr/bin/env bash
set -Eeuo pipefail

echo "[Wrapper] PWD: $(pwd)"
ls -la

# Normalize CRLF if any
if [[ -f k8s_deployment.sh ]]; then
  sed -i 's/\r$//' k8s_deployment.sh || true
  chmod +x k8s_deployment.sh || true
else
  echo "[Wrapper] k8s_deployment.sh not found" >&2
  exit 2
fi

# Exec with all arguments passed from ARM template
bash ./k8s_deployment.sh "$@"
