#!/usr/bin/env bash
# Deletes the VM and its disk. Usage: ./destroy.sh
cd "$(dirname "$0")"
VBoxManage controlvm cloud-app poweroff 2>/dev/null; sleep 2
VBoxManage unregistervm cloud-app --delete 2>/dev/null
rm -f cloud-app.vdi seed.iso
echo "destroyed"
