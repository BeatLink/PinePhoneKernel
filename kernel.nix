# SPDX-License-Identifier: GPL-2.0-only
#
# megi's PinePhone kernel, packaged for NixOS.
#
# This is the same source postmarketOS ships, and it carries the drivers mainline
# does not:
#
#   CONFIG_TYPEC_ANX7688=y     the USB-C controller. Without it there is no role
#                              detection, so the UDC never attaches, no Type-C
#                              port registers, and DisplayPort alt mode and
#                              USB-PD are all impossible. One missing driver
#                              costs three features.
#   CONFIG_RTL8723CS=y         WiFi. megi's driver, not mainline's rtw88.
#   CONFIG_IP5XXX_POWER=y      the keyboard case's battery.
#
# It also fixes charging, which mainline cannot do on this hardware at all. The
# PinePhone's pack has a 3k NTC; the AXP803 powers up with its over-temperature
# threshold at 1FH, tuned for a 10k NTC, and mainline never reprograms it. So a
# healthy pack at any ordinary room temperature reads as over-temperature and the
# charger refuses. megi's tree sets it to 960 ohms and charging works. See the
# PinePhone block in drivers/power/supply/axp20x_battery.c.
#
# Built with nixpkgs' linuxManualConfig rather than mobile-nixos' kernel-builder,
# taking only the source, config and patches from mobile-nixos' device directory.
# That builder deletes lib/modules/*/build and lib/modules/*/source in its
# postInstall and produces no `dev` output, so there is no build tree to compile
# out-of-tree modules against -- fine for a phone with everything built in, fatal
# if you want ZFS, or any DKMS-style module. It also omits `features`, `config`
# and `commonMakeFlags`, each of which NixOS reads at evaluation time.
#
{
    lib,
    runCommand,
    linuxManualConfig,
    fetchFromGitea,
    fetchpatch,
    mobile-nixos,

    # NixOS' kernel module calls `.override` on whatever it is given, to fold in
    # boot.kernelPatches, boot.kernelParams-driven features and the randstruct
    # seed:
    #
    #   kernel = super.kernel.override (originalArgs: {
    #     inherit randstructSeed;
    #     kernelPatches = (originalArgs.kernelPatches or []) ++ kernelPatches;
    #     features = lib.recursiveUpdate super.kernel.features features;
    #   });
    #
    # callPackage makes `.override` match *this* function's signature, so these
    # have to be accepted and forwarded or any consumer using
    # nixosModules.default fails with "called with unexpected argument
    # 'features'". Defaults match what this kernel provides on its own.
    randstructSeed ? "",
    kernelPatches ? [ ],
    features ? { efiBootStub = true; },
}:
let
    kernelDir = "${mobile-nixos}/devices/pine64-pinephone/kernel";
    baseConfig = "${kernelDir}/config.aarch64";

    # Options added on top of megi's config.
    #
    # megi ships `# CONFIG_EFI is not set`, which suits the extlinux boot
    # postmarketOS uses. A NixOS system booting through Tow-Boot's UEFI into
    # systemd-boot loads the kernel as an EFI application and so needs the stub.
    # On arm64 EFI selects EFI_STUB itself, and the dependencies EFI does have --
    # OF, KERNEL_MODE_NEON, and not CPU_BIG_ENDIAN -- are already met.
    #
    # Harmless if you boot extlinux instead, so it is on by default.
    #
    # Single source of truth: this drives the generated config file, the
    # assertion that the options survived oldconfig, and the evaluation-time
    # `config` below, so the three cannot drift apart.
    injected = {
        CONFIG_EFI = "y";
        CONFIG_EFI_STUB = "y";
    };

    injectedLines = lib.mapAttrsToList (name: value: "${name}=${value}") injected;

    # Matches what nixpkgs' own readConfig does: only `=y` and `=m` lines are
    # parsed, and `# ... is not set` is simply absent, which is what isDisabled
    # leans on. Passed explicitly because `configfile` below is a derivation
    # rather than a path, which would otherwise force import-from-derivation.
    readConfig =
        file:
        lib.listToAttrs (
            lib.concatMap (
                line:
                let
                    m = lib.match "(CONFIG_[^=]+)=([ym])" line;
                in
                lib.optional (m != null) {
                    name = lib.elemAt m 0;
                    value = lib.elemAt m 1;
                }
            ) (lib.splitString "\n" (builtins.readFile file))
        );

    # Kconfig takes the last assignment of a symbol, so appending overrides the
    # earlier `# CONFIG_EFI is not set` without editing megi's file.
    configfile = runCommand "pinephone-kernel-config" { } (
        ''
            cat ${baseConfig} > $out
        ''
        + lib.concatMapStrings (line: ''
            echo '${line}' >> $out
        '') injectedLines
    );

    # Carried from mobile-nixos' device directory and postmarketOS' pmaports.
    devicePatches = [
        {
            name = "pinephone-default-on-and-panic-leds";
            patch = "${kernelDir}/0001-dts-pinephone-Setup-default-on-and-panic-LEDs.patch";
        }
        {
            # Reserves 128MiB of CMA, documented as required for the cameras.
            name = "pinephone-128mib-cma";
            patch = fetchpatch {
                url = "https://github.com/mobile-nixos/linux/commit/372597b5449b7e21ad59dba0842091f4f1ed34b2.patch";
                sha256 = "1lca3fdmx2wglplp47z2d1030bgcidaf1fhbnfvkfwk3fj3grixc";
            };
        }
        {
            # Drops modem-power from the DT so eg25-manager has full control.
            name = "pinephone-drop-modem-power";
            patch = fetchpatch {
                url = "https://gitlab.com/postmarketOS/pmaports/-/raw/164e9f010dcf56642d8e6f422a994b927ae23f38/device/main/linux-postmarketos-allwinner/0007-dts-pinephone-drop-modem-power-node.patch";
                sha256 = "nYCoaYj8CuxbgXfy5q43Xb/ebe5DlJ1Px571y1/+lfQ=";
            };
        }
    ];

    kernel = linuxManualConfig {
        inherit configfile;
        version = "6.17.5";

        src = fetchFromGitea {
            domain = "codeberg.org";
            owner = "megi";
            repo = "linux";
            rev = "orange-pi-6.17-20251026-1441";
            hash = "sha256-SoHvTjmdZb2m3tY5pK60d64d35wc5apOiYzzep3X7wM=";
        };

        config = readConfig baseConfig // injected;

        # `features` carries efiBootStub by default: the systemd-boot module
        # asserts `features ? efiBootStub` and fails with "This kernel does not
        # support the EFI boot stub" otherwise. It is a claim about the kernel
        # rather than a switch, so it has to agree with the CONFIG_EFI injection
        # above, or the assertion is a lie that surfaces at boot instead of at
        # evaluation. Defaulted in the signature so NixOS can recursiveUpdate
        # its own features onto it.
        inherit features randstructSeed;

        # Device patches first, then whatever the importing system added through
        # boot.kernelPatches. `kernelPatches` on the right is the function
        # argument, not this attribute -- the set is not recursive.
        kernelPatches = devicePatches ++ kernelPatches;
    };
in
kernel.overrideAttrs (old: {
    # Regmap debugfs writes, to reach the AXP803's charger registers from
    # userspace. Deliberately not a Kconfig option -- regmap-debugfs.c carries an
    # `#undef` above the guard and a comment saying anyone who wants it must edit
    # the source, singling out PMICs as the reason, so -D on the command line is
    # discarded before it is read. Flipping it to `#define` covers both the write
    # fop and the 0600 mode on `registers`, which is otherwise 0400.
    #
    # Useful for inspecting and testing the AXP803's charger state machine live.
    # replace-fail so the build breaks loudly if that line ever moves.
    postPatch = (old.postPatch or "") + ''
        echo ":: Allowing regmap register writes through debugfs"
        substituteInPlace drivers/base/regmap/regmap-debugfs.c \
            --replace-fail \
                "#undef REGMAP_ALLOW_WRITE_DEBUGFS" \
                "#define REGMAP_ALLOW_WRITE_DEBUGFS"
    '';

    # oldconfig drops options whose dependencies are unmet *silently*, so the
    # result is checked rather than assumed. A wrong guess should cost two
    # minutes here instead of a full kernel build.
    postConfigure = lib.concatMapStrings (opt: ''
        if ! grep -q '^${opt}=${injected.${opt}}$' "$buildRoot/.config"; then
            echo "error: ${opt} did not survive oldconfig"
            exit 1
        fi
    '') (lib.attrNames injected);
})
