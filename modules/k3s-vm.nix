# modules/k3s-vm.nix
# K3s (lightweight Kubernetes) VM configuration - MINIMAL VERSION
# K3s commented out for faster builds
{ config, lib, pkgs, ... }:
{
  # ============================================================
  # MINIMAL CONFIG - SSH only for fast builds
  # ============================================================

  services.openssh.enable = true;
  networking.firewall.allowedTCPPorts = [ 22 ];

  environment.systemPackages = with pkgs; [
    vim
    curl
    htop
    git
  ];

  # ============================================================
  # FULL K3S CONFIG - Uncomment to restore
  # ============================================================

  # # Enable k3s (lightweight Kubernetes)
  # services.k3s = {
  #   enable = true;
  #   role = "server";
  #   extraFlags = toString [
  #     "--data-dir=/var/lib/k3s"
  #     "--write-kubeconfig-mode=644"
  #     "--disable=traefik"
  #   ];
  # };
  #
  # systemd.tmpfiles.rules = [
  #   "d /var/lib/k3s 0755 root root -"
  # ];
  #
  # networking.firewall = {
  #   allowedTCPPorts = [
  #     22     # SSH
  #     6443   # Kubernetes API server
  #     10250  # Kubelet API
  #     80     # HTTP (for ingress)
  #     443    # HTTPS (for ingress)
  #   ];
  #   allowedTCPPortRanges = [
  #     { from = 30000; to = 32767; }
  #   ];
  #   allowedUDPPorts = [
  #     8472   # Flannel VXLAN
  #   ];
  # };
  #
  # environment.systemPackages = with pkgs; [
  #   kubectl
  #   kubernetes-helm
  #   vim
  #   curl
  #   htop
  #   git
  #   jq
  # ];
  #
  # environment.variables.KUBECONFIG = "/etc/rancher/k3s/k3s.yaml";
  #
  # programs.bash.shellAliases = {
  #   k = "kubectl";
  #   kns = "kubectl config set-context --current --namespace";
  # };
}
