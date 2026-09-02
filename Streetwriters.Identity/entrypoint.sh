#!/bin/sh
set -e

GPG_HOME="/app/.gnupg"
KEYSTORE_DIR="/app/keystore"

# Initialize GPG directory
mkdir -p "$GPG_HOME"
chmod 700 "$GPG_HOME"

# Check if we already have a private key
if ! gpg --homedir "$GPG_HOME" --list-secret-keys 2>/dev/null | grep -q "sec"; then
    echo "No GPG key found, generating..."

    # Generate a new PGP key non-interactively
    cat > "$GPG_HOME/gen_key_script" <<EOF
%echo Generating PGP key
Key-Type: RSA
Key-Length: 2048
Subkey-Type: RSA
Subkey-Length: 2048
Name-Real: Notesnook
Name-Email: support@notesnook.com
Expire-Date: 0
%no-protection
%commit
%echo done
EOF

    gpg --homedir "$GPG_HOME" --batch --gen-key "$GPG_HOME/gen_key_script" 2>/dev/null
    rm -f "$GPG_HOME/gen_key_script"
    echo "PGP key generated successfully"
else
    echo "Using existing GPG key"
fi

# List keys for debugging
gpg --homedir "$GPG_HOME" --list-keys 2>/dev/null || true

# Start the identity server
exec ./Streetwriters.Identity
