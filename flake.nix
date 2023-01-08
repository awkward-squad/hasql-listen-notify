# This flake.nix isn't for providing Haskell dependencies - it just gets some postgres in scope, since that's a 
# dependency of the postgresql-libpq Haskell package.

{
  description = "hasql-listen-notify";

  inputs = {
    nixpkgs = {
      url = "github:NixOS/nixpkgs/22.05";
    };
  };

  outputs = { self, nixpkgs }:
    {
      devShell = {
        x86_64-linux =
          nixpkgs.legacyPackages.x86_64-linux.mkShell {
            buildInputs = [
              nixpkgs.legacyPackages.x86_64-linux.gmp
              nixpkgs.legacyPackages.x86_64-linux.postgresql
            ];
          };
      };
    };
}
