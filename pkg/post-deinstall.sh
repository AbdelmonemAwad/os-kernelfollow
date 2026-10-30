#!/bin/sh
# Copyright (C) 2026 Abdelmonem Awad <eg2@live.com>. BSD 2-Clause License.
#
# Run by pkg(8) after the files of os-kernelfollow have been removed; not during an upgrade. pkg has
# removed the cron entry and the hooks with the rest. What is left is the entry this plugin made in
# config.xml, the GUI's caches, and the builds.

if [ -x /usr/local/opnsense/scripts/firmware/register.php ]; then
	/usr/local/opnsense/scripts/firmware/register.php remove os-kernelfollow > /dev/null 2>&1 || true
fi

if [ -f /usr/local/etc/rc.d/configd ]; then
	/usr/local/etc/rc.d/configd restart
fi

if [ -f /usr/local/etc/rc.configure_plugins ]; then
	echo "Reloading plugin configuration"
	/usr/local/etc/rc.configure_plugins POST_DEINSTALL
fi

# The menu file place-menu.sh wrote is not one of the package's files, so pkg left it, and the
# model's directory with it. The menu is cached by PHP in /var/lib/php/tmp on 26.7, in /tmp before.
rm -f /usr/local/opnsense/mvc/app/models/OPNsense/KernelFollow/Menu/Menu.xml
rmdir /usr/local/opnsense/mvc/app/models/OPNsense/KernelFollow/Menu /usr/local/opnsense/mvc/app/models/OPNsense/KernelFollow 2>/dev/null || true
rm -f /var/lib/php/tmp/opnsense_menu_cache.xml /tmp/opnsense_menu_cache.xml

rm -rf /var/db/os-kernelfollow/build

# What pkg never knew of, so never removes (2026-10-29): /usr/local/share/os-kernelfollow - where the
# self-update keeps what it installed and its output, a package install that took a self-update having
# run install/install.sh outside pkg, and the pool of carried archives, which install/uninstall.sh
# has always removed - and the compiled Python that install.sh's syntax check leaves beside the
# scripts. Without it the scripts' directory is empty, and goes too. Only this plugin's own paths.
rm -rf /usr/local/share/os-kernelfollow /usr/local/opnsense/scripts/kernelfollow/__pycache__
rmdir /usr/local/opnsense/scripts/kernelfollow/i18n/ui /usr/local/opnsense/scripts/kernelfollow/i18n \
    /usr/local/opnsense/scripts/kernelfollow/menu /usr/local/opnsense/scripts/kernelfollow 2>/dev/null || true

# Kept on purpose: the settings in config.xml; /usr/local/etc/kernelfollow.d and the modules it names,
# which belong to the plugins that registered them; and the kernel sources in /usr/src-*.
echo "Kernel Follower removed; the settings and the registrations are kept"
