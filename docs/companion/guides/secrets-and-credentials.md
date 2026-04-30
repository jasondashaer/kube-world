# Guide: Secrets and Credentials

How credentials (ProPresenter passwords, OBS WebSocket passwords,
Spotify OAuth, Pro7 macro UUIDs, Spotify playlist URIs) flow into
Companion at deploy time without ever appearing in plaintext in git.

Two paths, one source YAML:

| Mode | Cleartext source | Mechanism | Operator effort |
|---|---|---|---|
| **k3s** | SealedSecret CR in repo | Bitnami Sealed Secrets controller decrypts → K8s Secret → companion-deploy Pod `envFrom` | Encrypt once via `kubeseal`, commit, Flux applies |
| **vanilla** | `/etc/default/companion` on the Pi | systemd `EnvironmentFile=` injects into companion process env | Edit file on Pi, restart service |

In both modes, `connections.yaml` references credentials as
`${VAR}` placeholders. `companion-deploy.py generate` substitutes them
from the environment when the seed/import is built.

---

## 1. The substitution rule

In `apps/companion/config/connections.yaml`:

```yaml
- id: obs_yibc
  module: "bitfocus-obs-websocket"
  config:
    host: "192.168.1.50"           # hardcoded — site-stable, low-risk
    port: "4455"
    password: "${OBS_PASSWORD_YIBC}" # env-injected
```

When the deploy script runs:

- Env var `OBS_PASSWORD_YIBC` set → substituted in.
- Env var unset / empty → string left as literal `${OBS_PASSWORD_YIBC}`.
  Operator sees the placeholder in Companion's web UI and knows to
  fix it. **No silent emptying** — that would corrupt the connection
  without warning.

Variables in scope:

| Variable | Used by |
|---|---|
| `PROPRESENTER_PASSWORD_YIBC` | propresenter_yibc |
| `PROPRESENTER_PASSWORD_SAITAMA` | propresenter_saitama |
| `OBS_PASSWORD_YIBC` | obs_yibc |
| `OBS_PASSWORD_SAITAMA` | obs_saitama |
| `SPOTIFY_CLIENT_ID` | spotify_yibc |
| `SPOTIFY_CLIENT_SECRET` | spotify_yibc |
| `SPOTIFY_CLIENT_ID_SAITAMA` | spotify_saitama |
| `SPOTIFY_CLIENT_SECRET_SAITAMA` | spotify_saitama |

Add new variables by:
1. Reference `${NEW_VAR}` in `connections.yaml`.
2. Add to `apps/companion/secrets/companion-credentials.unsealed.example.yaml`.
3. Re-seal (k3s) or update `.env` (vanilla).

---

## 2. K3s mode setup (one-time per cluster)

### 2.1 Install the controller

The Sealed Secrets controller HelmRelease at
`infrastructure/sealed-secrets/helmrelease.yaml` deploys to the cluster
when `flux/kustomizations/sealed-secrets.yaml` reconciles. First time:

```bash
flux reconcile kustomization sealed-secrets --kubeconfig=...
kubectl get pods -n sealed-secrets    # wait for Running
```

The controller generates a keypair on first start. **Back up the
private key immediately**:

```bash
kubectl get secret -n sealed-secrets \
  -l sealedsecrets.bitnami.com/sealed-secrets-key \
  -o yaml > sealed-secrets-key-$(date +%Y%m%d).yaml
# Move offline (1Password, password manager, etc.). NEVER commit.
```

If you lose this key and the controller's PVC, every SealedSecret in
git is unrecoverable.

### 2.2 Install kubeseal CLI on your Mac

```bash
brew install kubeseal
```

### 2.3 Create the SealedSecret for Companion

Copy the example template:

```bash
cd apps/companion/secrets/
cp companion-credentials.unsealed.example.yaml companion-credentials.unsealed.yaml
$EDITOR companion-credentials.unsealed.yaml   # fill in real values
```

Encrypt against the cluster controller's pubkey:

```bash
kubeseal \
  --controller-namespace sealed-secrets \
  --controller-name sealed-secrets-controller \
  --kubeconfig ~/.kube/config \
  -f companion-credentials.unsealed.yaml \
  -w companion-credentials.sealed.yaml
```

`companion-credentials.unsealed.yaml` is gitignored (cleartext, never
commit). `companion-credentials.sealed.yaml` is the encrypted output —
safe to commit.

```bash
shred -u companion-credentials.unsealed.yaml   # delete cleartext
git add companion-credentials.sealed.yaml
git commit -m "chore: seal Companion credentials for <cluster>"
git push
```

Add to `apps/companion/kustomization.yaml`:

```yaml
resources:
  - deployment.yaml
  - gitops/deploy-job.yaml
  - secrets/companion-credentials.sealed.yaml   # new
```

Flux applies the SealedSecret. The controller decrypts to a real
`Secret/companion-credentials` in the `companion` namespace.

The deploy-job init container already has `envFrom: { secretRef: { name: companion-credentials, optional: true } }`, so credentials populate automatically on next reconcile.

### 2.4 Per-cluster sealing

Each cluster has its own keypair. A SealedSecret encrypted against
the **dev** cluster does NOT decrypt on the **prod** cluster. This is
the intended security boundary.

For dev → prod promotion, you re-seal:

```bash
# Re-seal against prod cluster
kubeseal --kubeconfig ~/.kube/config-prod \
  --controller-namespace sealed-secrets \
  --controller-name sealed-secrets-controller \
  -f companion-credentials.unsealed.yaml \
  -w companion-credentials.sealed.prod.yaml

git add companion-credentials.sealed.prod.yaml
```

Then use kustomize overlays to select per-environment:
`overlays/dev/` references `.sealed.dev.yaml`, `overlays/prod/` references
`.sealed.prod.yaml`. See `ENVIRONMENT-STRATEGY.md`.

### 2.5 Rotation

Periodic rotation procedure:

1. Update `.unsealed.yaml` on local disk with new value.
2. Re-seal to `.sealed.yaml` (overwriting).
3. Commit + push.
4. Flux re-applies SealedSecret. Controller updates the K8s Secret.
5. Restart companion-deploy: `kubectl rollout restart deployment/companion-deploy -n companion`. Init container picks up new env on the new Pod.
6. `shred -u` the cleartext.

---

## 3. Vanilla mode setup (per Pi)

No kubeseal, no controller, no Secret CRs. Just a file on disk.

### 3.1 First install

The install script copies `deploy/vanilla/site/<site>/.env.example` to
`/etc/default/companion` (mode 640, owner root:companion). Edit on the Pi:

```bash
sudo $EDITOR /etc/default/companion
```

Fill in the same values that go into the SealedSecret in k3s mode.

### 3.2 Apply

```bash
sudo systemctl restart companion
```

systemd's `EnvironmentFile=/etc/default/companion` directive in the
unit file injects every `KEY=value` line as an env var into the
companion process. The seed import (one-time) consumes them.

After the initial seed import, Companion's own DB stores the values —
the env file is no longer the source of truth at vanilla sites. If
you change the env file, you have to re-import the seed for it to take
effect (or edit values via Companion web UI). This is consistent with
vanilla mode being operator-owned: drift from the env file is
acceptable.

### 3.3 Backup of the env file

The Pi's `/etc/default/companion` file is the only copy of these
credentials at vanilla sites. Back it up:

```bash
# On the Pi
sudo cp /etc/default/companion /root/companion.env.backup
# Off the Pi (e.g. to laptop via Tailscale)
scp pi-edge-1:/root/companion.env.backup ./companion-yibc.env.backup
gpg -c companion-yibc.env.backup       # encrypt with passphrase
shred -u companion-yibc.env.backup     # remove cleartext
```

Store the encrypted backup somewhere safe (1Password vault, etc.). If
the Pi dies and you re-image, restoring this env file gets you 90% of
the way back.

---

## 4. OAuth-specific concerns (Spotify, future Google APIs)

OAuth credentials have two layers:

### Layer 1: Developer-app credentials

`SPOTIFY_CLIENT_ID` + `SPOTIFY_CLIENT_SECRET`. These represent the
Companion app's identity to Spotify. Created at
[developer.spotify.com/dashboard](https://developer.spotify.com/dashboard).
Static — change rarely.

Goes in the SealedSecret / env file.

### Layer 2: User refresh token

After the developer-app credentials are configured, the operator
clicks "Authorize" in Companion's web UI. Browser redirects to Spotify
login → user grants permission → Spotify returns a refresh token →
Companion stores it in its own DB.

This refresh token is **per-user-account, not per-app**. It survives
Companion restarts. It does NOT survive a fresh Companion install
(import seed config doesn't include the refresh token — it's stored
in DB).

Implication for k3s mode auto-import: the import flow rebuilds
Companion's connection state from the YAML + env. The OAuth refresh
token, stored in Companion's SQLite DB, IS preserved across imports
if the Companion DB persists (which it does — PVC mounts at
`/companion`). So:

1. First-time setup: operator clicks Authorize once in web UI.
2. From then on: every git push that triggers a re-import keeps the
   token (DB unchanged).
3. PVC wipe: re-authorize once.

For vanilla mode: same story but DB is local on the Pi.

### Account swap

Different Spotify account → re-authorize via Companion UI. Code change
not required unless you want different developer-app credentials too
(rare).

### Per-location accounts

YIBC and Saitama have separate developer apps + separate OAuth tokens.
Different `SPOTIFY_CLIENT_ID` env vars (`SPOTIFY_CLIENT_ID` for YIBC,
`SPOTIFY_CLIENT_ID_SAITAMA` for Saitama). The web UI authorize step
runs once per location.

---

## 5. What should NOT be in env vars

Things that don't belong in the credentials Secret:

| Field | Where it goes instead |
|---|---|
| Channel numbers (Pastor=11, etc.) | Hardcoded in page YAML — not secret, location-stable |
| Mixer IPs | Hardcoded in connections.yaml — site-stable |
| Stream Deck IPs | Hardcoded in surfaces.yaml |
| Pro7 closing macro UUID | **Could** be secret-ish, but it's an identifier not a credential. Hardcoded OK. |
| Spotify playlist URI | NOT secret. URI is just a public identifier. Hardcoded OK. |

If something doesn't grant access when leaked, it's not a secret.

---

## 6. Failure modes + diagnosis

| Symptom | Likely cause |
|---|---|
| Companion connection shows red, password field shows literal `${OBS_PASSWORD_YIBC}` | Env var not set in deploy-job pod. Check `kubectl get secret -n companion companion-credentials -o yaml` exists and has the key. |
| Sealed secret never decrypts to a Secret | Controller not running, or the SealedSecret was sealed against a different cluster. Check `kubectl logs -n sealed-secrets ...`. |
| systemd companion service starts but env file changes don't take effect | Companion uses its DB for config after first import. Re-import via web UI or via `companion-deploy.py import` to pick up new env values. |
| `kubeseal` CLI fails with "unable to fetch certificate" | Controller not Running yet, or kubeconfig wrong. Verify pod status first. |
| OAuth was working then suddenly fails | Refresh token expired (Spotify rotates after long inactivity). Re-authorize in Companion web UI. |

---

## Cross-references

- Connection definitions: `apps/companion/config/connections.yaml`
- Substitution code: `apps/companion/scripts/companion-deploy.py` (`substitute_env`)
- SealedSecret template: `apps/companion/secrets/companion-credentials.unsealed.example.yaml`
- Sealed Secrets HelmRelease: `infrastructure/sealed-secrets/helmrelease.yaml`
- Vanilla env templates: `deploy/vanilla/site/<site>/.env.example`
- Environment strategy: [ENVIRONMENT-STRATEGY.md](../ENVIRONMENT-STRATEGY.md)
