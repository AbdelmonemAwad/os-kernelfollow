#!/bin/sh
#-
# SPDX-License-Identifier: BSD-2-Clause
# Copyright (c) 2026 Abdelmonem Awad <eg2@live.com>
#
# Make every out-of-tree kernel module registered here follow the kernel, in the one window where that
# is possible: after an update has put a new kernel on disk and before the host boots it.
#
#	sh follow.sh                  follow the kernel the next boot will use
#	DRY=1 sh follow.sh            say what it would do and change nothing
#	FORCE=1 sh follow.sh          build even when a stamp matches, or when no module is installed yet
#	ONLY=<name> sh follow.sh      one registration, by the name of its file
#	NOFETCH=1 ...                 never download kernel sources; build only from what is here
#	ANYWAY=1 ...                  run although the setting is off - the page's "Follow now"
#	TICK=1 ...                    the five-minute cron run: after a failed fetch, an hour before the
#	                              same sources are fetched again
#
# WHY. A FreeBSD module declares its kernel dependency as a range - from the __FreeBSD_version it was
# compiled with to the end of the branch - so within 15.x `kldload` loads a module built against a
# different 15.x kernel instead of refusing it, and any structure that moved is read at the wrong
# offset. Nothing says so. So a module that is not part of OPNsense has to be rebuilt for every kernel
# an update brings, against that kernel's own sources, and the rebuild has to happen before the boot
# that loads it. Between the update installing the kernel and the reboot, everything needed is there
# at once: the old kernel still running, so the network that fetches the sources is up, and the new
# kernel on disk, naming the commit of its sources. This is that moment, made automatic: it is run by
# the upgrade hook, by the stop hook of every orderly reboot (bounded), and by cron every five minutes.
#
# WHAT IT FOLLOWS. Each file in /usr/local/etc/kernelfollow.d/<name>.conf registers one module,
# KEY=value a line (docs/registering.md):
#
#	MODULE=/boot/modules/<name>.ko        where the module is installed (required)
#	SOURCES=/usr/local/share/<pkg>/<dir>  its Makefile, *.c and *.h, never built in (required)
#	ATTACHED=dev.<driver>.0.%desc         a sysctl that exists once the driver is attached (optional)
#	OWNER=os-<plugin>                     who registered it, for the page (optional)
#	CRITICAL=yes                          the network needs it: when it cannot be built, the next
#	                                      boot is sent to the old kernel it matches (default no)
#
# Beside each module it keeps <module>.kernel, the kernel it was built for, and when it replaces one
# built for another kernel, <module>.prev with its own .prev.kernel - so whatever loads the module can
# refuse a mismatch and fall back to the previous build when the old kernel is booted again.
#
# BESIDE os-xgs-npu. This came from os-xgs-npu's install/kernel-follow.sh on 2026-10-22. That
# follower still runs where os-xgs-npu is installed, for its own two modules (octep.ko, npuep.ko), and
# os-xgs-npu has not been changed. So while it is installed this one leaves those two modules to it,
# never touches nextboot unless it set it itself, and leaves the extracted kernel sources in
# /usr/src-* for it to prune. Two followers building one module into one place would be worse than
# either alone.
#
# WHAT IT WILL NOT DO. It never replaces a working module with one that failed to build, never stamps
# a module it did not just compile, and never fails an update or a reboot: a failure leaves what is
# installed where it was and says so in the log, under kernelfollow.

set -u

# One at a time: cron and a hook can start this in the same minute. A second run waits up to fifteen
# minutes for the first, then finds the stamps right and does nothing.
#
# A DRY run waits for nothing (2026-10-29): it is the page's Check and the installer's last look, it
# changes nothing, and fifteen minutes behind a fetch is longer than the page waits for an answer, so
# the page was left with nothing to show while the Check went on waiting. It says that a run is under
# way - which the page shows too - and ends.
: ${LOCK:=/var/run/kernelfollow.lock}
if [ -z "${KF_LOCKED:-}" ]; then
	KF_LOCKED=1; export KF_LOCKED
	if [ "${DRY:-0}" = 1 ]; then
		/usr/bin/lockf -s -t 0 -k "${LOCK}" /bin/sh "$0" "$@"
		rc=$?
		# 75 is lockf's own EX_TEMPFAIL: somebody holds the lock
		if [ "${rc}" = 75 ]; then
			echo "a run is under way; check again when it has finished"
			exit 0
		fi
		exit "${rc}"
	fi
	exec /usr/bin/lockf -t 900 -k "${LOCK}" /bin/sh "$0" "$@"
fi

: ${PREFIX:=/usr/local}
: ${CONFD:=${PREFIX}/etc/kernelfollow.d}
: ${STATE:=/var/db/os-kernelfollow}
: ${FETCH:=${PREFIX}/opnsense/scripts/kernelfollow/fetch-sources.sh}
: ${SRCPOOL:=${PREFIX}/share/os-kernelfollow/kernel-sources}
: ${SRCROOT:=/usr}
: ${KERNEL:=/boot/kernel/kernel}
: ${KERNEL_OLD:=/boot/kernel.old/kernel}
: ${NEXTBOOT:=/sbin/nextboot}
# The fall-back armed ahead of a rebuild, with the kernel it was armed for (emptied at boot with the
# rest of /var/run)
: ${ARMED:=/var/run/kernelfollow.armed}
: ${WORKPREFIX:=/var/cache/opnsense-update}
: ${PENDINGDIR:=${WORKPREFIX}/.sets.pending}
: ${PENDING_KERNEL:=${WORKPREFIX}/.kernel.pending}
: ${CONF:=/conf/config.xml}
: ${PROJECT:=${PREFIX}/opnsense/scripts/octep/kernel-follow.sh}
: ${SYSCTL:=/sbin/sysctl}
: ${UNAME:=/usr/bin/uname}
: ${DRY:=0}
: ${FORCE:=0}
: ${NOFETCH:=0}
: ${ONLY:=}
: ${ANYWAY:=0}
: ${TICK:=0}

log() {
	echo "$*"
	/usr/bin/logger -t kernelfollow -p daemon.notice "$*" 2>/dev/null || true
}
warn() {
	echo "$*" >&2
	/usr/bin/logger -t kernelfollow -p daemon.err "$*" 2>/dev/null || true
}

# The plugin's settings, by element name, out of its section of config.xml; the model's defaults when
# the page was never saved.
setting() {
	v=$(/usr/bin/sed -n "/<KernelFollow[ >]/,/<\/KernelFollow>/s:.*<$1>\([0-9]*\)</$1>.*:\1:p" "${CONF}" 2>/dev/null | /usr/bin/head -1)
	echo "${v:-$2}"
}
: ${ENABLED:=$(setting enabled 1)}
: ${ALLOWFETCH:=$(setting fetch 1)}
: ${PRUNE:=$(setting prune 1)}
: ${SETTLE:=$(( $(setting settle_hours 24) * 3600 ))}

# One value out of a registration, read as status.py reads it (2026-10-29: the two read a file
# differently, and the page could say "to rebuild" of a file in which this found no MODULE):
# KEY=value, spaces around either side and a carriage return ignored, one pair of quotes around the
# value taken off, a line starting with # skipped, the last line for a key winning.
val() {
	/usr/bin/tr -d '\r' < "$2" |
	    /usr/bin/sed -n -e '/^[[:space:]]*#/d' -e "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" |
	    /usr/bin/tail -1 |
	    /usr/bin/sed -e 's/[[:space:]]*$//' -e "s/^\([\"']\)\(.*\)\1\$/\2/"
}

# Nothing registered is the usual state of a machine this plugin was only installed on: no kernel is
# read, nothing is logged, and cron's tick costs one directory listing.
set -- "${CONFD}"/*.conf
if [ ! -f "$1" ]; then
	exit 0
fi

# NOTHING TO DO IS SAID ONCE, as os-xgs-npu's follower has said it since 2026-10-28. The cron entry
# runs this every five minutes, and with one module registered and matching it logged five Notices
# each time - 1440 in a day - that the module already matched, and one a tick that the plugin was
# switched off. Those lines go to the log once for each boot, and again whenever what they say
# changes - a kernel staged, a module rebuilt, a registration added - and to the screen of whoever
# runs this by hand every time. Anything that is not "nothing to do" is logged as it always was
# (2026-10-29).
: ${SAID:=${STATE}/said}
BOOTED=$(${SYSCTL} -n kern.boottime 2>/dev/null | /usr/bin/sed -n 's/^{ sec = \([0-9]*\),.*/\1/p')
SAYING=
quiet=0
note() { if [ "${quiet}" = 1 ]; then echo "$*"; else log "$*"; fi; }
notew() { if [ "${quiet}" = 1 ]; then echo "$*" >&2; else warn "$*"; fi; }
said() {
	[ "${DRY}" = 1 ] || [ "$(/bin/cat "${SAID}" 2>/dev/null)" = "${SAYING}" ] ||
	    { /bin/mkdir -p "${SAID%/*}" && echo "${SAYING}" > "${SAID}"; } 2>/dev/null
}

if [ "${ENABLED}" != 1 ] && [ "${ANYWAY}" != 1 ] && [ "${DRY}" != 1 ]; then
	SAYING="${BOOTED}|switched off"
	[ "$(/bin/cat "${SAID}" 2>/dev/null)" = "${SAYING}" ] && quiet=1
	note "switched off in the settings; nothing followed"
	said
	exit 0
fi
[ "${ALLOWFETCH}" = 1 ] || NOFETCH=1

# ---------------------------------------------------------------- the kernel to follow

# The kernel the next boot will use, read out of the binary without booting it. At the upgrade hook it
# is still a set waiting in the pending directory (opnsense-update applies it after the hook), so the
# staged set is read first and /boot/kernel second.
version_of_kernel_file() {
	[ -r "$1" ] || return 1
	/usr/bin/strings -a "$1" 2>/dev/null | /usr/bin/grep -m1 -E '^FreeBSD [0-9].*stable/[^ ]+' || return 1
}

kernel_staged() {
	[ -f "${PENDING_KERNEL}" ] || return 1
	for set in "${PENDINGDIR}"/kernel-*.txz; do
		[ -r "${set}" ] || continue
		v=$(/usr/bin/tar -xOf "${set}" boot/kernel/kernel 2>/dev/null | /usr/bin/strings -a 2>/dev/null |
		    /usr/bin/grep -m1 -E '^FreeBSD [0-9].*stable/[^ ]+')
		if [ -n "${v}" ]; then
			echo "${v}"
			return 0
		fi
	done
	return 1
}

TARGET=$(kernel_staged || true)
if [ -n "${TARGET}" ]; then
	WHERE="staged, waiting to be applied"
else
	TARGET=$(version_of_kernel_file "${KERNEL}" || true)
	WHERE="${KERNEL}"
fi
if [ -z "${TARGET}" ]; then
	warn "cannot read a kernel version from a staged set or from ${KERNEL}; nothing to follow"
	exit 0
fi
RUNNING=$(${UNAME} -v)
# the commit of the kernel to follow's sources, as fetch-sources.sh names its tree after it
TSHA=$(printf '%s\n' "${TARGET}" | /usr/bin/sed -n 's/.*-n[0-9]*-\([0-9a-f][0-9a-f]*\).*/\1/p')

# What this run will say, and whether anything is left to do: a module installed and stamped for
# another kernel, or anything at all with FORCE=1. A registration that names no module or no sources
# is said once too - it stays as it is until somebody edits it, and every tick would say the same.
SAYING="${BOOTED}|${TARGET}|${WHERE}|${RUNNING}"
WORK=0
for conf in "${CONFD}"/*.conf; do
	[ -f "${conf}" ] || continue
	name=$(/usr/bin/basename "${conf}" .conf)
	module=$(val MODULE "${conf}")
	src=$(val SOURCES "${conf}")
	stamp=
	[ -z "${module}" ] || stamp=$(/bin/cat "${module}.kernel" 2>/dev/null || true)
	installed=0
	[ -n "${module}" ] && [ -f "${module}" ] && installed=1
	SAYING="${SAYING}|${name}=${module}:${installed}:${stamp}"
	[ -z "${ONLY}" ] || [ "${ONLY}" = "${name}" ] || continue
	[ -n "${module}" ] && [ -n "${src}" ] || continue
	case "$(/usr/bin/basename "${module}")" in
	octep.ko|npuep.ko) [ -f "${PROJECT}" ] && continue ;;
	esac
	[ "${installed}" = 0 ] && [ "${FORCE}" != 1 ] && continue
	[ "${stamp}" = "${TARGET}" ] && [ "${FORCE}" != 1 ] && continue
	WORK=1
done
if [ "${FORCE}" != 1 ] && [ "${WORK}" = 0 ] && [ "$(/bin/cat "${SAID}" 2>/dev/null)" = "${SAYING}" ]; then
	quiet=1
fi

note "kernel to follow: ${TARGET} (${WHERE})"
note "kernel running  : ${RUNNING}"

/bin/mkdir -p "${STATE}/results" "${STATE}/build" 2>/dev/null

# What happened to one module, for the page: KEY=value lines, rewritten at every run.
record() {
	[ "${DRY}" = 1 ] && return 0
	{
		echo "name=$1"
		echo "result=$2"
		echo "message=$3"
		echo "target=${TARGET}"
		echo "at=$(/bin/date +%s)"
	} > "${STATE}/results/$1.new" && /bin/mv "${STATE}/results/$1.new" "${STATE}/results/$1"
}

# ---------------------------------------------------------------- the fall-back for a critical module

# When a module the network needs does not match the new kernel, the next boot is sent to
# /boot/kernel.old - the kernel the installed module was built for - with nextboot(8), which is one
# shot: consumed by the boot it steers. The appliance comes up whole, one kernel behind, and the next
# tick has the network to fetch and build.
#
# HELD UNTIL THE MODULE MATCHES (2026-10-30). Until then it was armed only once a fetch or a build had
# failed, and spent by the boot it steered. os-xgs-npu's follower, which this one came from, did the
# same, and on an XGS 107w (os-xgs-npu issue 890) a reboot while the sources were still downloading
# took the new kernel with the old module: no ports, and no network to repair it from. So it is also
# armed BEFORE a rebuild starts - `pin_old_kernel <stamp> ahead` - and again by the first run of
# every boot until the module matches; unpin_old_kernel() lets go then. Armed ahead, its lines are
# notices, not errors - an ordinary kernel update is not a failure - and its mark is ${ARMED}, so the
# page's warning, which reads ${STATE}/pinned, still means that something failed. Either mark is this
# plugin's own, so this never clears a fall-back somebody else set.
pin_old_kernel() {
	say=warn mark="${STATE}/pinned"
	if [ "${2:-}" = ahead ]; then
		say=log mark="${ARMED}"
	fi
	OLDV=$(version_of_kernel_file "${KERNEL_OLD}" || true)
	if [ -z "${OLDV}" ] || [ "${OLDV}" != "$1" ]; then
		${say} "  the module does not match /boot/kernel.old either; falling back would not help"
		return 1
	fi
	if [ ! -x "${NEXTBOOT}" ]; then
		${say} "  no ${NEXTBOOT}, so the next boot cannot be steered"
		return 1
	fi
	if [ "${DRY}" = 1 ]; then
		log "  DRY=1 - would send the next boot to kernel.old"
		return 0
	fi
	if "${NEXTBOOT}" -k kernel.old > /dev/null 2>&1; then
		echo "${TARGET}" > "${mark}"
		${say} "  the next boot will take /boot/kernel.old, which this module matches"
		[ "${say}" = log ] && log "  until the module is rebuilt for the kernel to follow, which cancels it"
		return 0
	fi
	warn "  ${NEXTBOOT} -k kernel.old failed"
	return 1
}

# ONE FALL-BACK FOR THE WHOLE HOST (2026-10-29). nextboot holds one, and os-xgs-npu's follower sets the
# same - `nextboot -k kernel.old` - for octep.ko and npuep.ko. Clearing it because this plugin's own
# module was rebuilt clears os-xgs-npu's too: at a reboot its stop hook (20) runs before this one (21),
# so an octep.ko it could not rebuild, and sent to kernel.old, would meet the new kernel, and an XGS
# come up with no front ports. While either module is installed and stamped for a kernel other than
# the one to follow, only this plugin's own mark goes, and the fall-back stays.
: ${PROJECT_MODULES:=/boot/modules/octep.ko /boot/modules/npuep.ko}
unpin_old_kernel() {
	[ -f "${STATE}/pinned" ] || [ -f "${ARMED}" ] || return 0
	for m in ${PROJECT_MODULES}; do
		[ -f "${m}" ] || continue
		s=$(/bin/cat "${m}.kernel" 2>/dev/null || true)
		[ "${s}" = "${TARGET}" ] && continue
		if [ "${DRY}" = 1 ]; then
			log "DRY=1 - would leave the fall-back to kernel.old for ${m##*/}, built for ${s:-no kernel}"
			return 0
		fi
		/bin/rm -f "${STATE}/pinned" "${ARMED}"
		log "this plugin needs the fall-back to kernel.old no longer; it stays for ${m##*/}," \
		    "built for ${s:-no kernel}"
		return 0
	done
	[ "${DRY}" = 1 ] && { log "DRY=1 - would cancel the fall-back to kernel.old this plugin set"; return 0; }
	"${NEXTBOOT}" -D > /dev/null 2>&1 || true
	/bin/rm -f "${STATE}/pinned" "${ARMED}"
	log "the fall-back to kernel.old this plugin set is cleared; the next boot takes /boot/kernel"
}

# ---------------------------------------------------------------- the sources, once a run

# AN HOUR BETWEEN FETCHES THAT FAIL, for the five-minute tick (2026-10-29). When a fetch failed - a
# full disk, a download cut short, sources that were not what was expected - the next tick fetched
# the whole tree again, about 350 MB, and so on every five minutes for as long as the cause stayed.
# A failed fetch is kept in ${STATE}/fetch-failed with the commit and the boot it was for, and a tick
# in the same boot, for the same commit, within the hour, builds only from sources already on the
# machine. The upgrade and stop hooks and Follow now always fetch - they are the moments that count -
# and a reboot lets the next tick fetch at once: a host that came up on kernel.old has its network.
FAILED_AT=
held() {
	[ "${TICK}" = 1 ] && [ -f "${STATE}/fetch-failed" ] || return 1
	read -r fsha fat fboot < "${STATE}/fetch-failed" || [ -n "${fsha:-}" ] || return 1
	case "${fat:-}" in ''|*[!0-9]*) return 1 ;; esac
	[ "${fsha}" = "$1" ] && [ "${fboot:-}" = "${BOOTED}" ] &&
	    [ $(( $(/bin/date +%s) - fat )) -lt 3600 ] || return 1
	FAILED_AT=$(/bin/date -r "${fat}" '+%H:%M' 2>/dev/null)
	return 0
}

SYSDIR=
sources() {
	[ -n "${SYSDIR}" ] && return 0
	if [ ! -f "${FETCH}" ]; then
		warn "  no ${FETCH}, so no kernel sources"
		return 1
	fi
	nonet=${NOFETCH}
	if [ "${nonet}" != 1 ] && held "${TSHA}"; then
		nonet=1
		warn "  the sources of ${TSHA} could not be fetched at ${FAILED_AT:-the last try};" \
		    "the five-minute run fetches them again an hour after that - the hooks and Follow now at once"
	fi
	if [ "${nonet}" = 1 ]; then
		FETCHLOG=$(NONET=1 SRCPOOL="${SRCPOOL}" /bin/sh "${FETCH}" "${TARGET}" 2>&1)
	else
		FETCHLOG=$(SRCPOOL="${SRCPOOL}" /bin/sh "${FETCH}" "${TARGET}" 2>&1)
	fi
	SYSDIR=$(echo "${FETCHLOG}" | /usr/bin/sed -n 's/^[[:space:]]*SYSDIR=\([^[:space:]]*\).*/\1/p' | /usr/bin/tail -1)
	if [ -z "${SYSDIR}" ] || [ ! -f "${SYSDIR}/sys/param.h" ]; then
		SYSDIR=
		# kept only where this run was let fetch: one that was held, or told not to, tried nothing new
		[ "${nonet}" = 1 ] || echo "${TSHA} $(/bin/date +%s) ${BOOTED}" > "${STATE}/fetch-failed"
		warn "  could not get kernel sources for ${TARGET}"
		echo "${FETCHLOG}" | /usr/bin/tail -6 | while read -r l; do warn "    ${l}"; done
		return 1
	fi
	/bin/rm -f "${STATE}/fetch-failed"
	log "  building against ${SYSDIR}"
}

# ---------------------------------------------------------------- one module

# From nothing, every time: the build directory is emptied and refilled from the pristine sources, so
# nothing a build for another kernel left behind - kmod.mk's machine link above all, which it never
# re-points - can reach this one. And the build is checked to have compiled every source file, with its
# machine headers from this kernel's tree, because "make exited 0" is not enough (os-xgs-npu learned
# this on 2026-10-02: a module stamped for one kernel, built on another's machine headers).
build() {
	name=$1 module=$2 src=$3
	kmod=$(/usr/bin/basename "${module}" .ko)
	root="${STATE}/build/${name}"
	blog="${STATE}/${name}.build.log"
	if [ ! -f "${src}/Makefile" ]; then
		warn "  no Makefile in ${src}"
		return 1
	fi
	/bin/rm -rf "${root}" && /bin/mkdir -p "${root}" || return 1
	/bin/cp "${src}"/Makefile "${root}/" && /bin/cp "${src}"/*.c "${root}/" 2>/dev/null
	/bin/cp "${src}"/*.h "${root}/" 2>/dev/null
	if ! ( cd "${root}" && /usr/bin/make SYSDIR="${SYSDIR}" ) > "${blog}" 2>&1; then
		warn "  the build failed; the whole log is ${blog}"
		/usr/bin/grep -E ' error:|Error [0-9]' "${blog}" | /usr/bin/head -5 | while read -r l; do warn "    ${l}"; done
		return 1
	fi
	if [ ! -f "${root}/${kmod}.ko" ]; then
		warn "  the build reported success but produced no ${kmod}.ko"
		return 1
	fi
	nsrc=$(/bin/ls "${root}"/*.c | /usr/bin/wc -l | /usr/bin/tr -d ' ')
	nobj=$(/bin/ls "${root}"/*.o 2>/dev/null | /usr/bin/wc -l | /usr/bin/tr -d ' ')
	if [ "${nobj}" -lt "${nsrc}" ]; then
		warn "  only ${nobj} of ${nsrc} sources were compiled; a partial build is not installed"
		return 1
	fi
	mlink=$(/usr/bin/readlink "${root}/machine" 2>/dev/null || true)
	case "${mlink}" in
	"${SYSDIR}"/*) ;;
	*)
		warn "  the machine headers came from ${mlink:-nowhere}, not from ${SYSDIR}; not installed"
		return 1
		;;
	esac
	log "  built $(/usr/bin/stat -f%z "${root}/${kmod}.ko") bytes from ${nsrc} sources"
	return 0
}

install_module() {
	name=$1 module=$2 stamp=$3
	kmod=$(/usr/bin/basename "${module}" .ko)
	# The module being replaced is kept, with its stamp, when it is for another kernel: a host that
	# boots the old kernel again needs it. A rebuild for the same kernel leaves .prev alone.
	if [ -n "${stamp}" ] && [ "${stamp}" != "${TARGET}" ] && [ -f "${module}" ]; then
		/bin/cp -p "${module}" "${module}.prev" 2>/dev/null &&
		    printf '%s\n' "${stamp}" > "${module}.prev.kernel" &&
		    log "  kept the previous module as ${module}.prev, stamped ${stamp}"
	fi
	/bin/mkdir -p "$(/usr/bin/dirname "${module}")"
	if ! /bin/cp "${STATE}/build/${name}/${kmod}.ko" "${module}.new"; then
		warn "  could not write ${module}.new; ${module} is untouched"
		return 1
	fi
	printf '%s\n' "${TARGET}" > "${module}.kernel.new"
	/bin/mv "${module}.new" "${module}"
	/bin/mv "${module}.kernel.new" "${module}.kernel"
	/bin/chmod 0555 "${module}" 2>/dev/null || true
	/bin/chmod 0444 "${module}.kernel" 2>/dev/null || true
	log "  installed ${module}, stamped for the kernel the next boot will use"
}

FAILED=0
ALLMATCH=1
DETACHED=0
# whether this boot has armed the fall-back ahead for this kernel already (see pin_old_kernel)
AHEAD=0
[ "$(/bin/cat "${ARMED}" 2>/dev/null)" = "${TARGET}" ] && AHEAD=1
for conf in "${CONFD}"/*.conf; do
	[ -f "${conf}" ] || continue
	name=$(/usr/bin/basename "${conf}" .conf)
	[ -z "${ONLY}" ] || [ "${ONLY}" = "${name}" ] || continue
	module=$(val MODULE "${conf}")
	src=$(val SOURCES "${conf}")
	critical=$(val CRITICAL "${conf}")
	note "${name}: ${module:-<no MODULE>}"
	if [ -z "${module}" ] || [ -z "${src}" ]; then
		notew "  ${conf} names no MODULE or no SOURCES; skipped"
		record "${name}" failed "the registration names no MODULE or no SOURCES"
		continue
	fi
	case "$(/usr/bin/basename "${module}")" in
	octep.ko|npuep.ko)
		if [ -f "${PROJECT}" ]; then
			note "  followed by os-xgs-npu's own follower here; left to it"
			record "${name}" skipped "followed by os-xgs-npu's own follower"
			continue
		fi
		;;
	esac
	stamp=$(/bin/cat "${module}.kernel" 2>/dev/null || true)
	note "  stamp: ${stamp:-<none>}"
	if [ ! -f "${module}" ] && [ "${FORCE}" != 1 ]; then
		note "  not installed; nothing to follow"
		record "${name}" skipped "not installed"
		continue
	fi
	if [ "${stamp}" = "${TARGET}" ] && [ "${FORCE}" != 1 ]; then
		note "  matches the kernel to follow"
		record "${name}" ok "matches the kernel to follow"
		attached=$(val ATTACHED "${conf}")
		if [ -n "${attached}" ] && [ -z "$(${SYSCTL} -n "${attached}" 2>/dev/null)" ]; then
			DETACHED=1
		fi
		continue
	fi
	ALLMATCH=0
	if [ "${DRY}" = 1 ]; then
		log "  DRY=1 - would rebuild it for the kernel to follow"
		continue
	fi
	# The fall-back first, before a fetch that can take long - for an installed module built for
	# another kernel, not a first build or a FORCE=1 one for the same kernel; and only once the kernel
	# to follow is in /boot: while it is a set still staged, kernel.old is the kernel before the one
	# running.
	if [ "${critical}" = yes ] && [ "${AHEAD}" = 0 ] && [ "${WHERE}" = "${KERNEL}" ] &&
	    [ -f "${module}" ] && [ "${stamp}" != "${TARGET}" ]; then
		pin_old_kernel "${stamp}" ahead && AHEAD=1
	fi
	if sources && build "${name}" "${module}" "${src}" && install_module "${name}" "${module}" "${stamp}"; then
		record "${name}" built "rebuilt for the kernel to follow"
		continue
	fi
	FAILED=1
	warn "  ${module} is untouched and still matches ${stamp:-<nothing>}"
	if [ "${critical}" = yes ]; then
		pin_old_kernel "${stamp}" || warn "  the next boot will load a module built for another kernel, or none"
	fi
	record "${name}" failed "could not be rebuilt for the kernel to follow; see ${STATE}/${name}.build.log"
done

if [ "${FAILED}" = 0 ]; then
	# Everything matches the kernel on disk now, so a fall-back this plugin set is no longer needed -
	# only once the kernel to follow is /boot/kernel itself, not a set still waiting.
	[ "${WHERE}" = "${KERNEL}" ] && unpin_old_kernel
fi

# ---------------------------------------------------------------- the sources of kernels gone by

# Once the new kernel has proven itself - it is the one running, every module followed matches it and
# is attached where its registration names a sysctl, and the boot is SETTLE old (a day by default; the
# owner's condition for os-xgs-npu, 2026-10-21) - the sources of other kernels go: this plugin's pool
# always, the extracted trees in /usr/src-* only where os-xgs-npu is not installed (its follower prunes
# them by the same rule there). The running kernel's own sources always stay.
prune() {
	[ "${PRUNE}" = 1 ] && [ "${DRY}" != 1 ] && [ "${FAILED}" = 0 ] && [ "${ALLMATCH}" = 1 ] &&
	    [ "${DETACHED}" = 0 ] || return 0
	[ "${RUNNING}" = "${TARGET}" ] || return 0
	booted=$(${SYSCTL} -n kern.boottime 2>/dev/null | /usr/bin/sed -n 's/^{ sec = \([0-9]*\),.*/\1/p')
	[ -n "${booted}" ] && [ $(( $(/bin/date +%s) - booted )) -ge "${SETTLE}" ] || return 0
	keep=$(printf '%s\n' "${TARGET}" | /usr/bin/sed -n 's/.*-n[0-9]*-\([0-9a-f][0-9a-f]*\).*/\1/p')
	[ -n "${keep}" ] || return 0
	for archive in "${SRCPOOL}"/*.tar.gz "${SRCPOOL}"/*.tgz; do
		[ -f "${archive}" ] || continue
		case "${archive##*/}" in *"${keep}"*) continue ;; esac
		/bin/rm -f "${archive}" && log "removed ${archive}: an archive of a kernel no longer run"
	done
	[ -f "${PROJECT}" ] && return 0
	for tree in "${SRCROOT}"/src-*-*; do
		printf '%s\n' "${tree##*/}" | /usr/bin/grep -Eq '^src-[0-9][0-9.]*-[0-9a-f]{7,40}$' || continue
		[ -f "${tree}/sys/sys/param.h" ] || continue
		case "${tree}" in *"-${keep}") continue ;; esac
		/bin/rm -rf "${tree}" && log "removed ${tree}: the sources of a kernel this host no longer runs"
	done
	# A tree half written, under a name the loop above does not take: what a fetch killed before its
	# trap could run leaves (2026-10-29). An hour old at least, so that a fetch started by hand a
	# minute ago keeps its own.
	for part in "${SRCROOT}"/src-*-*.partial; do
		[ -d "${part}" ] || continue
		printf '%s\n' "${part##*/}" | /usr/bin/grep -Eq '^src-[0-9][0-9.]*-[0-9a-f]{7,40}\.partial$' || continue
		[ -n "$(/usr/bin/find "${part}" -maxdepth 0 -mmin +60 2>/dev/null)" ] || continue
		/bin/rm -rf "${part}" && log "removed ${part}: a tree a fetch left half written"
	done
}
prune

[ "${WORK}" = 1 ] || said
[ "${DRY}" = 1 ] && note "DRY=1 - nothing changed"
exit "${FAILED}"
