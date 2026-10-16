#!/bin/sh
set -e

# GNUPGHOME, not a literal path. BouncyCastle's GnuPGContext resolves the
# keyring through GNUPGHOME when it is set and falls back to $HOME/.gnupg
# otherwise, so the shell keygen below and the signing code in the app have to
# agree on ONE directory.
#
# This is a MOUNT POINT. It used to be an unmounted path in the container
# layer, which meant: every recreate (image update, compose change, host reboot
# with a new container id) generated a brand-new keypair, and the previous key
# was gone with the old container. Recipients who had verified the older key
# lost that verification, and backups never contained it -- backup.sh archived
# keystore-data, which is a different directory (the IdentityServer signing-key
# store, see Startup.cs AddFileSystemPersistence) and never held the GPG key.
GNUPGHOME=/app/.gnupg
GPG_HOME="$GNUPGHOME"
export GNUPGHOME
KEYSTORE_DIR="/app/keystore"

# Initialize GPG directory
mkdir -p "$GPG_HOME"
chmod 700 "$GPG_HOME"

# Use SMTP_USERNAME as the GPG key email (matches sender address)
GPG_EMAIL="${SMTP_USERNAME:-support@notesnook.com}"
GPG_NAME="${SMTP_FROM_NAME:-Notesnook}"

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
Name-Real: $GPG_NAME
Name-Email: $GPG_EMAIL
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
