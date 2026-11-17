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

Each module, registered or os-xgs-npu's, says who follows it (followed_by), what that follower's last
run found or did with it (last) and when it last built it (built_at), each read from that follower's
own record (2026-11-17): this plugin's results/<name>, or for octep.ko and npuep.ko where os-xgs-npu's
follower is installed, that follower's /var/db/os-xgs-npu/kernel-follow.result. Until then os-xgs-npu's
modules carried their stamps alone, a registration of either carried this plugin's "skipped", and no
module said when it was built.
"""

import fcntl
import glob
import json
import lzma
import os
import re
import subprocess
import tarfile

CONFD = '/usr/local/etc/kernelfollow.d'
STATE = '/var/db/os-kernelfollow'
SRCPOOL = '/usr/local/share/os-kernelfollow/kernel-sources'
PROJECT = '/usr/local/opnsense/scripts/octep/kernel-follow.sh'
PROJECT_MODULES = ('/boot/modules/octep.ko', '/boot/modules/npuep.ko')
# What os-xgs-npu's follower records of its last run, as follow.sh records each module (its
# install/kernel-follow.sh, RESULT): the module it follows, and what it found or did with it.
PROJECT_RESULT = '/var/db/os-xgs-npu/kernel-follow.result'
KERNEL = '/boot/kernel/kernel'
WORKPREFIX = '/var/cache/opnsense-update'
CONF = '/conf/config.xml'
BANNER = re.compile(rb'FreeBSD [0-9][^\x00\n]*?stable/[^ \x00\n]+[^\x00\n]*')


def version_in(data):
    found = BANNER.search(data)
    return found.group(0).decode('ascii', 'replace').strip() if found else None


def kernel_in_set(path):
    """The banner of the kernel in a staged set, out of its boot/kernel/kernel member - named so or
    './boot/kernel/kernel', as a set can name it. The members are read in order and the rest of the
    set is never unpacked (2026-10-29): extractfile() by name first listed the whole set, raised
    KeyError where the first name was not the set's, and so never tried the second."""
    with tarfile.open(path, 'r:xz') as archive:
        for member in archive:
            name = member.name
            while name.startswith('./'):
                name = name[2:]
            if name == 'boot/kernel/kernel' and member.isfile():
                handle = archive.extractfile(member)
                return version_in(handle.read()) if handle else None
    return None


def kernel_to_follow():
    if os.path.exists(os.path.join(WORKPREFIX, '.kernel.pending')):
        for path in sorted(glob.glob(os.path.join(WORKPREFIX, '.sets.pending', 'kernel-*.txz'))):
            try:
                found = kernel_in_set(path)
            except (OSError, EOFError, lzma.LZMAError, tarfile.TarError):
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
    """KEY=value lines, read as follow.sh's val() reads them (2026-10-29; until then follow.sh took
    a key only at the start of a line and its value as it stood, and the two could disagree about one
    file): spaces around either side and carriage returns ignored, one pair of quotes around the
    value taken off, a line starting with # skipped, the last line for a key winning."""
    out = {}
    for line in (read(path) or '').replace('\r', '').split('\n'):
        if '=' not in line or line.lstrip().startswith('#'):
            continue
        key, value = line.split('=', 1)
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in '"\'':
            value = value[1:-1]
        out[key.strip()] = value
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


def number(text):
    return int(text) if (text or '').isdigit() else None


def followed(entry, record):
    """What a follower's record says of a module: its last run's result, the line that says why, the
    kernel it followed and when - and when it last built the module, said only while the module is
    installed."""
    entry['last'] = {'result': record.get('result'), 'message': record.get('message'),
                     'target': record.get('target'), 'at': number(record.get('at'))}
    entry['built_at'] = number(record.get('built_at')) if entry['installed'] else None
    return entry


def project_record(module):
    """os-xgs-npu's follower's record, where it is of this module: that follower follows one module, the
    one installed, and names it in its record."""
    record = keys(PROJECT_RESULT)
    same = bool(module) and os.path.normpath(record.get('module') or '-') == os.path.normpath(module)
    return record if same else {}


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
        # the record of whoever follows it: follow.sh leaves those two to os-xgs-npu's follower, and its
        # own record of either says only that
        modules.append(followed(entry, project_record(entry['module']) if entry['followed_by'] == 'os-xgs-npu'
                                else keys(os.path.join(STATE, 'results', name))))
    project_modules = [dict(followed(module_state(m, target), project_record(m)), followed_by='os-xgs-npu')
                       for m in PROJECT_MODULES if project and os.path.exists(m)]
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
