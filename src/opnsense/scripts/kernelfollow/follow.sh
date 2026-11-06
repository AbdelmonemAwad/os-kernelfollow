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
#	PINONLY=1 sh follow.sh        only send the next boot to kernel.old, for a module the network
#	                              needs that is built for it and not for /boot/kernel - or, where
#	                              none needs it, cancel the one this plugin set; no lock, no fetch,
#	                              no build - the stop hook runs this first
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
#
# PINONLY=1 takes no lock at all (2026-11-06): it has to arm the fall-back to kernel.old while another
# run holds this one, and it writes no module ("the fall-back alone, at a reboot", below).
: ${LOCK:=/var/run/kernelfollow.lock}
: ${PINONLY:=0}
if [ -z "${KF_LOCKED:-}" ] && [ "${PINONLY}" != 1 ]; then
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
# The fall-back armed ahead of a rebuild, with the kernel it was armed for and the boot it was armed
# in (/var/run is emptied at boot as well; the boot is kept so that this does not depend on it)
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
# read, nothing is logged, and cron's tick costs one directory listing. PINONLY=1 answers 3 then,
# nothing needs the fall-back: its 0 would say that it armed it ("the fall-back alone", below).
set -- "${CONFD}"/*.conf
if [ ! -f "$1" ]; then
	[ "${PINONLY}" = 1 ] && exit 3
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
# PINONLY=1 logs what it arms, or why it cannot, and no more: the run after it says the rest, once
[ "${PINONLY}" = 1 ] && quiet=1
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
	# Nor armed: PINONLY=1 answers 1, not a 0 that would say it was, and leaves said() alone,
	# which would keep a line it did not log from the run after it.
	[ "${PINONLY}" = 1 ] && exit 1
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

# The release a kernel's version names, and its major number: 15.1-RELEASE-p6 and 15 in
# "FreeBSD 15.1-RELEASE-p6 stable/26.7-n284176-c962f76493b6 SMP".
release_of() {
	printf '%s\n' "$1" | /usr/bin/sed -n 's/^FreeBSD \([^ ]*\).*/\1/p'
}
major_of() {
	printf '%s\n' "$1" | /usr/bin/sed -n 's/^FreeBSD \([0-9][0-9]*\).*/\1/p'
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
	[ "${PINONLY}" = 1 ] && exit 1
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
# armed BEFORE the rebuilds start - `pin_old_kernel <stamp> ahead`, before the loop over the modules -
# and again by the first run of every boot until every module the network needs matches;
# unpin_old_kernel() lets go then. And since 2026-11-06 at every orderly reboot, by the stop hook,
# first and without the lock ("the fall-back alone, at a reboot", below). Armed ahead, its lines are
# notices, not errors - an ordinary kernel update is not a failure - and its mark is ${ARMED}, so the
# page's warning, which reads ${STATE}/pinned, still means that something failed. Either mark is this
# plugin's own, so this never clears a fall-back somebody else set.
pin_old_kernel() {
	say=warn mark="${STATE}/pinned" what="${TARGET}"
	if [ "${2:-}" = ahead ]; then
		say=log mark="${ARMED}" what="${TARGET}|${BOOTED}"
	fi
	# the kernel in /boot now: the one to follow, or with a set still staged the one it replaces
	BOOTV=${TARGET}
	[ "${WHERE}" = "${KERNEL}" ] || BOOTV=$(version_of_kernel_file "${KERNEL}" || true)
	# A KERNEL STILL STAGED is applied before the reboot that follows, and from then on the
	# kernel in /boot now is kernel.old: that is the one a boot can fall back to, and the stop
	# hook arms it at that reboot (PINONLY=1, below). Nothing is armed here, where kernel.old is
	# still the one before. Until 2026-11-06 this judged that one - two kernels back from the
	# staged one - and a rebuild that failed at the upgrade hook said that falling back would not
	# help and that the next boot would load a module built for another kernel, where the stop
	# hook sends that boot to kernel.old, which the module is built for. A module built for
	# neither is judged as before, as os-xgs-npu's follower judges it since the same day. Nor is
	# the stop hook said to send it there across a major release, which it does not (below).
	if [ "${WHERE}" != "${KERNEL}" ] && [ -n "$1" ] && [ "${BOOTV}" = "$1" ]; then
		across_major "once the staged kernel is applied, /boot/kernel.old" "$1" "${TARGET}" && return 1
		if [ ! -x "${NEXTBOOT}" ]; then
			${say} "  no ${NEXTBOOT}, so the next boot cannot be steered"
			return 1
		fi
		${say} "  once the staged kernel is applied, /boot/kernel.old is the one this module is built for"
		${say} "  and the stop hook sends the next boot to it at the reboot that follows"
		return 0
	fi
	OLDV=$(version_of_kernel_file "${KERNEL_OLD}" || true)
	if [ -z "${OLDV}" ] || [ "${OLDV}" != "$1" ]; then
		${say} "  the module does not match /boot/kernel.old either; falling back would not help"
		return 1
	fi
	across_major /boot/kernel.old "${OLDV}" "${BOOTV}" "${TARGET}" && return 1
	if [ ! -x "${NEXTBOOT}" ]; then
		${say} "  no ${NEXTBOOT}, so the next boot cannot be steered"
		return 1
	fi
	if [ "${DRY}" = 1 ]; then
		log "  DRY=1 - would send the next boot to kernel.old"
		return 0
	fi
	if "${NEXTBOOT}" -k kernel.old > /dev/null 2>&1; then
		echo "${what}" > "${mark}"
		${say} "  the next boot will take /boot/kernel.old, which this module matches"
		[ "${say}" = log ] && log "  until the module is rebuilt for the kernel to follow, which cancels it"
		return 0
	fi
	warn "  ${NEXTBOOT} -k kernel.old failed"
	return 1
}

# NOT ACROSS A MAJOR RELEASE (2026-11-06). A major upgrade of OPNsense is one of FreeBSD as well -
# 26.1 to 26.7 is 14.3 to 15.1 - and after it /boot/kernel.old is the old release's kernel, while
# /boot/kernel and the userland the upgrade installs are the new one's. FreeBSD supports an older
# userland on a newer kernel, not a newer userland on an older one, so a boot sent to kernel.old
# then trades the module the network needs for a system it does not support. Until 2026-11-06
# nothing here compared the two: 1.0.2 armed it wherever a run reached the fall-back with the module
# still built for the old release, and the stop hook's first look, new that day, would have armed it
# at every orderly reboot of the upgrade. So pin_old_kernel() arms it only where the kernel it would
# boot is of the same major release as the one in /boot and, with a set still staged, as the kernel
# to follow, and otherwise says why not and answers as where falling back would not help.
# os-xgs-npu's follower sets the same fall-back for its own two modules by its own judgement, and
# this one leaves that to it (ONE FALL-BACK FOR THE WHOLE HOST, below).
#
# across_major <the name of the kernel a fall-back would boot> <its version> <version>...: true, and
# said, where one of the versions after it is of another major release; one that cannot be read is
# passed over.
across_major() {
	aw=$1 av=$2
	shift 2
	for v in "$@"; do
		[ -z "${v}" ] || [ "$(major_of "${v}")" = "$(major_of "${av}")" ] && continue
		${say} "  ${aw} is FreeBSD $(release_of "${av}"), of another major release than FreeBSD" \
		    "$(release_of "${v}"); the next boot is not sent to it"
		return 0
	done
	return 1
}

# ONE FALL-BACK FOR THE WHOLE HOST (2026-10-29). nextboot holds one, and os-xgs-npu's follower sets the
# same - `nextboot -k kernel.old` - for octep.ko and npuep.ko. Clearing it because this plugin's own
# module was rebuilt clears os-xgs-npu's too: at a reboot its stop hook (20) runs before this one (21),
# so an octep.ko it could not rebuild, and sent to kernel.old, would meet the new kernel, and an XGS
# come up with no front ports. While either module is installed and stamped for a kernel other than
# the one to follow, only this plugin's own mark goes, and the fall-back stays.
#
# The other way round is not covered (found in review, 2026-10-30): os-xgs-npu's follower clears
# nextboot when it has rebuilt its own module, whoever armed it. Where a module registered here with
# CRITICAL=yes is still being rebuilt at that moment, its fall-back goes with it, and the mark here
# still says armed, so it is armed again only at the next boot - or, since 2026-11-06, at an orderly
# reboot before it, where the stop hook's PINONLY=1 arms it whatever the mark says, after os-xgs-npu's
# stop hook has run. No published plugin registers such a module beside os-xgs-npu.
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

# Whether the kernel to follow is the one in /boot: read from there, or from a staged set that the
# update has applied since this run read it. Until 2026-11-06 only the first counted, and a run that
# began while a major upgrade's kernel was still a staged set - a five-minute run's - and rebuilt the
# module the network needs after the set was applied never let the fall-back go, which the stop hook
# arms at the reboot, without the lock, while that run goes on: the next boot would take kernel.old
# with the module rebuilt for /boot/kernel.
in_boot() {
	[ "${WHERE}" = "${KERNEL}" ] || [ "$(version_of_kernel_file "${KERNEL}" || true)" = "${TARGET}" ]
}

# Whether every installed module the network needs matches the kernel to follow - read from the
# stamps as they are now, whatever this run built, failed, or was told to leave alone with ONLY=. The
# fall-back is let go on this alone (2026-10-30, found in review): it waited for the whole run to
# succeed, so a module the network does not need, failing, held the host one kernel behind, and a run
# for ONLY one module let go of the fall-back another still needed.
#
# A registration with no SOURCES is passed over, here and where the fall-back is armed, as the loop
# passes it over: it can never be rebuilt, so a fall-back armed for it would never be let go, and the
# host would take kernel.old at every boot with nothing on the page to say why (found in review).
critical_match() {
	for cc in "${CONFD}"/*.conf; do
		[ -f "${cc}" ] && [ "$(val CRITICAL "${cc}")" = yes ] || continue
		cm=$(val MODULE "${cc}")
		[ -n "${cm}" ] && [ -f "${cm}" ] && [ -n "$(val SOURCES "${cc}")" ] || continue
		case "${cm##*/}" in
		octep.ko|npuep.ko) [ -f "${PROJECT}" ] && continue ;;
		esac
		[ "$(/bin/cat "${cm}.kernel" 2>/dev/null)" = "${TARGET}" ] || return 1
	done
	return 0
}

# The fall-back for the modules the network needs, chosen as critical_match() chooses them: armed
# once, by the first of them that is built for another kernel than ${TARGET} and that kernel.old
# matches. The loop that armed it ahead of the rebuilds until 2026-11-06 (below), shared since with
# PINONLY=1, whose answer its status is: 0 armed, 3 none of them needs it, 1 one does and it could
# not be armed.
fall_back() {
	fb=3
	for conf in "${CONFD}"/*.conf; do
		[ -f "${conf}" ] && [ "$(val CRITICAL "${conf}")" = yes ] || continue
		module=$(val MODULE "${conf}")
		[ -n "${module}" ] && [ -f "${module}" ] && [ -n "$(val SOURCES "${conf}")" ] || continue
		case "${module##*/}" in
		octep.ko|npuep.ko) [ -f "${PROJECT}" ] && continue ;;
		esac
		stamp=$(/bin/cat "${module}.kernel" 2>/dev/null || true)
		[ "${stamp}" = "${TARGET}" ] && continue
		log "$(/usr/bin/basename "${conf}" .conf): the network needs it, and it is built for another kernel"
		pin_old_kernel "${stamp}" ahead && return 0
		fb=1
	done
	return "${fb}"
}

# ---------------------------------------------------------------- the fall-back alone, at a reboot

# PINONLY=1 arms the fall-back, or lets go of the one this plugin set where nothing needs it, and does
# nothing else: no lock, no sources, no build, no record for the page. The stop hook runs it at every
# orderly reboot, before a whole run and after one cut off, and says what it answers.
#
# Until 2026-11-06 only the run holding the lock could arm it, and only one that found the kernel to
# follow already in /boot ("the fall-back, ahead of the rebuilds", below). A major upgrade over a slow
# line fell between the two: a run that started while the kernel was still a staged set - a
# five-minute run's, in the middle of the upgrade - arms nothing, and it could still be fetching
# sources at the reboot. The stop hook's run waited for its lock until the time limit cut it off,
# before it reached the fall-back, and the next boot took the new kernel with a module built for the
# old one.
#
# No lock, because nothing here needs one: it writes no module, and what it changes - nextboot and
# ${ARMED} - pin_old_kernel() changes only for a module built for kernel.old, and unpin_old_kernel()
# only where every module the network needs is built for /boot/kernel, the finding on which a run
# holding the lock lets it go too. If that run installs a rebuilt module and lets the fall-back go
# just as this arms it, the next boot takes kernel.old with the module rebuilt for /boot/kernel, and
# the one it replaced kept beside it as .prev, with its stamp, for whatever loads the module to take
# instead (docs/registering.md): one kernel behind, as the fall-back always is.
#
# Where modules are registered and none of them needs it, a fall-back this plugin set goes
# (2026-11-06), as unpin_old_kernel() lets it go - never os-xgs-npu's. Until then it stayed where the
# module had been rebuilt by a run that did not let it go, or just as this armed it, and the stop
# hook could say that every module the network needs was built for /boot/kernel of a next boot that
# took kernel.old.
#
# /boot/kernel and not a staged set, because the question is what the loader boots: with a kernel
# still staged, /boot/kernel is the one running and kernel.old the one before it. And armed whatever
# ${ARMED} says: os-xgs-npu's stop hook (20) runs before this one (21), and its follower clears
# nextboot once it has rebuilt its own module, whoever armed it (ONE FALL-BACK FOR THE WHOLE HOST).
#
# The answer is the exit status, so that the stop hook says only what is so: 0 the next boot is sent
# to kernel.old; 3 nothing needs it - every module the network needs that this plugin follows is
# built for /boot/kernel, or none is registered; 1 one is not, and the next boot could not be sent to
# kernel.old, for the reason in the lines before - or /boot/kernel cannot be read, or the plugin is
# switched off in its settings. 3 and not 2 since 2026-11-06: sh exits with 2 on an error of its
# own - a variable that is not set, under set -u, or a syntax error - and the stop hook read such an
# error as every module the network needs built for /boot/kernel.
if [ "${PINONLY}" = 1 ]; then
	TARGET=$(version_of_kernel_file "${KERNEL}" || true)
	WHERE="${KERNEL}"
	if [ -z "${TARGET}" ]; then
		warn "cannot read a kernel version from ${KERNEL}, so the next boot is left as it is"
		exit 1
	fi
	fall_back
	fb=$?
	[ "${fb}" = 3 ] && unpin_old_kernel
	exit "${fb}"
fi

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

# ---------------------------------------------------------------- the fall-back, ahead of the rebuilds

# Before the loop, because the sources are fetched once a run, for whichever module needs them first
# (2026-10-30, found in review: armed inside the loop, a module the network needs that sorted after
# one it does not was armed only after that one's fetch). Every module the network needs counts, ONLY=
# or not: one that does not match the kernel on disk wants the fall-back whatever this run was asked
# to build. Installed modules only - a first build has no kernel to fall back to - and only once the
# kernel to follow is in /boot: while it is a set still staged, kernel.old is the kernel before the
# one running. Once a boot, for the kernel to follow; never on a DRY run. A run that started while
# the kernel was still staged never arms it here, and it can still hold the lock at the reboot, so the
# stop hook arms it first, without the lock ("the fall-back alone, at a reboot", above). fall_back()
# is the loop that was here.
if [ "${DRY}" != 1 ] && [ "${WHERE}" = "${KERNEL}" ] &&
    [ "$(/bin/cat "${ARMED}" 2>/dev/null)" != "${TARGET}|${BOOTED}" ]; then
	fall_back || true
fi

FAILED=0
ALLMATCH=1
DETACHED=0
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
	if sources && build "${name}" "${module}" "${src}" && install_module "${name}" "${module}" "${stamp}"; then
		record "${name}" built "rebuilt for the kernel to follow"
		# The fall-back goes as soon as the last module the network needs matches, not after the
		# rest of the run: a time limit reached in a later module's build would otherwise keep it.
		# Once the kernel it was built for is the one in /boot (in_boot, 2026-11-06).
		if [ "${critical}" = yes ] && in_boot && critical_match; then
			unpin_old_kernel
		fi
		continue
	fi
	FAILED=1
	warn "  ${module} is untouched and still matches ${stamp:-<nothing>}"
	if [ "${critical}" = yes ]; then
		pin_old_kernel "${stamp}" || warn "  the next boot will load a module built for another kernel, or none"
	fi
	record "${name}" failed "could not be rebuilt for the kernel to follow; see ${STATE}/${name}.build.log"
done

# Every module the network needs matches the kernel on disk now, so a fall-back this plugin set is no
# longer needed - only once the kernel to follow is /boot/kernel itself, not a set still waiting:
# read from /boot, or since 2026-11-06 a staged set the update has applied during the run (in_boot).
# Decided by those modules alone (critical_match) since 2026-10-30; a DRY run, which builds nothing,
# still says what a run that succeeds would do.
if in_boot; then
	if [ "${DRY}" = 1 ]; then
		[ "${FAILED}" = 0 ] && unpin_old_kernel
	elif critical_match; then
		unpin_old_kernel
	fi
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
