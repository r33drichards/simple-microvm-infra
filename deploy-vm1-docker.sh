#!/usr/bin/env bash
# Deploy Docker to vm1 and run sandbox container using NixOS OCI containers
# This script should be run on the hypervisor (16.144.20.78)

set -e

echo "==> Checking out branch with Docker configuration..."
cd /root/simple-microvm-infra
git fetch origin
git checkout claude/deploy-docker-sandbox-011CUeEKVQfDeopHtRiYgA8u
git pull

echo "==> Rebuilding vm1 with declarative container configuration..."
microvm -Ru vm1

echo "==> Waiting for vm1 to be ready..."
sleep 15

echo "==> Checking container status..."
ssh root@10.1.0.2 << 'EOSSH'
echo "Docker containers:"
docker ps -a
echo ""
echo "Systemd service status:"
systemctl status docker-sandbox.service --no-pager
EOSSH

echo ""
echo "==> Docker container deployed successfully!"
echo "==> The container is managed declaratively by NixOS"
echo "==> Container service: docker-sandbox.service"
echo "==> To check status: ssh root@10.1.0.2 'systemctl status docker-sandbox'"
echo "==> To view logs: ssh root@10.1.0.2 'journalctl -u docker-sandbox -f'"
echo "==> To check container: ssh root@10.1.0.2 'docker ps'"
