#!/usr/bin/env bash
# Creates the cloud-init VM in VirtualBox from scratch. Usage: ./deploy.sh
set -euo pipefail
cd "$(dirname "$0")"
VM=cloud-app
IP=192.168.56.10
FQDN=${FQDN:-cloud.devops-sk-44.lrk.si}   # override: FQDN=my.domain ./deploy.sh
APP_COMMIT=01c9c48f454b3b02c0f4b57410208b1edbcaed95
# Let's Encrypt: LE_MODE=staging (default, for testing) | prod (real cert, max 5/week!) | off
LE_MODE=${LE_MODE:-staging}
case "$LE_MODE" in staging) LE_FLAGS="--staging";; prod) LE_FLAGS="";; off) LE_FLAGS="skip";; *) echo "LE_MODE?"; exit 1;; esac
START=$(date +%s)
source ~/.sk44-secrets

# render user-data from the template (secrets only end up in the seed ISO on this host)
sed -e "s|__SSH_PUBKEY__|$(cat ~/.ssh/sk44.pub)|" \
    -e "s|__FQDN__|$FQDN|g" \
    -e "s|__APP_COMMIT__|$APP_COMMIT|" \
    -e "s|__LE_FLAGS__|$LE_FLAGS|" \
    -e "s|__GOOGLE_CLIENT_ID__|${GOOGLE_CLIENT_ID}|" \
    -e "s|__GOOGLE_CLIENT_SECRET__|${GOOGLE_CLIENT_SECRET}|" \
    user-data.tmpl > user-data
cloud-init schema --config-file user-data 2>/dev/null || true

VBoxManage list hostonlyifs | grep -q '^Name: *vboxnet0' || VBoxManage hostonlyif create
cloud-localds --network-config=network-config seed.iso user-data meta-data
VBoxManage clonemedium disk base.vdi "$PWD/$VM.vdi" --format VDI >/dev/null
VBoxManage modifymedium disk "$PWD/$VM.vdi" --resize 20480

VBoxManage createvm --name "$VM" --ostype Ubuntu_64 --register >/dev/null
VBoxManage modifyvm "$VM" --cpus 4 --memory 4096 --audio-driver none \
  --nic1 nat --nic2 hostonly --hostonlyadapter2 vboxnet0 \
  --uart1 0x3F8 4 --uartmode1 file "/tmp/$VM-console.log"
VBoxManage storagectl "$VM" --name SATA --add sata --controller IntelAhci --portcount 2
VBoxManage storageattach "$VM" --storagectl SATA --port 0 --device 0 --type hdd --medium "$PWD/$VM.vdi"
VBoxManage storageattach "$VM" --storagectl SATA --port 1 --device 0 --type dvddrive --medium "$PWD/seed.iso"
VBoxManage startvm "$VM" --type headless

SSH="ssh -i $HOME/.ssh/sk44 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=3 -o LogLevel=ERROR ubuntu@$IP"
echo "Waiting for SSH..."
for i in $(seq 100); do        # ~5 min max
  $SSH true 2>/dev/null && break
  if ! VBoxManage showvminfo "$VM" --machinereadable | grep -q '^VMState="running"'; then
    echo; echo "VM is not running any more. Last console lines:"; tail -20 "/tmp/$VM-console.log"; exit 1
  fi
  printf .; sleep 3
done; echo
$SSH true 2>/dev/null || { echo "SSH did not come up in 5 min. Last console lines:"; tail -20 "/tmp/$VM-console.log"; exit 1; }
echo "Waiting for cloud-init to finish (log inside VM: /var/log/setup-app.log)..."
$SSH "sudo tail -n +1 -F /var/log/setup-app.log 2>/dev/null | grep --line-buffered -E '^(===|SMOKE|TLS:)'" &
TAIL=$!
if $SSH 'cloud-init status --wait' >/dev/null; then kill $TAIL 2>/dev/null || true
  echo "Deploy finished in $(( $(date +%s) - START )) s"
  $SSH 'L=/var/log/setup-app.log; sudo grep "^TLS:" $L; echo "smoke test: $(sudo grep -c "^SMOKE OK" $L) OK, $(sudo grep -c "^SMOKE FAIL" $L) FAIL"; sudo cat /root/monitoring.txt' || true
else
  kill $TAIL 2>/dev/null || true
  echo "cloud-init FAILED after $(( $(date +%s) - START )) s. Last lines of the log:"
  $SSH 'sudo tail -n 30 /var/log/setup-app.log'
  exit 1
fi
