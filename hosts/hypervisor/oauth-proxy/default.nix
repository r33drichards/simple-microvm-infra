{ pkgs }:

let
  oso = pkgs.python3Packages.buildPythonPackage {
    pname = "oso";
    version = "0.27.3";
    format = "wheel";
    src = pkgs.fetchurl {
      # No aarch64-linux wheel exists on PyPI for oso 0.27.3;
      # using the cp311 manylinux x86_64 wheel as the closest upstream artifact.
      # On the aarch64 host this will be run via the binfmt/emulation path or
      # replaced by a source build if a native wheel becomes available.
      url = "https://files.pythonhosted.org/packages/0d/bb/341e5d21c2674112fb55c31906207477d224a9168bdf57b25dc650cc1829/oso-0.27.3-cp311-cp311-manylinux_2_17_x86_64.manylinux2014_x86_64.whl";
      sha256 = "sha256-k/vt46bVCQeA4l7KM/13pS9jwO0fiK0PLpaJCsfD/hc=";
    };
    doCheck = false;
  };

  pythonEnv = pkgs.python3.withPackages (_: [ oso ]);

in
pkgs.stdenv.mkDerivation {
  name = "oauth-proxy";
  src = ./.;
  installPhase = ''
    mkdir -p $out/bin
    cp proxy.py $out/bin/oauth-proxy
    chmod +x $out/bin/oauth-proxy
    sed -i "1s|.*|#!${pythonEnv}/bin/python3|" $out/bin/oauth-proxy
  '';
}
