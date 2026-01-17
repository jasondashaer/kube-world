# Secrets Management

This directory contains encrypted secrets for the kube-world infrastructure.

## Setup

### 1. Generate Age Key

```bash
# Install age
brew install age  # macOS
# or
apt install age   # Linux

# Generate keypair
age-keygen -o ~/.sops/key.txt

# Note your public key (starts with 'age1...')
cat ~/.sops/key.txt | grep "public key"
```

### 2. Configure SOPS

Update `../.sops.yaml` with your public key.

### 3. Set Environment Variable

```bash
export SOPS_AGE_KEY_FILE=~/.sops/key.txt
```

Add to your shell profile (~/.zshrc or ~/.bashrc).

## Usage

### Encrypt a Secret

```bash
# Create from template
cp secrets.template.yaml my-secrets.yaml
# Edit my-secrets.yaml with actual values
sops -e my-secrets.yaml > my-secrets.enc.yaml
rm my-secrets.yaml  # Remove unencrypted file
```

### Decrypt a Secret

```bash
sops -d my-secrets.enc.yaml
```

### Edit Encrypted Secret

```bash
sops my-secrets.enc.yaml  # Opens in $EDITOR
```

## Security Notes

1. **NEVER** commit unencrypted secrets
2. Store `~/.sops/key.txt` securely (consider password manager)
3. Back up your age private key - losing it means losing access to secrets
4. Use different keys for dev/prod environments
5. Rotate secrets periodically

## Files

- `secrets.template.yaml` - Template for creating new secrets
- `*.enc.yaml` - Encrypted secrets (safe to commit)
