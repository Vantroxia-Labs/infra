#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
# Generate SSH key pair for CI/CD deployment
# Run this LOCALLY (not on the VPS). It creates:
#   - deploy_key     → add as GitHub secret VPS_SSH_KEY
#   - deploy_key.pub → append to VPS deploy user's authorized_keys
# ═══════════════════════════════════════════════════════════════════════════
set -euo pipefail

KEY_FILE="deploy_key"

if [ -f "$KEY_FILE" ]; then
  echo "Key already exists: $KEY_FILE"
  echo "Delete it first if you want to regenerate."
  exit 1
fi

ssh-keygen -t ed25519 -C "aegisremit-ci-deploy" -f "$KEY_FILE" -N ""

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "  SSH key pair generated!"
echo ""
echo "  1. Add PRIVATE key as GitHub secret:"
echo "     → Go to: github.com/Vantroxia-Labs/infra/settings/secrets"
echo "     → Name:  VPS_SSH_KEY"
echo "     → Value: contents of $KEY_FILE"
echo ""
echo "  2. Add PUBLIC key to VPS:"
echo "     ssh deploy@YOUR_VPS_IP"
echo "     echo '$(cat ${KEY_FILE}.pub)' >> ~/.ssh/authorized_keys"
echo ""
echo "  3. Delete the private key from your local machine after"
echo "     adding it to GitHub secrets (don't keep copies)."
echo "═══════════════════════════════════════════════════════════════"
