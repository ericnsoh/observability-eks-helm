#!/usr/bin/env bash
set -euo pipefail

# Bootstrap Argo CD on the current kube-context, then apply the root app-of-apps.
# Prerequisites: kubectl, helm, aws cli, cluster admin access.

for command in aws kubectl helm; do
  if ! command -v "${command}" >/dev/null 2>&1; then
    echo "Error: required command '${command}' was not found in PATH." >&2
    if [[ "${command}" == "helm" ]] && command -v brew >/dev/null 2>&1; then
      echo "Install it with: brew install helm" >&2
    fi
    exit 1
  fi
done

CLUSTER_NAME="${CLUSTER_NAME:-etechapp-eks-spj1rJJ9}"
AWS_REGION="${AWS_REGION:-us-east-2}"
REPO_URL="${REPO_URL:-https://github.com/ericnsoh/observability-eks-helm.git}"
REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT_APP_MANIFEST="${REPO_ROOT}/gitops/argocd/root-app.yaml"

if [[ ! -f "${ROOT_APP_MANIFEST}" ]]; then
  echo "Error: root Application manifest not found: ${ROOT_APP_MANIFEST}" >&2
  exit 1
fi

echo "==> Updating kubeconfig for ${CLUSTER_NAME} (${AWS_REGION})"
aws eks update-kubeconfig --name "${CLUSTER_NAME}" --region "${AWS_REGION}"

echo "==> Creating argocd namespace"
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -

echo "==> Installing Argo CD via Helm"
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update
helm upgrade --install argocd argo/argo-cd \
  --namespace argocd \
  --set server.service.type=LoadBalancer \
  --set configs.params."server\.insecure"=true \
  --wait

echo "==> Waiting for Argo CD server"
kubectl -n argocd rollout status deploy/argocd-server --timeout=300s

echo "==> Applying root Application (repo: ${REPO_URL})"
# Allow editing the repo URL without committing secrets into bootstrap
sed "s|^[[:space:]]*repoURL:.*|    repoURL: ${REPO_URL}|" \
  "${ROOT_APP_MANIFEST}" | kubectl apply -f -

echo
echo "Bootstrap complete."
echo "Argo CD initial admin password:"
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d
echo
echo
echo "Argo CD URL (wait for EXTERNAL-IP):"
kubectl -n argocd get svc argocd-server
echo "Grafana will be available after kube-prometheus-stack syncs (namespace monitoring)."
