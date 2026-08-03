# PinePhone kernel for NixOS

[![Build kernel and publish binary cache](https://github.com/BeatLink/PinePhoneKernel/actions/workflows/build.yml/badge.svg)](https://github.com/BeatLink/PinePhoneKernel/actions/workflows/build.yml)

[megi&#39;s kernel](https://codeberg.org/megi/linux) — the tree postmarketOS ships —
packaged as a NixOS flake, with a **public binary cache** so you do not spend
several hours building aarch64.

> **If your PinePhone will not charge under NixOS, this is almost certainly why.**
> It is a kernel bug, not a dead battery. See
> [why mainline cannot charge a PinePhone](#why-mainline-cannot-charge-a-pinephone).

There is no megi or mobile-nixos kernel in `cache.nixos.org`, and mobile-nixos
publishes none, so every PinePhone NixOS user currently rebuilds a kernel that is
bit-identical for all of them.

## Is this for you?

|                                                                |                                                                         |
| -------------------------------------------------------------- | ----------------------------------------------------------------------- |
| **PinePhone** (Allwinner A64) — revisions 1.0, 1.1, 1.2 | supported                                                               |
| **PinePhone Pro** (Rockchip RK3399)                      | **no** — different SoC, different kernel entirely                |
| PineTab / other Allwinner devices                              | untested; the kernel supports them, this packaging does not target them |

You want this if you run NixOS on the phone itself. If you run postmarketOS,
Mobian or Arch ARM, you already have this kernel and need nothing here.

## What you get over mainline

Mainline boots on a PinePhone, but several things do not work:

|                                                      | Mainline                       | This                     |
| ---------------------------------------------------- | ------------------------------ | ------------------------ |
| **Charging**                                   | **broken above ~14 °C** | works                    |
| WiFi (RTL8723CS)                                     | no driver                      | `CONFIG_RTL8723CS`     |
| USB-C role switching, USB-PD, DisplayPort alt mode   | no ANX7688 driver | `CONFIG_TYPEC_ANX7688`, `CONFIG_TYPEC_DP_ALTMODE` |
| Keyboard case (keys and its battery) | —                             | `CONFIG_KEYBOARD_PINEPHONE`, `CONFIG_IP5XXX_POWER` |
| PinePhone device trees, incl. the keyboard accessory | partial                        | complete                 |

### Why mainline cannot charge a PinePhone

The PinePhone's battery uses a **3 kΩ NTC** thermistor. The AXP803 PMIC powers up
with its over-temperature threshold (`REG 39H`) at `0x1F`, a value tuned for a
**10 kΩ** NTC, and mainline never reprograms it — `axp20x_battery`'s only
temperature handling lives in `axp717_set_battery_info()`, for a different PMIC.

So a perfectly healthy pack at ordinary room temperature reads as *over
temperature*, and the charger refuses. The threshold works out to about **14 °C**:
below that mainline charges, above it never does.

It presents exactly like a dead battery:

```
status         Charging        # claims to be charging
current_now    5000            # 5 mA, and never rises
voltage_now    2902000         # stuck, for hours
capacity       0               # gauge cannot characterise the pack
```

Every symptom points at a failed cell, and the obvious next step is to buy a new
battery, which changes nothing.

megi's tree sets the threshold to 960 Ω, guarded on
`of_machine_is_compatible("pine64,pinephone-1.2")`. On the same phone, with the
same battery, that is the difference between 5 mA and **1.3 A**.

> A quick way to confirm this without installing anything: boot a postmarketOS
> image from an SD card. It ships the same kernel. If it charges there, your
> hardware is fine.

## AI assistance

This repository was developed with AI assistance. The Nix packaging, the CI
workflow and this README were written by **Claude Opus 5** (Anthropic), working
with the repository author.

Stated up front, before the installation instructions, because AI-generated
contributions are divisive in free software and because what follows asks you to
add a binary cache to your system. You should be able to factor that in before
doing either.

**No kernel code here is AI-written.** The kernel is
[megi&#39;s tree](https://codeberg.org/megi/linux), unmodified apart from the
changes documented under [what is on top](#what-is-on-top-of-megis-tree): six
appended config options, and flipping one `#undef` to `#define` in
`regmap-debugfs.c`. All are listed in full with reasons. What was
AI-written is the Nix expression that fetches, configures and builds it, and the
prose you are reading.

## Quick start

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    pinephone-kernel.url = "github:BeatLink/PinePhoneKernel";
  };

  outputs = { nixpkgs, pinephone-kernel, ... }: {
    nixosConfigurations.myphone = nixpkgs.lib.nixosSystem {
      system = "aarch64-linux";
      modules = [
        pinephone-kernel.nixosModules.default      # the kernel
        pinephone-kernel.nixosModules.binaryCache  # optional, see below
        ./configuration.nix
      ];
    };
  };
}
```

> **Do not set `inputs.pinephone-kernel.inputs.nixpkgs.follows`.** Overriding
> nixpkgs changes the stdenv, which changes the derivation, which means the cache
> misses and you build a kernel for hours. A kernel built from a slightly
> different nixpkgs than your userland is fine — they do not need to match.

### Check it worked

```sh
uname -r                                  # 6.17.5
dmesg | grep -i "thermal regulation"      # Configuring battery thermal regulation for Pinephone
cat /sys/class/power_supply/axp20x-battery/current_now
```

That last one should read hundreds of thousands of µA on a charger, not single-digit
thousands.

## The binary cache

`nixosModules.binaryCache` configures it for you. It is a separate module so that
importing a kernel never silently adds a substituter to your system. By hand:

```nix
nix.settings = {
  extra-substituters = [ "https://beatlink.github.io/PinePhoneKernel" ];
  extra-trusted-public-keys = [
    "pinephone-kernel-1:Bh9JYKdNDBNwefy+ZrjHKjVUR453bPDXRMZ+kO9K33w="
  ];
};
```

Two limitations, both deliberate:

- **Latest revision only.** Each publish replaces the site, which keeps it inside
  GitHub Pages' size limit. Pin an older revision of this flake and you build it
  yourself.
- **Out-of-tree modules are not cached.** ZFS and friends are built by
  `linuxPackagesFor` against *your* nixpkgs, so only the kernel comes from the
  cache. That is still the great majority of the build time.

Everything published is signed, and CI is the only thing holding the private key.

## Build it yourself

```sh
nix build github:BeatLink/PinePhoneKernel#linux-pinephone-megi
```

Expect several hours on anything that is not a fast native aarch64 machine.
`overlays.default` builds it against your own nixpkgs instead, which gives up the
cache but keeps everything on one nixpkgs revision.

## What is on top of megi's tree

Three patches carried from mobile-nixos' device directory — default-on and panic
LEDs, 128 MiB of CMA for the cameras, and dropping `modem-power` from the DT so
`eg25-manager` has full control.

Six config options are appended to megi's config. Kconfig takes the last
assignment of a symbol, so these override without editing anyone's file, and
each is asserted after `oldconfig` — which drops options with unmet dependencies
*silently*, so an unchecked injection yields a kernel that quietly lacks what
was asked for:

| Option | Why |
| --- | --- |
| `CONFIG_EFI`, `CONFIG_EFI_STUB` | megi ships EFI off, suiting the extlinux boot postmarketOS uses. Booting through Tow-Boot's UEFI into systemd-boot loads the kernel as an EFI application and needs the stub. Harmless under extlinux. |
| `CONFIG_AUTOFS_FS` | systemd's initrd puts `autofs` in `availableKernelModules`, and `makeModulesClosure` runs with `allowMissing = false`, so the build dies outright without it |
| `CONFIG_DMIID` | `/sys/class/dmi/id`; on arm64 DMI comes from EFI, so it is only reachable because of the above |
| `CONFIG_KEYBOARD_PINEPHONE` | megi's tree carries the driver **and** the DT node for the keyboard case, but the config leaves the driver off — the hardware is fully described and nothing binds to it |
| `CONFIG_TYPEC_DP_ALTMODE` | ANX7688 registers the Type-C port, but the DisplayPort alt mode driver is a separate option and was off, so alt mode had nothing to negotiate with |

`AUTOFS_FS` and `DMIID` are precisely the entries left unmet when NixOS'
`system.requiredKernelConfig` is checked against megi's config — NixOS
expectations rather than PinePhone ones, which is why a config aimed at
postmarketOS has no reason to carry them.

One source change on top of that:

- **Regmap debugfs writes.** `regmap-debugfs.c` carries an `#undef` above its
  guard and a comment saying anyone who wants it must edit the source, so `-D` on
  the command line is discarded before it is read. Flipped to `#define`, which
  makes `/sys/kernel/debug/regmap/sunxi-rsb-3a3/registers` writable and the
  AXP803's charger state machine inspectable live.

Built with nixpkgs' `linuxManualConfig` rather than mobile-nixos'
`kernel-builder`, which deletes the kernel build tree in its `postInstall` and
exposes no `dev` output — fine for a phone with everything built in, fatal if you
want ZFS or any other out-of-tree module.

## Contributing

Issues and pull requests welcome, particularly:

- Kernel version bumps as megi's tree moves
- Reports from PinePhone 1.0 and 1.1, which are untested here
- Anything that lets a config option be dropped because mainline gained it

Please note that the two local changes above are deliberately minimal. Things that
belong upstream should go to [megi](https://codeberg.org/megi/linux) or
[mobile-nixos](https://github.com/NixOS/mobile-nixos) rather than accumulating
here.

## Maintainer notes

<details>
<summary>Cache signing and CI setup</summary>

The cache is signed. The keypair was generated once with:

```sh
nix-store --generate-binary-cache-key \
    pinephone-kernel-1 cache-priv-key.pem cache-pub-key.pem
```

- private half → repository secret `CACHE_PRIV_KEY`
- public half → `README.md`, `flake.nix` (`nixosModules.binaryCache`) and
  `.github/workflows/build.yml` (`extra-trusted-public-keys`); all three must
  match or signature verification fails confusingly at the consumer

Pages must be set to **GitHub Actions** as its source. Never commit
`cache-priv-key.pem`; `.gitignore` covers it.

CI builds on `ubuntu-24.04-arm` — free and native aarch64 for public
repositories — and rebuilds weekly so the cache survives nixpkgs moving
underneath it. The workflow lists this cache as one of its own substituters, so
an unchanged derivation is fetched rather than rebuilt.

</details>

## Licence

**GPL-2.0-only**, matching the kernel this packages. Full text in
[LICENSE](LICENSE).

Two pieces of this repository come from elsewhere and keep their own terms, both
permissive and both GPL-compatible, so they can be carried here without
conflicting:

- `readConfig` in [kernel.nix](kernel.nix) mirrors the same function in nixpkgs'
  `pkgs/os-specific/linux/kernel/build.nix` — **MIT**, the NixOS contributors.
- The kernel config and the LED and CMA patches come from mobile-nixos'
  `devices/pine64-pinephone` — **MIT**, Samuel Dionne-Riel and the Mobile NixOS
  contributors.

The patches themselves are kernel source and are GPL-2.0 regardless of the
repository carrying them.

## Credits

Essentially none of the engineering here is original. This repository is a thin
Nix wrapper around other people's work.

### megi — Ondřej Jirman

[xnux.eu](https://xnux.eu/) · [codeberg.org/megi/linux](https://codeberg.org/megi/linux)

The kernel itself, and by a wide margin the largest reason a PinePhone is usable
at all. The tree packaged here carries the ANX7688 USB-C driver, the RTL8723CS
WiFi driver, the IP5xxx keyboard-case battery driver and the PinePhone device
trees — none of which exist in mainline. Years of sustained work on hardware most
people had written off.

The charging fix this README opens with is theirs too. A few lines in
`axp20x_battery.c` reprogram the AXP803's thermal thresholds for the PinePhone's
3 kΩ NTC, with the resistance curve spelled out in a comment:

```c
// 3kOhm NTC inside PinePhone batery
// 15 - 50 °C: Max 0.5C CC to 4.35V : 4710 Ohm - 1080 Ohm
```

That comment is the only statement of this battery's thermistor value found
anywhere while investigating it — not in the schematic, not in the datasheet, not
in any documentation. Without it, a PinePhone that will not charge presents
exactly as a dead cell, and the obvious action is to replace a perfectly healthy
battery. A few lines of code comment saved a pack, and the diagnosis in this
README is entirely downstream of having read it.

Their [PinePhone notes](https://xnux.eu/devices/pine64-pinephone.html) are the best reference on this hardware that exists.

### mobile-nixos

[github.com/NixOS/mobile-nixos](https://github.com/NixOS/mobile-nixos) · started by [Samuel Dionne-Riel](https://samueldr.com/)

The device directory this builds from — kernel config, the default-on/panic LED
patch, the CMA patch, and the firmware list. The config in particular represents a
great deal of accumulated knowledge about what this SoC needs.

### postmarketOS

[postmarketos.org](https://postmarketos.org/) · [pmaports](https://gitlab.com/postmarketOS/pmaports)

The `modem-power` device tree patch is taken directly from pmaports, and their
packaging of megi's tree is the reference for how this hardware is meant to be
run. Booting their image is also the fastest way to prove a charging problem is
software rather than hardware.

### Pine64

[pine64.org For publishing the ](https://pine64.org/)[schematics](<https://files.pine64.org/doc/PinePhone/PinePhone%20v1.2%20Released%20Schematic.pdf>) and the [AXP803 datasheet](https://files.pine64.org/doc/datasheet/pine64/AXP803_Datasheet_V1.0.pdf).
Working out the charging behaviour meant reading the PMIC register map for the
TS-pin thresholds, then checking schematic page 06 to confirm the battery
thermistor was genuinely wired to that pin rather than substituted by a fixed
resistor. For almost any other phone, neither document is public.

### nixpkgs and linux-sunxi

[nixpkgs](https://github.com/NixOS/nixpkgs) supplies `linuxManualConfig` and the
kernel build infrastructure that does the real work here.
[linux-sunxi](https://linux-sunxi.org/) documents the AXP803 and the RSB bus.

### Upstream Linux

The kernel is the work of thousands of people. megi's tree is a fork of it, and
the drivers above are written against interfaces the wider community maintains.
