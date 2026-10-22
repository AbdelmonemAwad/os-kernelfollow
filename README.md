# Kernel Follower for OPNsense

Rebuilds an out-of-tree FreeBSD kernel module for the kernel an OPNsense update installs, before the reboot, and holds the reboot until it is built - so a driver outside OPNsense's own repository is there on the next boot.

> **Planned - nothing here runs yet.** This repository was opened on 2026-10-22 to hold
> Kernel Follower as a plugin of its own. No code has been written or moved into it, and there is no
> release.

## What it is to do

- the kernel the next boot takes, compared with the stamp beside each module it follows;
- that kernel's sources fetched, or taken from the archive an image carries, and the module built against them;
- a reboot held until the module is built, and the sources of kernels no longer run removed once the new one has settled.

## Where its first code comes from

Its first code is to be os-xgs-npu's kernel follower: `install/kernel-follow.sh`, the source fetcher and its pool, the five-minute cron entry and the upgrade and stop hooks - moved here, and made to serve any out-of-tree module.

## Where it fits

It is one part of the [os-xgs-npu](https://github.com/AbdelmonemAwad/os-xgs-npu) project, which puts OPNsense on Sophos XGS hardware, and works the way its other plugins do: changes by pull request, a release installed from **XGS: Updates**, its Arabic in [opnsense-arabic](https://github.com/AbdelmonemAwad/opnsense-arabic)'s catalogue.

## Licence

BSD 2-Clause - see [LICENSE](LICENSE).
