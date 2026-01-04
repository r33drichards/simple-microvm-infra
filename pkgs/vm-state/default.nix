{ pkgs, src }:

pkgs.rustPlatform.buildRustPackage {
  pname = "vm-state";
  version = "0.1.0";

  inherit src;

  cargoLock = {
    lockFile = "${src}/Cargo.lock";
  };

  meta = with pkgs.lib; {
    description = "Manage portable MicroVM states with ZFS backend";
    license = licenses.mit;
    mainProgram = "vm-state";
  };
}
