#!/bin/sh
#-
# SPDX-License-Identifier: BSD-2-Clause
# Copyright (c) 2026 Abdelmonem Awad <eg2@live.com>
#
# Fetch the kernel sources that match THIS running kernel, or the kernel named, and print the SYSDIR
# to build against.
#
#	sh fetch-sources.sh                              the running kernel's
#	sh fetch-sources.sh "FreeBSD 15.1-RELEASE-p1 stable/26.7-n283674-12334a596709 SMP"
#
# follow.sh runs it with the kernel the next boot will use and reads the SYSDIR= line it ends with.
# It came from os-xgs-npu (contrib/npuep/fetch-sources.sh) on 2026-10-22; what follows is that
# file's account of why it is shaped as it is, written about the appliance it was made for - an XGS
# whose WAN is one of the ports the module drives - and true of any module a network needs.
#
# Why this exists at all. An out-of-tree kernel module is compiled against headers, and the
# headers have to be the ones the running kernel was built from. OPNsense does not ship kernel
# sources and there is no package that provides them, so for a long time this appliance simply
# had a 333MB /usr/src/sys that somebody had copied there once - no version recorded, no
# provenance, not a package and not a checkout. It built, so nobody asked.
#
# It was the wrong tree. It was stock FreeBSD 15.1-RELEASE, BRANCH="RELEASE", while the kernel
# is OPNsense's own build of 15.1-RELEASE-p1 from github.com/opnsense/src. The trees differ in
# 156 files. That the module worked anyway was luck, and it was only confirmed as luck by
# fetching the right tree and rebuilding: __FreeBSD_version is 1501000 in both, none of the 156
# files is in a path this driver includes, and the two builds came out BYTE-IDENTICAL. Good
# news, and not a reason to keep guessing - the next kernel is not obliged to be so kind.
#
# The kernel names its own commit. `uname -v` on this board reads
#
#	FreeBSD 15.1-RELEASE-p1 stable/26.7-n283674-12334a596709 SMP
#
# and the last field of that middle token is the git commit in opnsense/src. So the sources can
# always be pinned to exactly what is running, with no version file to keep up to date.
#
# ORDER MATTERS AFTER AN UPDATE, and on an appliance whose WAN is one of the coprocessor's own
# ports it matters more than it looks.
#
# `uname -v` reports the RUNNING kernel. Pin to it after the reboot and the sources are right;
# pin to it before, and they are the old ones, perfectly and uselessly.
#
# But on this appliance the obvious order - update, reboot, fetch, build - has a circle in it. A
# new kernel means the stamped module is refused, which means no oxp interfaces, which means no
# WAN, which means this script cannot reach codeload to fetch anything. The twelve ports that
# need the module are also the only way to the internet that would rebuild it.
#
# So the version can be given instead of read. After the update has installed the new kernel and
# BEFORE the reboot, the new kernel is already on disk and says what it is:
#
#     strings -a /boot/kernel/kernel | grep -m1 "^FreeBSD 1.*stable/"
#
# Pass that to this script while the old WAN is still alive, build against it, install the module
# with the new stamp, and then reboot once. Everything comes up together.
#
#     sh fetch-sources.sh "FreeBSD 15.1-RELEASE-p1 stable/26.7-n283674-12334a596709 SMP"

# The version to pin to: the first argument if one is given, otherwise the running kernel.
KVER=${1:-$(uname -v)}

SYS_ID=$(echo "${KVER}" | awk '{for (i = 1; i <= NF; i++) if ($i ~ /^stable\//) print $i}')
if [ -z "${SYS_ID}" ]; then
	echo "cannot find a source revision in: ${KVER}" >&2
	echo "this does not look like an OPNsense kernel; build against /usr/src/sys." >&2
	exit 1
fi

SHA=${SYS_ID##*-}
BRANCH=${SYS_ID%%-*}			# e.g. stable/26.7
SERIES=${BRANCH#stable/}
DST=${DST:-/usr/src-${SERIES}-${SHA}}
URL="https://codeload.github.com/opnsense/src/tar.gz/${SHA}"
# Where a carried copy of the sources is looked for before the network is touched: this plugin's
# pool, then os-xgs-npu's, where an image carries its kernel's archive (it may be installed beside).
SRCPOOL=${SRCPOOL:-/usr/local/share/os-kernelfollow/kernel-sources}
SRCPOOL2=${SRCPOOL2:-/usr/local/share/os-xgs-npu/kernel-sources}

echo "kernel         : ${KVER}"
if [ -n "${1:-}" ]; then echo "                 (given, not the running one)"; fi
echo "source commit  : ${SHA} on ${BRANCH}"
echo "destination    : ${DST}"

if [ -d "${DST}/sys" ]; then
	echo "already there - nothing to fetch."
	echo
	echo "SYSDIR=${DST}/sys"
	exit 0
fi

# NO TREE HALF WRITTEN IS LEFT BEHIND (2026-10-29). The tree is unpacked into ${DST}.partial and
# renamed once it is whole; a run ended by a signal - the stop hook gives follow.sh ten minutes, and
# timeout(1) ends it with SIGTERM - left the .partial where it was, up to 330 MB under /usr that the
# page never showed and nothing removed once the kernel had moved on.
PARTIAL=
cleanup() { [ -z "${PARTIAL}" ] || rm -rf "${PARTIAL}"; }
trap cleanup EXIT
trap 'exit 1' INT TERM HUP

# ROOM FIRST (2026-10-29). The tree is about 330 MB of sys/, under /usr, on the file system that holds
# the rest of OPNsense, and nothing looked before writing it: a full disk failed the extraction half
# way, and the next five-minute tick downloaded the whole tree again. ROOM_MB free is asked of the
# file system the tree goes to - enough for the tree and as much again for everything else - before
# anything is unpacked or fetched.
: ${ROOM_MB:=800}
ROOM_KB=$(df -Pk "$(dirname "${DST}")" 2>/dev/null | awk 'NR == 2 {print $4}')
if [ -n "${ROOM_KB}" ] && [ "${ROOM_KB}" -lt $((ROOM_MB * 1024)) ]; then
	echo "only $((ROOM_KB / 1024)) MB free in $(dirname "${DST}"), and the sources need ${ROOM_MB} MB:" \
	    "nothing fetched or unpacked." >&2
	exit 1
fi

# A COPY ALREADY ON THE APPLIANCE COMES FIRST, because on this appliance the network is downstream
# of the thing being built. The WAN is one of the coprocessor's front ports, so it exists only while
# the module matches the running kernel: a fresh install has no internet until the driver is built,
# and the driver cannot be built without the sources. That circle is broken by carrying them.
#
# Anything matching ${SRCPOOL}/*<sha>*.tar.gz is used instead of the network - the codeload tarball
# saved as it comes, under any name that has the commit in it. SRCPOOL defaults to a directory this
# plugin owns, and install.sh copies into it what the checkout carries in kernel-sources/, so a
# repository copied onto the appliance with the sources beside it needs no internet at all.
for a in "${SRCPOOL}"/*"${SHA}"*.tar.gz "${SRCPOOL}"/*"${SHA}"*.tgz \
    "${SRCPOOL2}"/*"${SHA}"*.tar.gz "${SRCPOOL2}"/*"${SHA}"*.tgz; do
	[ -f "${a}" ] || continue
	echo
	echo "using the copy already here: ${a}"
	PARTIAL="${DST}.partial"
	rm -rf "${DST}.partial"
	mkdir -p "${DST}.partial"
	if ! tar -xzf "${a}" -C "${DST}.partial" --strip-components=1 '*/sys/*'; then
		rm -rf "${DST}.partial"
		echo "that archive would not extract; falling through to the network." >&2
		break
	fi
	if [ ! -f "${DST}.partial/sys/sys/param.h" ]; then
		rm -rf "${DST}.partial"
		echo "that archive has no sys/sys/param.h; falling through to the network." >&2
		break
	fi
	mv "${DST}.partial" "${DST}"
	PARTIAL=
	echo "unpacked $(du -sh "${DST}" | awk '{print $1}'), nothing fetched"
	echo
	echo "SYSDIR=${DST}/sys"
	exit 0
done

# Past this point is the network, and NONET=1 forbids it. The installer sets it: a first install
# must not start a 350 MB download nobody asked for, but it may use anything already on the machine,
# which is what the two paths above are.
if [ "${NONET:-0}" = "1" ]; then
	echo "no sources for ${SHA} here, and NONET=1 forbids fetching them." >&2
	echo "put the codeload tarball in ${SRCPOOL} (any name with ${SHA} in it), or unset NONET." >&2
	exit 1
fi

# Only sys/ is extracted. The whole tarball still has to come down the wire - codeload has no way
# to ask for a subtree - but a module build needs nothing else: bsd.kmod.mk and the rest of the
# angle-bracket makefiles live in /usr/share/mk, which belongs to the base system and is already
# present and already the right version.
echo
echo "fetching (the whole tree comes down, only sys/ is written)..."
PARTIAL="${DST}.partial"
rm -rf "${DST}.partial"
mkdir -p "${DST}.partial"
if ! fetch -o - "${URL}" | tar -xz -C "${DST}.partial" --strip-components=1 '*/sys/*'; then
	rm -rf "${DST}.partial"
	echo "fetch or extract failed. Is ${SHA} reachable at ${URL} ?" >&2
	exit 1
fi

if [ ! -f "${DST}.partial/sys/sys/param.h" ]; then
	rm -rf "${DST}.partial"
	echo "extracted, but there is no sys/sys/param.h - the archive is not what was expected." >&2
	exit 1
fi
mv "${DST}.partial" "${DST}"
PARTIAL=

echo
echo "fetched $(du -sh "${DST}" | awk '{print $1}')"
echo "  tree says      : $(awk -F'"' '/^REVISION=/{r=$2} /^BRANCH=/{b=$2} END{print r "-" b}' "${DST}/sys/conf/newvers.sh")"
echo "  __FreeBSD_version: $(awk '/^#define[ \t]+__FreeBSD_version/{print $3}' "${DST}/sys/sys/param.h")"
echo "  running kernel   : $(sysctl -n kern.osreldate)"
echo
echo "Now build against it, with the SYSDIR below."

# AT COLUMN ZERO, AND THAT IS THE WHOLE POINT OF THIS LINE.
#
# follow.sh runs this script, captures its output and picks the tree out of it with
# `sed -n 's/^SYSDIR=//p'`. The already-there path above prints that line bare; this path used to
# print it only as part of the indented hint "  SYSDIR=... sh contrib/npuep/build.sh", which the
# anchored pattern does not match. So on the one path that matters - a kernel the appliance has
# never built for, which is every real update - the follower fetched 341 MB, verified the tree, and
# then said "could not get kernel sources" and left the module unbuilt. Found on 2026-10-02 by
# taking the sources away and rebooting: the hook did its work and the front ports still did not
# come up.
echo "SYSDIR=${DST}/sys"
