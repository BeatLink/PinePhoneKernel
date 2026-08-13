# SPDX-License-Identifier: GPL-2.0-only
{
    description = "megi's PinePhone kernel packaged for NixOS, with a signed binary cache published per commit";

    inputs = {
        nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

        # Only the device directory is used -- the kernel config, the LED patch
        # and the firmware list. None of mobile-nixos' NixOS modules are
        # imported, so this stays compatible with a stock NixOS system.
        mobile-nixos = {
            url = "github:NixOS/mobile-nixos";
            flake = false;
        };
    };

    outputs =
        {
            self,
            nixpkgs,
            mobile-nixos,
        }:
        let
            system = "aarch64-linux";
            pkgs = nixpkgs.legacyPackages.${system};

            # kernelPatches must be passed explicitly: nixpkgs has a top-level
            # `kernelPatches` attribute (a set of named patches), which
            # callPackage would otherwise auto-fill over the default, giving
            # "expected a list but found a set".
            kernel = pkgs.callPackage ./kernel.nix {
                inherit mobile-nixos;
                kernelPatches = [ ];
            };
        in
        {
            packages.${system} = {
                default = kernel;
                linux-pinephone-megi = kernel;
            };

            # For anyone who would rather build it against their own nixpkgs than
            # take the cached artifact. Note this gives up the cache: a different
            # nixpkgs means a different stdenv means a different derivation.
            overlays.default = _final: prev: {
                linux-pinephone-megi = prev.callPackage ./kernel.nix {
                    inherit mobile-nixos;
                    kernelPatches = [ ];
                };
            };

            # Deliberately uses self.packages rather than rebuilding against the
            # importing system's nixpkgs. That is what makes the binary cache
            # actually hit -- rebuilding with your own nixpkgs produces a
            # different derivation and a multi-hour aarch64 build.
            #
            # A kernel built from a slightly different nixpkgs than userland is
            # fine; they do not need to match. Out-of-tree modules (ZFS and
            # friends) still build locally against it, since linuxPackagesFor
            # uses your pkgs for those.
            nixosModules.default =
                { pkgs, ... }:
                {
                    boot.kernelPackages = pkgs.linuxPackagesFor self.packages.${system}.linux-pinephone-megi;
                };

            formatter.${system} = pkgs.nixfmt-rfc-style;
            formatter.x86_64-linux = nixpkgs.legacyPackages.x86_64-linux.nixfmt-rfc-style;
        };
}
