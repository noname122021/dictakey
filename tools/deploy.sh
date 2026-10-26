#!/bin/bash
# Installs .deb to iOS device: ./deploy.sh <path.deb> [user@host]
# Note: Legacy iOS 6 OpenSSH requires legacy ciphers & key exchange.
set -e
DEB="$1"
HOST="${2:-root@iphone.local}"
[ -f "$DEB" ] || { echo "Usage: $0 <path.deb> [user@host]"; exit 1; }

SSH_OPTS="-o KexAlgorithms=+diffie-hellman-group1-sha1,diffie-hellman-group14-sha1 \
  -o HostKeyAlgorithms=+ssh-rsa -o Ciphers=+aes128-cbc,aes256-cbc,3des-cbc \
  -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10"

scp $SSH_OPTS "$DEB" "$HOST:/var/root/" && \
ssh $SSH_OPTS "$HOST" "dpkg -i /var/root/$(basename "$DEB") && rm /var/root/$(basename "$DEB") && su mobile -c uicache || uicache"
