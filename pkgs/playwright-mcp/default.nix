{ pkgs }:

pkgs.buildNpmPackage rec {
  pname = "mcp-server-playwright";
  version = "0.0.45";

  buildInputs = [ pkgs.nodejs ];

  nativeBuildInputs = [ pkgs.makeWrapper ];

  src = pkgs.fetchFromGitHub {
    owner = "microsoft";
    repo = "playwright-mcp";
    rev = "v${version}";
    hash = "sha256-mNFhaW/nU4WQtgwiAfM9srWlMFMH7ZSxTPAs1xxH+ac=";
  };

  npmDepsHash = "sha256-zga3jjb72rZVAZsKrAOBS4eR+3WrT+lg9wwy4D4+kDk=";

  # No build script in package.json
  dontNpmBuild = true;

  # Skip browser download during build - we'll use system chromium
  env.PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD = "1";

  # Wrap the executable to use system chromium and writable cache directory
  postInstall = ''
    wrapProgram $out/bin/mcp-server-playwright \
      --set PLAYWRIGHT_BROWSERS_PATH "\$HOME/.cache/ms-playwright" \
      --set PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD "1" \
      --set PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH "${pkgs.chromium}/bin/chromium"
  '';
}
