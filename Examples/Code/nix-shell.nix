{ pkgs ? import <nixpkgs> { } }:

pkgs.mkShell {
  name = "dev-shell";
  buildInputs = with pkgs; [ go_1_22 nodejs_20 ripgrep ];
  shellHook = ''
    export GOPATH="$PWD/.go"
    echo "ready: $(go version)"
  '';
}
