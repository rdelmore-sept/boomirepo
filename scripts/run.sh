#!/usr/bin/env bash
set -Eeuo pipefail

# -----------------------------
# 1) Parse required arguments
# -----------------------------
RESOURCE_GROUP=""
AKS_NAME=""

# Keep everything else to forward into k8s_deployment.sh
PASSTHRU=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --resource_group)
      RESOURCE_GROUP="$2"; shift 2 ;;
    --aks_name)
      AKS_NAME="$2"; shift 2 ;;
    *)
      PASSTHRU+=("$1"); shift ;;
  esac
done

if [[ -z "${RESOURCE_GROUP}" || -z "${AKS_NAME}" ]]; then
  echo "[run.sh] ERROR: --resource_group and --aks_name are required." >&2
  exit 64
fi

# -----------------------------
# 2) Show context + prepare file
# -----------------------------
echo "[run.sh] PWD: $(pwd)"
ls -la

if [[ ! -f k8s_deployment.sh ]]; then
  echo "[run.sh] ERROR: k8s_deployment.sh not found in $(pwd)" >&2
  exit 2
fi

# Normalize possible CRLF and ensure executable
sed -i 's/\r$//' k8s_deployment.sh || true
chmod +x k8s_deployment.sh || true

# -----------------------------
# 3) Ensure tools are present
# -----------------------------
if ! command -v az >/dev/null 2>&1; then
  echo "[run.sh] Installing Azure CLI..."
  # RHEL 8-compatible install
  rpm --import https://packages.microsoft.com/keys/microsoft.asc
  cat >/etc/yum.repos.d/azure-cli.repo <<'EOF'
[azure-cli]
name=Azure CLI
baseurl=https://packages.microsoft.com/yumrepos/azure-cli
enabled=1
gpgcheck=1
gpgkey=https://packages.microsoft.com/keys/microsoft.asc
EOF
  dnf install -y azure-cli
fi

if ! command -v kubectl >/dev/null 2>&1; then
  echo "[run.sh] Installing kubectl via az..."
  az aks install-cli
fi

if ! command -v helm >/dev/null 2>&1; then
  echo "[run.sh] Installing Helm..."
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi

# -----------------------------
# 4) Azure auth (Managed Identity)
# -----------------------------
echo "[run.sh] az login --identity"
az login --identity --output none

# If you need to pin the subscription explicitly, uncomment:
# az account set --subscription "<SUBSCRIPTION_ID>"

# -----------------------------
# 5) Get AKS credentials
# -----------------------------
echo "[run.sh] az aks get-credentials -g ${RESOURCE_GROUP} -n ${AKS_NAME}"
az aks get-credentials -g "${RESOURCE_GROUP}" -n "${AKS_NAME}" --overwrite-existing --output none

# Quick sanity check (won’t fail the run; logs are helpful for triage)
kubectl cluster-info || true
kubectl get nodes -o wide || true
helm version || true

# -----------------------------
# 6) Invoke your original script
# -----------------------------
echo "[run.sh] Launching k8s_deployment.sh with original arguments…"
# Re-inject the required flags (resource_group, aks_name) first, then pass everything else.
bash ./k8s_deployment.sh \
  --resource_group "${RESOURCE_GROUP}" \
  --aks_name "${AKS_NAME}" \
  "${PASSTHRU[@]}"
