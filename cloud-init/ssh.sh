#!/usr/bin/env bash
exec ssh -i ~/.ssh/sk44 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR ubuntu@192.168.56.10 "$@"
