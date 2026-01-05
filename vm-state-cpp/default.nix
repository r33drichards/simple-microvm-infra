{ lib
, stdenv
, cmake
, pkg-config
, systemd
, zfs
, util-linux
, libtirpc
, zlib
}:

stdenv.mkDerivation rec {
  pname = "vm-state";
  version = "1.0.0";

  src = ./.;

  nativeBuildInputs = [
    cmake
    pkg-config
  ];

  buildInputs = [
    systemd
    zfs  # Provides libzfs and libnvpair
    util-linux  # Provides blkid, required by libzfs pkg-config
    libtirpc  # Required by libzfs pkg-config
    zlib  # Required by libzfs_core pkg-config
  ];

  cmakeFlags = [
    "-DCMAKE_BUILD_TYPE=Release"
  ];

  meta = with lib; {
    description = "Manage portable VM states with ZFS and systemd using libzfs";
    homepage = "https://github.com/r33drichards/simple-microvm-infra";
    license = licenses.mit;
    maintainers = [ ];
    platforms = platforms.linux;
    mainProgram = "vm-state";
  };
}
