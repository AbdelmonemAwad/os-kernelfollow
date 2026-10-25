#!/bin/sh
#-
# SPDX-License-Identifier: BSD-2-Clause
# Copyright (c) 2026 Abdelmonem Awad <eg2@live.com>
#
# Remove the Kernel Follower plugin files. Kept: the settings in config.xml; the registrations in
# /usr/local/etc/kernelfollow.d, which belong to the plugins that made them; the modules and their
# stamps, which belong to those plugins too; and the kernel sources in /usr/src-*. The builds go.

# the cron entry first, so no tick starts while the rest goes
rm -f /usr/local/etc/cron.d/kernelfollow
rm -f /usr/local/etc/rc.syshook.d/upgrade/30-kernelfollow
rm -f /usr/local/etc/rc.syshook.d/stop/21-kernelfollow
rm -f /usr/local/opnsense/service/conf/actions.d/actions_kernelfollow.conf
rm -rf /usr/local/opnsense/scripts/kernelfollow
# the menu file place-menu.sh wrote, which is not one of src/'s files
rm -f /usr/local/opnsense/mvc/app/models/OPNsense/KernelFollow/Menu/Menu.xml
rmdir /usr/local/opnsense/mvc/app/models/OPNsense/KernelFollow/Menu 2>/dev/null || true
rm -rf /usr/local/opnsense/mvc/app/models/OPNsense/KernelFollow
rm -rf /usr/local/opnsense/mvc/app/controllers/OPNsense/KernelFollow
rm -rf /usr/local/opnsense/mvc/app/views/OPNsense/KernelFollow
rm -rf /usr/local/share/os-kernelfollow
rm -rf /var/db/os-kernelfollow/build
service configd restart > /dev/null
# PHP keeps them in its own temporary directory on 26.7 (/var/lib/php/tmp); /tmp is where they were
rm -f /var/lib/php/tmp/opnsense_menu_cache.xml /var/lib/php/tmp/opnsense_acl_cache.json \
    /tmp/opnsense_menu_cache.xml /tmp/opnsense_acl_cache.json
echo "Kernel Follower removed"
