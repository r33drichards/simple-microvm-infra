# modules/k3s-vm.nix
# K3s (lightweight Kubernetes) VM configuration
# Runs a single-node k3s cluster with persistent storage
{ config, lib, pkgs, ... }:
{
  # Enable k3s (lightweight Kubernetes)
  services.k3s = {
    enable = true;
    role = "server";
    # Store data on persistent volume
    extraFlags = toString [
      "--data-dir=/persist/k3s"
      "--write-kubeconfig-mode=644"
      "--disable=traefik"  # Disable default traefik, can add it later if needed
    ];
  };

  # Ensure k3s data directory exists on persistent storage
  systemd.tmpfiles.rules = [
    "d /persist/k3s 0755 root root -"
  ];

  # Open firewall ports for Kubernetes
  networking.firewall = {
    # Allow Kubernetes API server
    allowedTCPPorts = [
      22     # SSH
      6443   # Kubernetes API server
      10250  # Kubelet API
      80     # HTTP (for ingress)
      443    # HTTPS (for ingress)
    ];
    # NodePort range
    allowedTCPPortRanges = [
      { from = 30000; to = 32767; }  # NodePort services
    ];
    # Allow flannel VXLAN
    allowedUDPPorts = [
      8472   # Flannel VXLAN
    ];
  };

  # Install Kubernetes tools and basic packages
  environment.systemPackages = with pkgs; [
    # Kubernetes tools
    kubectl
    kubernetes-helm
    # Basic utilities
    vim
    curl
    htop
    git
    jq
  ];

  # Create kubectl alias and KUBECONFIG for root and robertwendt
  environment.variables.KUBECONFIG = "/etc/rancher/k3s/k3s.yaml";

  # Bash aliases for convenience
  programs.bash.shellAliases = {
    k = "kubectl";
    kns = "kubectl config set-context --current --namespace";
  };

  # SSH access for management
  services.openssh.enable = true;
}
