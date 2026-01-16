#!/bin/bash
set -e  # Exit on error

# Install prerequisites (idempotent)
if ! command -v ansible &> /dev/null; then
  brew install ansible  # For Mac; adapt for other OS
fi
if ! command -v kubectl &> /dev/null; then
  brew install kubectl
fi
if ! command -v kind &> /dev/null; then
  brew install kind  # For local Mac cluster
fi

# Provision local Mac cluster (temp management for IaC)
kind create cluster --name management --config clusters/mac-local.yaml || true  # Idempotent

# Provision Pi (via Ansible)
ansible-playbook -i pi-setup/inventory.ini pi-setup/playbook.yml

# Deploy Rancher to management cluster
./rancher/install-rancher.sh

# Set up GitOps (Fleet)
kubectl apply -f gitops/fleet.yaml  # Points to this repo

# Verify
kubectl get nodes --all-namespaces
echo "Bootstrap complete! Access Rancher at https://localhost:8443 (port-forward if needed)."