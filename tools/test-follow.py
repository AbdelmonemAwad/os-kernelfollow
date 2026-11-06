#!/usr/bin/env python3
#-
# SPDX-License-Identifier: BSD-2-Clause
# Copyright (c) 2026 Abdelmonem Awad <eg2@live.com>
#
"""follow.sh and the stop hook away from a firewall: a made-up /boot, kernelfollow.d and state in a
temporary directory, through the variables follow.sh already reads, with nextboot, sysctl, uname and the
fetcher stand-ins there, and lockf, logger, make and stat stand-ins in copies of the two scripts. lockf
is util-linux flock(1), so a lock another process holds is held, as on a firewall.

What PINONLY=1 arms, and answers, while another run holds the lock; what a rebuild that fails says of
the fall-back to kernel.old while the new kernel is still a staged set; and the stop hook at a reboot
after a kernel update - the fall-back armed while another run holds the lock, armed again where it was
cleared during the wait, and kernel.old said only where it is armed (2026-11-06; until then the stop
hook said it whether anything had armed it or not).

    python3 tools/test-follow.py
"""
import fcntl
import os
import signal
import subprocess
import tarfile
import tempfile
import time
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
FOLLOW = os.path.join(HERE, '..', 'src', 'opnsense', 'scripts', 'kernelfollow', 'follow.sh')
STOP = os.path.join(HERE, '..', 'src', 'etc', 'rc.syshook.d', 'stop', '21-kernelfollow')

# After an update: NEXT in /boot/kernel, the kernel the next boot takes; OLD the one running, now in
# /boot/kernel.old; OLDER the one before both.
NEXT = 'FreeBSD 15.1-RELEASE-p6 stable/26.7-n284176-c962f76493b6 SMP'
OLD = 'FreeBSD 15.1-RELEASE-p4 stable/26.7-n284159-abbbe67a45e7 SMP'
OLDER = 'FreeBSD 15.1-RELEASE-p2 stable/26.7-n284102-0f1e2d3c4b5a SMP'
BOOTED = '1762400000'

# Everything follow.sh and the hook take from the environment: none of it is inherited from the one
# the test runs in.
THEIRS = ('LOCK', 'PINONLY', 'KF_LOCKED', 'PREFIX', 'CONFD', 'STATE', 'FETCH', 'SRCPOOL', 'SRCROOT',
          'KERNEL', 'KERNEL_OLD', 'NEXTBOOT', 'ARMED', 'WORKPREFIX', 'PENDINGDIR', 'PENDING_KERNEL',
          'CONF', 'PROJECT', 'PROJECT_MODULES', 'SYSCTL', 'UNAME', 'DRY', 'FORCE', 'NOFETCH', 'ONLY',
          'ANYWAY', 'TICK', 'ENABLED', 'ALLOWFETCH', 'PRUNE', 'SETTLE', 'SAID', 'FOLLOW', 'LIMIT')


class Follower(unittest.TestCase):
    """A host after a kernel update and before its reboot, in a temporary directory."""

    def setUp(self):
        tmp = tempfile.TemporaryDirectory(prefix='kernelfollow-test-')
        self.addCleanup(tmp.cleanup)
        self.dir = tmp.name
        for d in ('boot/kernel', 'boot/kernel.old', 'boot/modules', 'confd', 'state', 'share', 'run'):
            os.makedirs(self.path(d))
        self.kernel('boot/kernel/kernel', NEXT)
        self.kernel('boot/kernel.old/kernel', OLD)
        # lockf [-s] [-t seconds] [-k] file command..., as follow.sh gives it: 75 when it waited its
        # seconds out, as lockf answers
        self.lockf = self.stub('lockf', self.record('lockf.calls') +
                               'while :; do\n\tcase $1 in\n\t-k|-s) shift ;;\n\t-t) t=$2; shift 2 ;;\n'
                               '\t*) break ;;\n\tesac\ndone\nf=$1; shift\n'
                               'exec flock -E 75 ${t:+-w "$t"} "$f" "$@"')
        self.logger = self.stub('logger', self.record('log'))
        # the one setting nextboot(8) holds for the next boot, as /boot/nextboot.conf holds it
        conf = self.path('nextboot.conf')
        self.nextboot = self.stub('nextboot', self.record('nextboot.calls') +
                                  'case $1 in\n-k) echo "kernel=\\"$2\\"" > \'%s\' ;;\n'
                                  '-D) rm -f \'%s\' ;;\nesac' % (conf, conf))
        self.sysctl = self.stub('sysctl', 'case "$*" in\n*kern.boottime*) echo "{ sec = %s, usec = 0 }" ;;\n'
                                          '*) exit 1 ;;\nesac' % BOOTED)
        self.uname = self.stub('uname', 'echo "%s"' % OLD)
        # a module's Makefile names its KMOD, and SLOW the seconds its build takes
        self.make = self.stub('make', self.record('make.calls') +
                              'for a; do case $a in SYSDIR=*) sysdir=${a#SYSDIR=} ;; esac; done\n'
                              'kmod=$(sed -n "s/^KMOD=//p" Makefile)\nslow=$(sed -n "s/^SLOW=//p" Makefile)\n'
                              '[ -z "${slow}" ] || sleep "${slow}"\n'
                              'for c in *.c; do : > "${c%.c}.o"; done\n'
                              'echo "${kmod}" > "${kmod}.ko"\nln -s "${sysdir}/amd64/include" machine')
        self.stat = self.stub('stat', 'for a; do f=$a; done\nwc -c < "$f" | tr -d " "')
        self.fetch(works=False)
        self.copies = {}

    # ---------------------------------------------------------------- the made-up host

    def path(self, name):
        return os.path.join(self.dir, name)

    def write(self, name, text):
        os.makedirs(os.path.dirname(self.path(name)), exist_ok=True)
        with open(self.path(name), 'w', encoding='utf-8', newline='\n') as f:
            f.write(text)

    def read(self, name):
        try:
            with open(self.path(name), encoding='utf-8') as f:
                return f.read()
        except FileNotFoundError:
            return ''

    def lines(self, name):
        return self.read(name).splitlines()

    def kernel(self, name, version):
        """a kernel binary as strings(1) reads it"""
        self.write(name, '\0\0' + version + '\n\0')

    def record(self, into):
        return "printf '%%s\\n' \"$*\" >> '%s'\n" % self.path(into)

    def stub(self, name, body):
        self.write('bin/' + name, '#!/bin/sh\n%s\n' % body)
        os.chmod(self.path('bin/' + name), 0o755)
        return self.path('bin/' + name)

    def fetch(self, works):
        """fetch-sources.sh: the sources of the kernel it is given, or none"""
        tree = self.path('usr/src-26.7-c962f76493b6')
        if works:
            self.write(tree + '/sys/sys/param.h', '/* made up */\n')
            self.stub('fetch-sources.sh', self.record('fetch.calls') + 'echo "SYSDIR=%s/sys"' % tree)
        else:
            self.stub('fetch-sources.sh', self.record('fetch.calls') +
                      'echo "no sources for $1 here, and nothing to fetch them from"; exit 1')

    def register(self, name, stamp, critical=True, sources=True, slow=0):
        """kernelfollow.d/<name>.conf, its sources, and its module installed and stamped - not
        installed where stamp is None"""
        module = self.path('boot/modules/%s.ko' % name)
        src = self.path('share/' + name)
        self.write(src + '/Makefile',
                   'KMOD=%s\nSRCS=%s.c\n' % (name, name) + ('SLOW=%d\n' % slow if slow else ''))
        self.write(src + '/%s.c' % name, '/* %s */\n' % name)
        conf = ['MODULE=' + module] + (['SOURCES=' + src] if sources else [])
        conf.append('CRITICAL=' + ('yes' if critical else 'no'))
        self.write('confd/%s.conf' % name, '\n'.join(conf) + '\n')
        if stamp is not None:
            self.write(module, 'ELF %s\n' % name)
            self.write(module + '.kernel', stamp + '\n')

    def hold_lock(self):
        """follow.sh's lock, held by another process - this one - until the test ends"""
        fd = os.open(self.path('run/kernelfollow.lock'), os.O_RDWR | os.O_CREAT, 0o644)
        fcntl.flock(fd, fcntl.LOCK_EX)
        self.addCleanup(os.close, fd)

    # ---------------------------------------------------------------- the scripts

    def copy(self, source, name):
        """source with each command of a fixed path replaced by its stand-in"""
        if name not in self.copies:
            with open(source, encoding='utf-8') as f:
                text = f.read()
            for command, stand_in in (('/usr/bin/lockf', self.lockf), ('/usr/bin/logger', self.logger),
                                      ('/usr/bin/make', self.make), ('/usr/bin/stat', self.stat)):
                text = text.replace(command, stand_in)
            self.write(name, text)
            self.copies[name] = self.path(name)
        return self.copies[name]

    def env(self, **more):
        env = {k: v for k, v in os.environ.items() if k not in THEIRS}
        env.update(PREFIX=self.path('local'), CONFD=self.path('confd'), STATE=self.path('state'),
                   LOCK=self.path('run/kernelfollow.lock'), ARMED=self.path('run/kernelfollow.armed'),
                   KERNEL=self.path('boot/kernel/kernel'), KERNEL_OLD=self.path('boot/kernel.old/kernel'),
                   NEXTBOOT=self.nextboot, SYSCTL=self.sysctl, UNAME=self.uname,
                   FETCH=self.path('bin/fetch-sources.sh'), SRCPOOL=self.path('share/kernel-sources'),
                   SRCROOT=self.path('usr'), WORKPREFIX=self.path('update'), CONF=self.path('config.xml'),
                   PROJECT=self.path('octep/kernel-follow.sh'),
                   PROJECT_MODULES=' '.join(self.path('boot/modules/%s.ko' % m) for m in ('octep', 'npuep')))
        env.update(more)
        return env

    def run_in_session(self, argv, env, seconds, meanwhile=None):
        """(exit status, what it printed, seconds taken); the status None where it had not ended in
        the seconds given, and everything it started killed then. meanwhile() is what another process
        does while it runs."""
        start = time.monotonic()
        p = subprocess.Popen(argv, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
                             start_new_session=True)
        if meanwhile:
            meanwhile()
        try:
            out, _ = p.communicate(timeout=seconds)
            rc = p.returncode
        except subprocess.TimeoutExpired:
            os.killpg(p.pid, signal.SIGKILL)
            out, _ = p.communicate()
            rc = None
        return rc, out, time.monotonic() - start

    def follow(self, seconds=30, **more):
        return self.run_in_session(['/bin/sh', self.copy(FOLLOW, 'follow.sh')], self.env(**more), seconds)

    def stop(self, limit, meanwhile=None):
        hook = self.copy(STOP, 'stop-21-kernelfollow')
        env = self.env(FOLLOW=self.copy(FOLLOW, 'follow.sh'), LIMIT=str(limit))
        return self.run_in_session(['/bin/sh', hook], env, limit + 60, meanwhile)

    def armed(self):
        """whether the next boot is sent to kernel.old"""
        return self.read('nextboot.conf') == 'kernel="kernel.old"\n'


class PinOnly(Follower):
    """PINONLY=1, as the stop hook runs it first: the next boot sent to kernel.old for a module the
    network needs that is built for kernel.old and not for /boot/kernel - and no lock, no fetch, no
    build, nothing recorded for the page."""

    def pin_only(self, seconds=20):
        return self.follow(PINONLY='1', seconds=seconds)

    def assertDidNothingElse(self):
        self.assertEqual(self.lines('lockf.calls'), [], 'it went for the lock')
        self.assertEqual(self.lines('fetch.calls'), [], 'it fetched sources')
        self.assertEqual(self.lines('make.calls'), [], 'it built a module')
        results = self.path('state/results')
        self.assertEqual(os.listdir(results) if os.path.isdir(results) else [], [], 'it recorded a result')

    def test_a_module_built_for_kernel_old_sends_the_next_boot_there(self):
        self.register('net', OLD)
        rc, out, _ = self.pin_only()
        self.assertEqual(rc, 0, out)
        self.assertEqual(self.lines('nextboot.calls'), ['-k kernel.old'])
        self.assertTrue(self.armed())
        # its mark is the one a run arms ahead of its rebuild with: a precaution, not a failure
        self.assertEqual(self.read('run/kernelfollow.armed'), '%s|%s\n' % (NEXT, BOOTED))
        self.assertFalse(os.path.exists(self.path('state/pinned')))
        self.assertIn('-p daemon.notice   the next boot will take /boot/kernel.old, which this module '
                      'matches', self.read('log'))
        self.assertDidNothingElse()

    def test_a_module_built_for_the_next_kernel_needs_nothing_and_says_nothing(self):
        self.register('net', NEXT)
        rc, out, _ = self.pin_only()
        self.assertEqual(rc, 2, out)
        self.assertEqual(self.lines('nextboot.calls'), [])
        self.assertFalse(os.path.exists(self.path('run/kernelfollow.armed')))
        self.assertEqual(self.read('log'), '')
        self.assertDidNothingElse()

    def test_it_waits_for_no_lock_another_process_holds(self):
        self.register('net', OLD)
        self.hold_lock()
        rc, out, _ = self.pin_only(seconds=10)
        self.assertIsNotNone(rc, 'still waiting for the lock after 10s')
        self.assertEqual(rc, 0, out)
        self.assertTrue(self.armed())
        self.assertDidNothingElse()

    def test_a_module_built_for_neither_kernel_arms_nothing(self):
        self.register('net', OLDER)
        rc, out, _ = self.pin_only()
        self.assertEqual(rc, 1, out)
        self.assertEqual(self.lines('nextboot.calls'), [])
        self.assertIn('the module does not match /boot/kernel.old either', self.read('log'))
        self.assertDidNothingElse()

    def test_armed_once_by_the_first_module_kernel_old_matches(self):
        self.register('a-net', OLDER)
        self.register('b-net', OLD)
        self.register('c-net', OLD)
        rc, out, _ = self.pin_only()
        self.assertEqual(rc, 0, out)
        self.assertEqual(self.lines('nextboot.calls'), ['-k kernel.old'])
        self.assertDidNothingElse()

    def test_armed_again_although_its_mark_says_it_is(self):
        # os-xgs-npu's follower clears nextboot once it has rebuilt its own module, whoever armed it,
        # and its stop hook runs before this one: the mark says armed, nextboot holds nothing
        self.register('net', OLD)
        self.write('run/kernelfollow.armed', '%s|%s\n' % (NEXT, BOOTED))
        rc, out, _ = self.pin_only()
        self.assertEqual(rc, 0, out)
        self.assertTrue(self.armed())
        self.assertDidNothingElse()

    def test_only_the_modules_the_network_needs_count_as_a_run_counts_them(self):
        self.register('extra', OLD, critical=False)
        self.register('broken', OLD, sources=False)
        self.register('absent', None)
        self.write('octep/kernel-follow.sh', '# os-xgs-npu is installed: octep.ko is left to it\n')
        self.register('octep', OLD)
        rc, out, _ = self.pin_only()
        self.assertEqual(rc, 2, out)
        self.assertEqual(self.lines('nextboot.calls'), [])
        self.assertDidNothingElse()

    def test_nothing_registered_needs_nothing(self):
        rc, out, _ = self.pin_only()
        self.assertEqual(rc, 2, out)
        self.assertDidNothingElse()

    def test_switched_off_arms_nothing_and_does_not_say_it_needed_nothing(self):
        self.register('net', OLD)
        self.write('config.xml', '<opnsense>\n  <OPNsense>\n    <KernelFollow>\n      <general>\n'
                                 '        <enabled>0</enabled>\n      </general>\n    </KernelFollow>\n'
                                 '  </OPNsense>\n</opnsense>\n')
        rc, out, _ = self.pin_only()
        self.assertEqual(rc, 1, out)
        self.assertEqual(self.lines('nextboot.calls'), [])
        self.assertDidNothingElse()


class WholeRun(Follower):
    """A whole run, the lock free."""

    def stage(self, version):
        """the kernel an update has fetched and not applied yet, as opnsense-update leaves it"""
        self.kernel('staged-kernel', version)
        os.makedirs(self.path('update/.sets.pending'))
        with tarfile.open(self.path('update/.sets.pending/kernel-26.7-amd64.txz'), 'w:xz') as t:
            t.add(self.path('staged-kernel'), arcname='boot/kernel/kernel')
        self.write('update/.kernel.pending', '26.7\n')

    def test_it_still_arms_the_fall_back_ahead_of_its_rebuild(self):
        self.register('net', OLD)
        rc, out, _ = self.follow()
        self.assertEqual(rc, 1, out)
        self.assertIn('net: the network needs it, and it is built for another kernel', self.read('log'))
        # ahead of the fetch, and again when the rebuild had failed
        self.assertEqual(self.lines('nextboot.calls'), ['-k kernel.old', '-k kernel.old'])
        self.assertEqual(self.read('run/kernelfollow.armed'), '%s|%s\n' % (NEXT, BOOTED))
        self.assertEqual(self.read('state/pinned'), NEXT + '\n')

    def test_a_failed_rebuild_with_the_kernel_staged_is_left_to_the_reboot(self):
        # the kernel in /boot is the one running and becomes kernel.old once the update applies NEXT;
        # kernel.old now is the one before it
        self.kernel('boot/kernel/kernel', OLD)
        self.kernel('boot/kernel.old/kernel', OLDER)
        self.stage(NEXT)
        self.register('net', OLD)
        rc, out, _ = self.follow()
        log = self.read('log')
        self.assertEqual(rc, 1, out)
        self.assertIn('could not get kernel sources for ' + NEXT, log)
        self.assertIn('once the staged kernel is applied, /boot/kernel.old is the one this module is '
                      'built for', log)
        self.assertIn('the stop hook sends the next boot to it at the reboot that follows', log)
        self.assertEqual(self.lines('nextboot.calls'), [], 'armed while kernel.old is still the one before')
        self.assertNotIn('falling back would not help', log)
        self.assertNotIn('will load a module built for another kernel', log)


class AtShutdown(Follower):
    """The stop hook at the reboot after a kernel update."""

    def hook_line(self):
        """the stop hook's own line in the log, where follow.sh's are too"""
        said = [line for line in self.lines('log') if 'at shutdown:' in line]
        self.assertEqual(len(said), 1, self.read('log'))
        return said[0]

    def test_with_the_lock_held_a_module_built_for_kernel_old_takes_it_and_is_said_to(self):
        self.register('net', OLD)
        self.hold_lock()
        rc, out, _ = self.stop(limit=2)
        self.assertEqual(rc, 0, out)
        self.assertEqual(len(self.lines('lockf.calls')), 1, 'the whole run did not wait for the lock')
        self.assertTrue(self.armed())
        self.assertTrue(os.path.exists(self.path('run/kernelfollow.armed')))
        self.assertIn('-p daemon.err at shutdown: follow.sh was cut off after 2s; the next boot takes '
                      'kernel.old, which a module the network needs is built for', self.hook_line())

    def test_a_fall_back_cleared_while_the_run_waited_is_armed_again(self):
        # os-xgs-npu's five-minute run, done with its own module while this hook's run waits for the
        # lock, clears nextboot whoever armed it
        self.register('net', OLD)
        self.hold_lock()

        def cleared_by_the_other_follower():
            end = time.monotonic() + 10
            while not self.armed() and time.monotonic() < end:
                time.sleep(0.05)
            subprocess.run([self.nextboot, '-D'], check=True)

        rc, out, _ = self.stop(limit=3, meanwhile=cleared_by_the_other_follower)
        self.assertEqual(rc, 0, out)
        self.assertTrue(self.armed(), 'the next boot takes the new kernel with a module built for the old')
        self.assertIn('cut off after 3s; the next boot takes kernel.old, which a module the network needs '
                      'is built for', self.hook_line())

    def test_with_the_lock_held_a_module_built_for_the_next_kernel_is_not_said_to_take_kernel_old(self):
        self.register('net', NEXT)
        self.hold_lock()
        rc, out, _ = self.stop(limit=2)
        line = self.hook_line()
        self.assertEqual(rc, 0, out)
        self.assertEqual(self.lines('nextboot.calls'), [])
        self.assertIn('cut off after 2s; every module the network needs that this plugin follows is built '
                      'for /boot/kernel', line)
        self.assertNotIn('kernel.old', line)
        self.assertFalse(self.armed())

    def test_with_the_lock_held_a_module_built_for_neither_kernel_is_not_said_to_take_kernel_old(self):
        self.register('net', OLDER)
        self.hold_lock()
        rc, out, _ = self.stop(limit=2)
        line = self.hook_line()
        self.assertEqual(rc, 0, out)
        self.assertEqual(self.lines('nextboot.calls'), [])
        self.assertIn('the module does not match /boot/kernel.old either', self.read('log'))
        self.assertIn('cut off after 2s; this plugin did not send the next boot to kernel.old', line)
        self.assertNotIn('takes kernel.old', line)
        self.assertFalse(self.armed())

    def test_a_fall_back_the_run_let_go_before_it_was_cut_off_is_not_said_to_stand(self):
        # The module the network needs is rebuilt, which lets the fall-back go at once; one it does not
        # need, after it, is still building at the time limit.
        self.fetch(works=True)
        self.register('a-net', OLD)
        self.register('b-extra', OLD, critical=False, slow=30)
        rc, out, _ = self.stop(limit=4)
        line = self.hook_line()
        self.assertEqual(rc, 0, out)
        self.assertEqual(self.read('boot/modules/a-net.ko.kernel'), NEXT + '\n')
        self.assertFalse(self.armed())
        self.assertFalse(os.path.exists(self.path('run/kernelfollow.armed')))
        self.assertIn('cut off after 4s; every module the network needs that this plugin follows is built '
                      'for /boot/kernel', line)
        self.assertNotIn('kernel.old', line)

    def test_a_rebuild_that_failed_is_said_with_what_it_left(self):
        self.register('net', OLD)
        rc, out, _ = self.stop(limit=30)
        self.assertEqual(rc, 0, out)
        self.assertTrue(self.armed())
        self.assertIn('-p daemon.err at shutdown: a module could not be rebuilt (see the entries above); the '
                      'next boot takes kernel.old, which a module the network needs is built for',
                      self.hook_line())


if __name__ == '__main__':
    unittest.main(verbosity=2)
