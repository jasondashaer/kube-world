# kube-world Operational Runbook

Day-2 operational procedures for the kube-world infrastructure. For architecture details, see [architecture.md](architecture.md). For AI assistant context, see [../CLAUDE.md](../CLAUDE.md).

## Table of Contents

- [Daily Operations](#daily-operations)
- [Bootstrap and Rebuild](#bootstrap-and-rebuild)
- [Deploying New Apps](#deploying-new-apps)
- [Adding Edge Clusters](#adding-edge-clusters)
- [Certificate Management](#certificate-management)
- [Identity and SSO](#identity-and-sso)
- [GitOps Operations](#gitops-operations)
- [Troubleshooting](#troubleshooting)
- [Known Issues and Workarounds](#known-issues-and-workarounds)

---

## Daily Operations

### Quick Health Check

```bash
# Source bootstrap env for credentials
source .env.bootstrap

# Central cluster
KUBECONFIG=~/.kube/pi-config kubectl get nodes
KUBECONFIG=~/.kube/pi-config flux get kustomizations
KUBECONFIG=~/.kube/pi-config flux get helmreleases -A

# Edge cluster
KUBECONFIG=~/.kube/pi-edge-1-config kubectl get nodes
KUBECONFIG=~/.kube/pi-edge-1-config kubectl get pods -A | grep -v Running

# Karmada
KUBECONFIG=~/.karmada/karmada-apiserver.config kubectl get clusters

# TLS certs
KUBECONFIG=~/.kube/pi-config kubectl get certificate -A
KUBECONFIG=~/.kube/pi-edge-1-config kubectl get certificate -A

# Quick URL check
for url in rancher.kubew.dev auth.kubew.dev gitlab.kubew.dev ntfy.kubew.dev ha.edge1.kubew.dev companion.edge1.kubew.dev; do
  code=$(curl -sk -o /dev/null -w "%{http_code}" "https://${url}")
  printf "  %-35s %s\n" "https://${url}" "$code"
done
```

### Accessing Services

| Service | URL | Login |
|---------|-----|-------|
| Rancher | https://rancher.kubew.dev | SSO via Zitadel (jharris) or local admin |
| Zitadel | https://auth.kubew.dev | jharris / `${RANCHER_BOOTSTRAP_PASSWORD}!Kw1` |
| GitLab | https://gitlab.kubew.dev | root / `${RANCHER_BOOTSTRAP_PASSWORD}` |
| ntfy | https://ntfy.kubew.dev | Subscribe to topic `kube-world` |
| Home Assistant | https://ha.edge1.kubew.dev | SSO (web) or admin + `${RANCHER_BOOTSTRAP_PASSWORD}` (app) |
| Node-RED | https://nodered.edge1.kubew.dev | None by default |
| ESPHome | https://esphome.edge1.kubew.dev | None by default |
| VS Code Server | https://code.edge1.kubew.dev | None by default |
| InfluxDB | https://influxdb.edge1.kubew.dev | admin / `kube-world-influx` |
| Zigbee2MQTT | https://zigbee.edge1.kubew.dev | None by default (needs hardware) |

### Watching GitOps Events

Subscribe to ntfy topic `kube-world` on mobile for real-time Flux events. Or via CLI:

```bash
curl -sk -H "Accept: text/event-stream" https://ntfy.kubew.dev/kube-world/sse
```

---

## Bootstrap and Rebuild

### Prerequisites

- Mac with `.env.bootstrap` sourced (has `CLOUDFLARE_API_TOKEN`, `TAILSCALE_API_TOKEN`, `RANCHER_BOOTSTRAP_PASSWORD`, etc.)
- SSH access to all Pis as `admin` user
- Tailscale running on Mac (for reaching Pis after they join the mesh)

### Full Fresh Bootstrap

```bash
source .env.bootstrap
./bootstrap.sh --platform pi --stack karmada --verbose
```

Takes ~15-25 minutes. Fully automated — no manual steps required. Includes:
1. Ansible provisioning of all Pis
2. K3s + Tailscale installation
3. Traefik + Gateway on central
4. Karmada control plane + edge cluster join
5. Rancher + cert-manager + LE wildcard cert
6. Zitadel identity + OIDC seeding
7. Rancher OIDC auto-enabled (no browser step)
8. GitLab native install + repo push
9. Flux install + all Kustomizations
10. ExternalDNS on central
11. Edge cluster Flux secrets
12. Flux reconciles all edge infrastructure
13. Apps deployed via Karmada propagation
14. HA init container seeds onboarding + local credential

### Wipe and Rebuild

```bash
# Full wipe both Pis
ssh admin@10.5.5.136 "sudo /usr/local/bin/k3s-uninstall.sh"
ssh admin@10.5.5.249 "sudo /usr/local/bin/k3s-uninstall.sh"
rm -rf ~/.karmada ~/.kube/pi-config ~/.kube/pi-edge-1-config
ssh admin@10.5.5.136 "sudo rm -rf /var/lib/rancher /etc/rancher /var/lib/karmada-etcd"
ssh admin@10.5.5.249 "sudo rm -rf /var/lib/rancher /etc/rancher"

# Verify clean
ssh admin@10.5.5.136 "which k3s || echo CLEAN"
ssh admin@10.5.5.249 "which k3s || echo CLEAN"

# Bootstrap from scratch
source .env.bootstrap && ./bootstrap.sh --platform pi --stack karmada --verbose
```

**WARNING: Let's Encrypt rate limit is 5 certs per exact identifier set per 7 days.** Each rebuild issues a new cert. If you need to rebuild more than 4-5 times in a week, use LE staging temporarily by patching the ClusterIssuer.

---

## Deploying New Apps

### App on Edge Cluster (via Karmada)

1. **Create app manifests:**
   ```
   apps/<app-name>/
   ├── deployment.yaml      # Deployment + Service + PVC
   └── kustomization.yaml   # References deployment.yaml
   ```

2. **Create Karmada PropagationPolicy:**
   ```yaml
   # karmada/propagation-policies/<app-name>.yaml
   apiVersion: policy.karmada.io/v1alpha1
   kind: PropagationPolicy
   metadata:
     name: <app-name>
     namespace: <namespace>
   spec:
     resourceSelectors:
       - apiVersion: apps/v1
         kind: Deployment
         name: <app-name>
       # + Services, PVCs, ConfigMaps, Secrets
     placement:
       clusterAffinity:
         labelSelector:
           matchExpressions:
             - key: workload-type
               operator: In
               values: [iot]
   ```

3. **Create Flux Kustomization in `flux/kustomizations/apps.yaml`:**
   ```yaml
   apiVersion: kustomize.toolkit.fluxcd.io/v1
   kind: Kustomization
   metadata:
     name: apps-<app-name>
     namespace: flux-system
   spec:
     interval: 5m
     path: ./apps/<app-name>
     prune: true
     sourceRef:
       kind: GitRepository
       name: kube-world
     kubeConfig:
       secretRef:
         name: karmada-kubeconfig
         key: value
     dependsOn:
       - name: apps-base
       - name: karmada-propagation-policies
   ```

4. **Add HTTPRoute in `infrastructure/clusters/edge1/raw/httproutes/`:**
   ```yaml
   apiVersion: gateway.networking.k8s.io/v1
   kind: HTTPRoute
   metadata:
     name: <app-name>
     namespace: <namespace>
   spec:
     parentRefs:
       - name: kube-world-gateway
         namespace: kube-system
     hostnames:
       - "<app-name>.edge1.kubew.dev"
     rules:
       - matches:
           - path:
               type: PathPrefix
               value: /
         backendRefs:
           - name: <app-name>
             port: <port>
   ```

5. **Add HTTPRoute to `infrastructure/clusters/edge1/raw/httproutes/kustomization.yaml`**

6. **Push to GitLab** — Flux syncs automatically:
   ```bash
   git push origin main
   git push http://root:${RANCHER_BOOTSTRAP_PASSWORD}@10.5.5.136:8180/root/kube-world.git HEAD:main
   ```

### App on Central Cluster

Same pattern but:
- Skip Karmada PropagationPolicy
- Flux Kustomization has no `kubeConfig.secretRef` (targets local cluster)
- HTTPRoute uses `*.kubew.dev` hostname, added to `infrastructure/traefik/` or applied by bootstrap

---

## Adding Edge Clusters

1. **Add to `pi-setup/inventory.ini`:**
   ```ini
   [edge_clusters]
   pi-edge-2 ansible_host=10.5.5.x node_name=pi-edge-2
   ```

2. **Add to `config.yaml` karmada.clusters:**
   ```yaml
   - name: "pi-edge-2"
     type: edge
     subdomain: "edge2"
     labels:
       topology.kubernetes.io/zone: edge
       hardware: raspberry-pi
       workload-type: iot
   ```

3. **Create `infrastructure/clusters/edge2/`** (copy from edge1, replace `edge1` → `edge2`)

4. **Create `flux/kustomizations/infrastructure-edge2.yaml`**

5. **Run bootstrap** — will auto-create wildcard CNAME `*.edge2.kubew.dev` via Cloudflare API

Alternatively, once Terraform is wired up: `terraform apply` handles the Cloudflare piece.

---

## Certificate Management

### Check Cert Status

```bash
# Central cluster cert (*.kubew.dev)
KUBECONFIG=~/.kube/pi-config kubectl get certificate -A
KUBECONFIG=~/.kube/pi-config kubectl -n kube-system get secret kube-world-tls \
    -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -subject -issuer -dates

# Edge cluster cert (*.edge1.kubew.dev)
KUBECONFIG=~/.kube/pi-edge-1-config kubectl get certificate -A
```

### Force Cert Renewal

```bash
# Delete the cert — cert-manager recreates and re-issues
KUBECONFIG=~/.kube/pi-config kubectl -n kube-system delete certificate kubew-dev-wildcard

# Or annotate to trigger renewal
KUBECONFIG=~/.kube/pi-config kubectl -n kube-system annotate certificate kubew-dev-wildcard \
    cert-manager.io/issue-temporary-certificate=true --overwrite
```

### Stuck Challenge Recovery

If a DNS-01 challenge gets stuck (pending indefinitely):

```bash
# 1. Clean Cloudflare _acme-challenge TXT records
ZONE_ID=$(curl -s "https://api.cloudflare.com/client/v4/zones?name=kubew.dev" \
    -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" | jq -r '.result[0].id')
STALE=$(curl -s -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
    "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records?type=TXT&name=_acme-challenge.kubew.dev" \
    | jq -r '.result[].id')
for id in $STALE; do
    curl -s -X DELETE -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
        "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records/${id}"
done

# 2. Delete stuck K8s resources
KUBECONFIG=~/.kube/pi-config kubectl delete challenges -n kube-system --all
KUBECONFIG=~/.kube/pi-config kubectl delete orders -n kube-system --all
KUBECONFIG=~/.kube/pi-config kubectl delete certificate -n kube-system kubew-dev-wildcard

# 3. Recreate cert (Flux will restore it on next reconcile)
KUBECONFIG=~/.kube/pi-config flux reconcile kustomization infra-edge1-raw
```

### Let's Encrypt Rate Limits

- **5 certs per exact identifier set per 168h** (rolling window)
- **50 certs per registered domain per 168h**
- If hit, switch to LE staging temporarily:
  ```bash
  KUBECONFIG=~/.kube/pi-config kubectl -n kube-system patch certificate kubew-dev-wildcard \
      --type merge -p '{"spec":{"issuerRef":{"name":"letsencrypt-staging"}}}'
  ```

---

## Identity and SSO

### Rancher OIDC

Fully automated by bootstrap — no manual step. If it breaks:

```bash
# Check status
KUBECONFIG=~/.kube/pi-config kubectl get authconfig genericoidc \
    -o jsonpath='{.enabled}'  # Should be "true"

# Re-enable if disabled
KUBECONFIG=~/.kube/pi-config kubectl patch authconfig genericoidc --type=merge -p '{
  "enabled": true,
  "rancherUrl": "https://rancher.kubew.dev/dashboard/auth/verify"
}'

# Re-map groups
./scripts/finalize-oidc.sh
```

### Home Assistant SSO

Web uses OIDC (SSO button on login page). Mobile app uses local credentials (`admin` + `${RANCHER_BOOTSTRAP_PASSWORD}`).

The OIDC client ID and secret are stored in the `ha-oidc-config` secret on the edge cluster, created by bootstrap from the Zitadel seed state.

### Manually Create Additional Users in Zitadel

1. Log into Zitadel at `https://auth.kubew.dev` as `jharris`
2. Navigate to Users → Add User
3. Assign project role (admin or user)
4. Users with `admin` role get Rancher Admin automatically via the group mapping

---

## GitOps Operations

### Force Flux Reconciliation

```bash
# Fetch latest from Git
KUBECONFIG=~/.kube/pi-config flux reconcile source git kube-world

# Reconcile specific Kustomization
KUBECONFIG=~/.kube/pi-config flux reconcile kustomization apps-home-assistant

# Reconcile all
KUBECONFIG=~/.kube/pi-config flux get kustomizations -A --no-header | awk '{print $1}' | \
    xargs -I {} flux reconcile kustomization {} -n flux-system
```

### Push Changes

```bash
git add <files>
git commit -m "message"
git push origin main  # GitHub

# ALSO push to GitLab — Flux source
git push http://root:${RANCHER_BOOTSTRAP_PASSWORD}@10.5.5.136:8180/root/kube-world.git HEAD:main
```

### Suspend/Resume Flux

```bash
# Suspend (stop reconciling)
KUBECONFIG=~/.kube/pi-config flux suspend kustomization apps-home-assistant

# Resume
KUBECONFIG=~/.kube/pi-config flux resume kustomization apps-home-assistant
```

---

## Troubleshooting

### Bootstrap Silently Exits Mid-run

Usually caused by `set -e` triggering on an unexpected failure. Check:

1. **Namespace doesn't exist on Karmada API** — Flux hasn't synced apps-base yet. Functions that need Karmada namespaces (e.g., `patch_ha_oidc_client_id`) should create them explicitly.

2. **Rancher webhook not ready** — The bootstrap now waits for it, but if you see "no endpoints available for service rancher-webhook", just re-run bootstrap.

3. **Pipe with `set -o pipefail`** — If any command in a pipe fails, the whole pipeline fails. Use `|| true` or explicit `if` blocks.

### Flux Kustomization Stuck "Dependency not ready"

Circular dependency or a dependency that needs creation first:

```bash
# Check what's blocking
KUBECONFIG=~/.kube/pi-config flux get kustomizations -A

# Force reconcile in dependency order
for k in apps-base karmada-propagation-policies karmada-override-policies apps-home-assistant; do
  KUBECONFIG=~/.kube/pi-config flux reconcile kustomization $k
done
```

### HA Mobile App Login Fails

The HA mobile app doesn't support OIDC. Use the local `admin` account with `${RANCHER_BOOTSTRAP_PASSWORD}` as the password. If the app is IP-banned:

```bash
KUBECONFIG=~/.kube/pi-edge-1-config kubectl -n home-assistant exec deploy/home-assistant -- \
    rm -f /config/.storage/ip_bans.yaml
KUBECONFIG=~/.kube/pi-edge-1-config kubectl -n home-assistant delete pod -l app.kubernetes.io/name=home-assistant
```

### Karmada Work Objects Not Applying

Check the resource binding and work objects:

```bash
# Scheduling decisions
KUBECONFIG=~/.karmada/karmada-apiserver.config kubectl get rb -A

# Work objects on each member cluster
KUBECONFIG=~/.karmada/karmada-apiserver.config kubectl get work -n karmada-es-pi-edge-1

# Karmada controller errors
KUBECONFIG=~/.kube/pi-config kubectl -n karmada-system logs deploy/karmada-controller-manager --tail=50 | grep -i error
```

### Cloudflare DNS Not Resolving

Tailscale MagicDNS backs the CNAMEs. If DNS is broken:

```bash
# Verify CNAME exists in Cloudflare
dig +short rancher.kubew.dev
# Expected: pi-central.<tailnet>.ts.net.

# Verify Tailscale is running on Mac + Pi
tailscale status
```

---

## Known Issues and Workarounds

### 1. cert-manager Cloudflare Cleanup Race (FIXED)

**Symptom:** One challenge valid, another stuck pending. Fresh certs never issue.

**Root cause:** Requesting a cert with both `*.domain` and `domain` creates two concurrent DNS-01 challenges at the same TXT record name. They race each other in cert-manager's Cloudflare cleanup.

**Fix (already applied):** Only request the wildcard (`*.kubew.dev`). Don't include the apex.

### 2. LE Rate Limit (Expected Behavior)

**Symptom:** `429 too many certificates already issued for this exact set of identifiers`.

**Workaround:** Wait up to 7 days, or add an extra SAN to create a new rate limit bucket, or switch to LE staging.

### 3. HA Mobile App + OIDC Incompatibility

**Symptom:** Mobile app shows "redirecting..." forever after SSO login.

**Root cause:** `hass-oidc-auth` component (alpha) shows a finish screen with a manual code instead of redirecting to `homeassistant://auth-callback` which the mobile app expects.

**Workaround:** Use local credentials (`admin` + `${RANCHER_BOOTSTRAP_PASSWORD}`) in the mobile app. Web UI uses SSO normally. Init container auto-seeds the local credential on fresh deploys.

### 4. Rancher Webhook Timing on Fresh Install

**Symptom:** Zitadel/PostgreSQL install fails with "no endpoints available for service rancher-webhook".

**Fix (already applied):** `install_zitadel()` now waits up to 120s for the webhook to be ready.

### 5. Karmada OverridePolicy Scope Too Broad

**Symptom:** Karmada fails to dispatch Services/PVCs to edge clusters.

**Root cause:** `pi-resource-overrides` ClusterOverridePolicy tried to patch container resources on ALL resource types.

**Fix (already applied):** `resourceSelectors` now limits to Deployment/DaemonSet/StatefulSet.

### 6. Apps Block on Missing Namespace in Karmada

**Symptom:** Karmada propagation policies fail with "namespaces X not found".

**Fix (already applied):** `karmada-propagation-policies` Flux Kustomization depends on `apps-base` which creates the namespaces first.

---

## Credentials Reference

Single password for operator convenience: `RANCHER_BOOTSTRAP_PASSWORD` from `.env.bootstrap`.

| Service | Username | Password |
|---------|----------|----------|
| Rancher (local) | admin | `${RANCHER_BOOTSTRAP_PASSWORD}` |
| Rancher (SSO) | jharris | via Zitadel |
| Zitadel | jharris | `${RANCHER_BOOTSTRAP_PASSWORD}!Kw1` |
| GitLab (root) | root | `${RANCHER_BOOTSTRAP_PASSWORD}` |
| Home Assistant (local) | admin | `${RANCHER_BOOTSTRAP_PASSWORD}` |
| Home Assistant (SSO) | jharris | via Zitadel |
| InfluxDB | admin | `kube-world-influx` (in manifest) |

The Rancher bootstrap password is in `.env.bootstrap` as `RANCHER_BOOTSTRAP_PASSWORD`. Zitadel requires a symbol so `!Kw1` is appended for Zitadel user passwords.
