#!/usr/bin/env bash
# Deploy Docker to vm1 and run sandbox container
# This script should be run on the hypervisor (16.144.20.78)

set -e

echo "==> Checking out branch with Docker configuration..."
cd /root/simple-microvm-infra
git fetch origin
git checkout claude/deploy-docker-sandbox-011CUeEKVQfDeopHtRiYgA8u
git pull

echo "==> Rebuilding vm1 with Docker support..."
microvm -Ru vm1

echo "==> Waiting for vm1 to be ready..."
sleep 10

echo "==> Pulling and running sandbox container in vm1..."
ssh root@10.1.0.2 << 'EOSSH'
docker pull wholelottahoopla/sandbox:latest
docker run -d --name sandbox --restart unless-stopped wholelottahoopla/sandbox:latest
docker ps -a
EOSSH

echo "==> Docker container deployed successfully!"
echo "==> To check container status: ssh root@10.1.0.2 'docker ps'"
echo "==> To view container logs: ssh root@10.1.0.2 'docker logs sandbox'"
