#!/usr/local/bin/python3
#-
# SPDX-License-Identifier: BSD-2-Clause
# Copyright (c) 2026 Abdelmonem Awad <eg2@live.com>
#
"""
What the page shows, as one JSON object: the kernel running and the kernel the next boot will use,
each registered module with its stamp and what the last run did with it, os-xgs-npu's own modules
where its follower is installed, the kernel sources on disk, and the settings.

    status.py

Read only. The kernel to follow is read as follow.sh reads it - a staged set first, /boot/kernel
second - out of the binary, without booting it.
"""

import fcntl
import glob
import json
import os
import re
import subprocess
import tarfile

CONFD = '/usr/local/etc/kernelfollow.d'
STATE = '/var/db/os-kernelfollow'
SRCPOOL = '/usr/local/share/os-kernelfollow/kernel-sources'
PROJECT = '/usr/local/opnsense/scripts/octep/kernel-follow.sh'
PROJECT_MODULES = ('/boot/modules/octep.ko', '/boot/modules/npuep.ko')
KERNEL = '/boot/kernel/kernel'
WORKPREFIX = '/var/cache/opnsense-update'
CONF = '/conf/config.xml'
BANNER = re.compile(rb'FreeBSD [0-9][^\x00\n]*?stable/[^ \x00\n]+[^\x00\n]*')


def version_in(data):
    found = BANNER.search(data)
    return found.group(0).decode('ascii', 'replace').strip() if found else None


def kernel_to_follow():
    if os.path.exists(os.path.join(WORKPREFIX, '.kernel.pending')):
        for path in sorted(glob.glob(os.path.join(WORKPREFIX, '.sets.pending', 'kernel-*.txz'))):
            try:
                with tarfile.open(path, 'r:xz') as archive:
                    member = archive.extractfile('./boot/kernel/kernel') or archive.extractfile('boot/kernel/kernel')
                    found = version_in(member.read()) if member else None
            except (OSError, KeyError, tarfile.TarError):
                found = None
            if found:
                return found, 'staged'
    try:
        with open(KERNEL, 'rb') as handle:
            return version_in(handle.read()), KERNEL
    except OSError:
        return None, KERNEL


def read(path):
    try:
        with open(path, encoding='utf-8', errors='replace') as handle:
            return handle.read().strip()
    except OSError:
        return None


def keys(path):
    """KEY=value lines, the last of each key winning, as follow.sh reads them."""
    out = {}
    for line in (read(path) or '').splitlines():
        if '=' in line and not line.lstrip().startswith('#'):
            key, value = line.split('=', 1)
            out[key.strip()] = value.strip()
    return out


def setting(name, default):
    text = read(CONF) or ''
    section = re.search(r'<KernelFollow[ >].*?</KernelFollow>', text, re.S)
    found = section and re.search(r'<%s>(\d+)</%s>' % (name, name), section.group(0))
    return found.group(1) if found else default


def lock_held():
    """A run is under way: lockf holds the lock file open, locked, for the whole of it."""
    try:
        with open('/var/run/kernelfollow.lock', 'r') as handle:
            fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return False
    except BlockingIOError:
        return True
    except OSError:
        return False


def module_state(module, target):
    stamp = read(module + '.kernel')
    return {
        'module': module,
        'installed': os.path.exists(module),
        'stamp': stamp,
        'matches': bool(stamp) and stamp == target,
        'prev_stamp': read(module + '.prev.kernel'),
    }


def main():
    target, where = kernel_to_follow()
    running = subprocess.run(['/usr/bin/uname', '-v'], capture_output=True, text=True).stdout.strip()
    project = os.path.exists(PROJECT)
    modules = []
    for conf in sorted(glob.glob(os.path.join(CONFD, '*.conf'))):
        name = os.path.basename(conf)[:-len('.conf')]
        reg = keys(conf)
        entry = {'name': name, 'owner': reg.get('OWNER', ''), 'critical': reg.get('CRITICAL') == 'yes',
                 'attached': reg.get('ATTACHED', '')}
        entry.update(module_state(reg.get('MODULE', ''), target) if reg.get('MODULE') else
                     {'module': '', 'installed': False, 'stamp': None, 'matches': False, 'prev_stamp': None})
        entry['followed_by'] = ('os-xgs-npu' if project and os.path.basename(entry['module']) in
                                ('octep.ko', 'npuep.ko') else 'this plugin')
        last = keys(os.path.join(STATE, 'results', name))
        entry['last'] = {'result': last.get('result'), 'message': last.get('message'),
                         'at': int(last['at']) if last.get('at', '').isdigit() else None}
        modules.append(entry)
    project_modules = [module_state(m, target) for m in PROJECT_MODULES if project and os.path.exists(m)]
    trees = sorted(p for p in glob.glob('/usr/src-*-*')
                   if re.match(r'^src-[0-9][0-9.]*-[0-9a-f]{7,40}$', os.path.basename(p)))
    pool = [{'file': os.path.basename(p), 'bytes': os.path.getsize(p)}
            for p in sorted(glob.glob(os.path.join(SRCPOOL, '*.t*gz')))]
    print(json.dumps({
        'running': running,
        'target': target,
        'where': where,
        'modules': modules,
        'project': project,
        'project_modules': project_modules,
        'trees': [os.path.basename(t) for t in trees],
        'pool': pool,
        'pinned': os.path.exists(os.path.join(STATE, 'pinned')),
        'last_run': (read(os.path.join(STATE, 'last-run.log')) or '').splitlines()[-40:],
        'running_now': lock_held(),
        'settings': {'enabled': setting('enabled', '1') == '1', 'fetch': setting('fetch', '1') == '1',
                     'prune': setting('prune', '1') == '1', 'settle_hours': int(setting('settle_hours', '24'))},
    }))


if __name__ == '__main__':
    main()
