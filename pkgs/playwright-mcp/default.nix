{ pkgs }:

pkgs.buildNpmPackage rec {
  pname = "mcp-server-playwright";
  version = "0.0.35";

  buildInputs = [ pkgs.nodejs ];

  nativeBuildInputs = [ pkgs.makeWrapper ];

  src = pkgs.fetchFromGitHub {
    owner = "microsoft";
    repo = "playwright-mcp";
    rev = "v${version}";
    hash = "sha256-bF/F4dP2ri09AlQLItQwQxDAQybY2fXft4ccxSKijt8=";
  };

  npmDepsHash = "sha256-xSQCs6rJlUrdS8c580mo1/VjpcDxwHor0pdstB9VQEo=";

  # Set Playwright to use system chromium instead of downloading browsers
  env.PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD = "1";
  env.PLAYWRIGHT_BROWSERS_PATH = "${pkgs.playwright-driver.browsers}";

  # Wrap the executable to set environment variables at runtime
  postInstall = ''
    wrapProgram $out/bin/mcp-server-playwright \
      --set PLAYWRIGHT_BROWSERS_PATH "0" \
      --set PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD "1" \
      --set PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH "${pkgs.chromium}/bin/chromium"
  '';
}
