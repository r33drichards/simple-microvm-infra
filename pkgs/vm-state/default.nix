{ pkgs, src }:

pkgs.stdenv.mkDerivation {
  pname = "vm-state";
  version = "0.1.0";

  inherit src;

  nativeBuildInputs = with pkgs; [
    meson
    ninja
    pkg-config
  ];

  buildInputs = with pkgs; [
    zfs
    nlohmann_json
  ];

  meta = with pkgs.lib; {
    description = "Manage portable MicroVM states with ZFS backend";
    license = licenses.mit;
    mainProgram = "vm-state";
    platforms = platforms.linux;
  };
}
