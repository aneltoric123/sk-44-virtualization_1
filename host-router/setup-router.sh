#!/usr/bin/env bash
# Host router on devops-sk-44 (the only machine with a public IP).
# VMs live on the VirtualBox host-only network 192.168.56.0/24.
#  - port 80:  HTTP reverse proxy, VM chosen by the Host header (Let's Encrypt HTTP-01 + redirect to HTTPS)
#  - port 443: TLS passthrough. nginx "stream" reads only the SNI name (ssl_preread) and forwards the
#              encrypted connection; certificates and private keys stay inside each VM.
#              Cloud VM: PROXY protocol is added so the VM sees the real client IP (logs, rate limits).
set -euo pipefail

CLOUD_FQDN=cloud.devops-sk-44.lrk.si;     CLOUD_IP=192.168.56.10
VAGRANT_FQDN=vagrant.devops-sk-44.lrk.si; VAGRANT_IP=192.168.56.5

sudo apt-get install -y nginx libnginx-mod-stream

sudo install -d /etc/nginx/stream.d
grep -q 'stream.d/\*.conf' /etc/nginx/nginx.conf || \
  echo 'include /etc/nginx/stream.d/*.conf;' | sudo tee -a /etc/nginx/nginx.conf >/dev/null
sudo tee /etc/nginx/stream.d/sk44-sni.conf >/dev/null <<CONF
stream {
  # 1st hop: pick the backend by SNI, always add a PROXY header (to local listeners only)
  map \$ssl_preread_server_name \$sk44_backend {
    $CLOUD_FQDN    127.0.0.1:10443;
    $VAGRANT_FQDN  127.0.0.1:10444;
    default        127.0.0.1:9;      # unknown name -> refused
  }
  server {
    listen 443;
    ssl_preread on;
    proxy_protocol on;
    proxy_pass \$sk44_backend;
    proxy_connect_timeout 5s;
  }

  # cloud VM: forward the real client IP with PROXY protocol (VM listens on 8443 with proxy_protocol)
  server {
    listen 127.0.0.1:10443 proxy_protocol;
    set_real_ip_from 127.0.0.1;
    proxy_protocol on;
    proxy_pass $CLOUD_IP:8443;
  }
  # Vagrant VM: plain TLS passthrough (header is consumed here, not forwarded)
  server {
    listen 127.0.0.1:10444 proxy_protocol;
    proxy_pass $VAGRANT_IP:443;
  }
}
CONF

sudo tee /etc/nginx/sites-available/sk44-router >/dev/null <<CONF
# unknown host names get no answer
server {
  listen 80 default_server;
  server_name _;
  return 444;
}
server {
  listen 80;
  server_name $CLOUD_FQDN;
  location / {
    proxy_pass http://$CLOUD_IP;
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
  }
}
server {
  listen 80;
  server_name $VAGRANT_FQDN;
  location / {
    proxy_pass http://$VAGRANT_IP;
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
  }
}
CONF
sudo rm -f /etc/nginx/sites-enabled/default
sudo ln -sf /etc/nginx/sites-available/sk44-router /etc/nginx/sites-enabled/sk44-router

if sudo ufw status | grep -q 'Status: active'; then sudo ufw allow 80/tcp; sudo ufw allow 443/tcp; fi

sudo nginx -t
sudo systemctl enable --now nginx
sudo systemctl reload nginx
echo "router ready"
