{ pkgs }:

pkgs.stdenv.mkDerivation {
  name = "oauth-proxy";
  src = ./.;
  installPhase = ''
    mkdir -p $out/bin $out/share/oauth-proxy
    cp proxy.py $out/bin/oauth-proxy
    chmod +x $out/bin/oauth-proxy
    sed -i "1s|.*|#!${pkgs.python3}/bin/python3|" $out/bin/oauth-proxy
    cp policy.json $out/share/oauth-proxy/policy.json
  '';
}
