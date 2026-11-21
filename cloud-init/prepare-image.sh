#!/usr/bin/env bash
# One-time host preparation: tools, SSH key, secrets file, Ubuntu 24.04 cloud image -> VirtualBox disk.
# Run once on a fresh machine, then ./deploy.sh as often as you like.
set -euo pipefail
cd "$(dirname "$0")"

command -v VBoxManage >/dev/null || { echo "VirtualBox (VBoxManage) must be installed first"; exit 1; }
sudo apt-get update -q
sudo apt-get install -y cloud-image-utils qemu-utils     # cloud-localds (seed ISO), qemu-img (convert)

# SSH key used only for this VM (public part goes into user-data, private part stays here)
[ -f ~/.ssh/sk44 ] || ssh-keygen -t ed25519 -N "" -f ~/.ssh/sk44 -C "sk44-cloud-init"
# optional Google OAuth keys for the app; never committed
[ -f ~/.sk44-secrets ] || { printf 'GOOGLE_CLIENT_ID=\nGOOGLE_CLIENT_SECRET=\n' > ~/.sk44-secrets; chmod 600 ~/.sk44-secrets; }

# official Ubuntu cloud image, verified against Ubuntu's checksum list
IMG=noble-server-cloudimg-amd64.img
URL=https://cloud-images.ubuntu.com/noble/current
if [ ! -f "$IMG" ]; then
  wget -q --show-progress "$URL/$IMG"
  wget -q -O SHA256SUMS "$URL/SHA256SUMS"
  grep " \*\?$IMG\$" SHA256SUMS | sha256sum -c -
fi
[ -f base.vdi ] || qemu-img convert -O vdi "$IMG" base.vdi
echo "ready -> ./deploy.sh"
