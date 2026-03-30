# hosts/hypervisor/smtp-proxy/default.nix
# Packages the SMTP-to-SES relay proxy with Python + dependencies
{ pkgs }:

let
  pythonWithDeps = pkgs.python3.withPackages (ps: [
    ps.boto3
    ps.aiosmtpd
  ]);
in
pkgs.writeShellScriptBin "smtp-ses-proxy" ''
  exec ${pythonWithDeps}/bin/python3 ${./proxy.py} "$@"
''
