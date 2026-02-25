#!/usr/bin/env bash
# Wrapper to prepare the VM for AKS operations and then run k8s_deployment.sh.
# - Installs az/kubectl/helm if missing
# - Authenticates using the VM's Managed Identity (MI) with --allow-no-subscriptions
# - Optionally uses a specific MI via --mi_client_id
# - Optionally sets subscription via --subscription_id
# - Pulls AKS kubeconfig
# - Hands off to k8s_deployment.sh with all original flags

set -Eeuo pipefail

# Optional: set RUN_VERBOSE=1 to trace commands
if [[ "${RUN_VERBOSE:-0}" == "1" ]]; then
  set -x
fi

log()  { printf '[run.sh] %s\n' "$*"; }
fail() { printf '[run.sh] ERROR: %s\n' "$*" >&2; exit 1; }
require_cmd() { command -v "$1" >/dev/null 2>&1 || fail "Required command '$1' not found"; }

# -----------------------------
# Parse arguments (consume what we need, forward the rest)
# -----------------------------
RESOURCE_GROUP=""
AKS_NAME=""
SUBSCRIPTION_ID=""   # optional (recommended to pass from ARM)
MI_CLIENT_ID=""      # optional: for VMs with multiple UAMIs
PASSTHRU=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --resource_group)   RESOURCE_GROUP="${2:-}"; shift 2 ;;
    --aks_name)         AKS_NAME="${2:-}";       shift 2 ;;
    --subscription_id)  SUBSCRIPTION_ID="${2:-}"; shift 2 ;;
    --mi_client_id)     MI_CLIENT_ID="${2:-}";    shift 2 ;;
    *)                  PASSTHRU+=("$1");         shift   ;;
  esac
done

[[ -n "$RESOURCE_GROUP" ]] || fail "--resource_group is required"
[[ -n "$AKS_NAME"       ]] || fail "--aks_name is required"

# -----------------------------
# Prepare files
# -----------------------------
log "PWD: $(pwd)"
ls -la || true

[[ -f k8s_deployment.sh ]] || fail "k8s_deployment.sh not found in $(pwd)"
sed -i 's/\r$//' k8s_deployment.sh || true
chmod +x k8s_deployment.sh || true

# -----------------------------
# Ensure tools: az, kubectl, helm
# -----------------------------
if ! command -v az >/dev/null 2>&1; then
  log "Installing Azure CLI…"
  rpm --import https://packages.microsoft.com/keys/microsoft.asc
  cat >/etc/yum.repos.d/azure-cli.repo <<'EOF'
[azure-cli]
name=Azure CLI
baseurl=https://packages.microsoft.com/yumrepos/azure-cli
enabled=1
gpgcheck=1
gpgkey=https://packages.microsoft.com/keys/microsoft.asc
EOF
  if command -v dnf >/dev/null 2>&1; then
    dnf install -y azure-cli
  else
    yum install -y azure-cli
  fi
fi
require_cmd az

if ! command -v kubectl >/dev/null 2>&1; then
  log "Installing kubectl via az…"
  az aks install-cli
fi
require_cmd kubectl

if ! command -v helm >/dev/null 2>&1; then
  log "Installing Helm 3…"
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi
require_cmd helm
require_cmd curl

# -----------------------------
# Azure auth via Managed Identity
# -----------------------------
if [[ -n "$MI_CLIENT_ID" ]]; then
  log "az login --identity --username ${MI_CLIENT_ID} (allow-no-subscriptions)"
  az login --identity --username "$MI_CLIENT_ID" --allow-no-subscriptions --output none     || fail "az login --identity (with --username) failed"
else
  log "az login --identity (allow-no-subscriptions)"
  az login --identity --allow-no-subscriptions --output none     || fail "az login --identity failed"
fi

# Explicitly set the subscription if provided
if [[ -n "$SUBSCRIPTION_ID" ]]; then
  log "az account set --subscription ${SUBSCRIPTION_ID}"
  az account set --subscription "$SUBSCRIPTION_ID"     || fail "az account set --subscription ${SUBSCRIPTION_ID} failed"
fi

# -----------------------------
# Get AKS credentials
# -----------------------------
log "az aks get-credentials -g ${RESOURCE_GROUP} -n ${AKS_NAME} --overwrite-existing"
az aks get-credentials -g "$RESOURCE_GROUP" -n "$AKS_NAME" --overwrite-existing --output none   || fail "az aks get-credentials failed (check MI RBAC on subscription and AKS resource)"

# Non-fatal sanity checks
kubectl cluster-info || true
kubectl get nodes -o wide || true
helm version || true

# -----------------------------
# Hand off to your original script
# -----------------------------
log "Launching k8s_deployment.sh with original arguments…"
bash ./k8s_deployment.sh   --resource_group "$RESOURCE_GROUP"   --aks_name "$AKS_NAME"   "${PASSTHRU[@]}"
