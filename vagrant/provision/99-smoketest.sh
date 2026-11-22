#!/usr/bin/env bash
set -euo pipefail
source /vagrant/provision/common.sh
echo "=== 99: smoke test ==="

FAIL=0
check() { local name=$1; shift; if "$@" >/dev/null 2>&1; then echo "  [ OK ] $name"; else echo "  [FAIL] $name"; FAIL=1; fi; }
retry() { local n=$1; shift; for _ in $(seq "$n"); do "$@" && return 0; sleep 2; done; return 1; }

set -a; . "$ENV_FILE"; set +a
CA=(); [ "$TLS_MODE" = mkcert ] && CA=(--cacert /root/.local/share/mkcert/rootCA.pem)
HTTPS=(curl -fsS "${CA[@]}" --resolve "$DOMAIN:443:127.0.0.1")
ADMIN_PASS=$(cred_get admin_password)

for s in nginx postgresql redis-server myapp prometheus prometheus-node-exporter \
         prometheus-postgres-exporter prometheus-redis-exporter prometheus-nginx-exporter \
         grafana-server loki alloy fail2ban; do
  check "service $s" systemctl is-active --quiet "$s"
done

check "PostgreSQL query"         psql "$DATABASE_URL" -c "SELECT 1"
check "Redis auth + PING"        redis-cli -a "$REDIS_PASSWORD" --no-auth-warning ping
check "HTTPS app (/up)"          retry 15 "${HTTPS[@]}" "https://$DOMAIN/up"
check "HTTP -> HTTPS redirect"   bash -c "curl -sI http://127.0.0.1/ | grep -qi '^location: https://'"
check "Grafana health via nginx" retry 15 "${HTTPS[@]}" "https://$DOMAIN/grafana/api/health"
check "Prometheus requires auth" bash -c "[ \"\$(curl -s -o /dev/null -w '%{http_code}' ${CA[*]:-} --resolve $DOMAIN:443:127.0.0.1 https://$DOMAIN/prometheus/)\" = 401 ]"
check "Prometheus via nginx"     "${HTTPS[@]}" -u "admin:$ADMIN_PASS" "https://$DOMAIN/prometheus/-/healthy"
check "All Prometheus targets up" retry 20 bash -c \
  "curl -s --data-urlencode 'query=up==0' http://127.0.0.1:9090/prometheus/api/v1/query | jq -e '.data.result|length==0'"
check "Firewall active"          bash -c "ufw status | grep -q 'Status: active'"
check "Backup exists"            bash -c "ls /var/backups/postgres/*.dump"

echo
if [ "$FAIL" -ne 0 ]; then echo "SMOKE TEST FAILED"; exit 1; fi
echo "ALL CHECKS PASSED"
echo
echo "App:        $(public_url)/"
echo "Grafana:    $(public_url)/grafana/      (admin / $ADMIN_PASS)"
echo "Prometheus: $(public_url)/prometheus/   (admin / $ADMIN_PASS)"

NAT_IF=$(ip route show default | awk '{print $5; exit}')
VM_IP=$(ip -4 -o addr show scope global | awk -v nat="$NAT_IF" '$2 != nat {split($4,a,"/"); print a[1]; exit}')
VM_IP=${VM_IP:-$(ip -4 -o addr show scope global | awk '{split($4,a,"/"); print a[1]; exit}')}

if [ "$TLS_MODE" = mkcert ]; then
  echo
  echo "Hosts entry (on the computer where your BROWSER runs):"
  if [ "$PUBLIC_HTTPS_PORT" = "443" ]; then
    echo "  $VM_IP  $DOMAIN"
    echo "Optionally Put # before if you have 127.0.0.1 myapp.local in the hosts file(if it doesnt work)"
  else
    echo "  127.0.0.1  $DOMAIN   (and open a tunnel to port $PUBLIC_HTTPS_PORT)"
  fi
  echo "Trust the CA in ./certs/rootCA.pem (see README)"
fi
