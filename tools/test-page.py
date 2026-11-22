#!/usr/bin/env python3
#-
# SPDX-License-Identifier: BSD-2-Clause
# Copyright (c) 2026 Abdelmonem Awad <eg2@live.com>
#
"""grid_rows() of the page away from a browser: the function and short(), which it calls, taken out of
index.volt as they are and run with node(1) on a status made up here, with $.each played by a few lines
of JavaScript. What it checks is the rows the grid is drawn from: one for each registration, then one for
each of os-xgs-npu's own modules, each with the last run its follower recorded (2026-11-22; until then
os-xgs-npu's modules had none, and their Last run column said '-' whatever that record held).

    python3 tools/test-page.py
"""
import json
import os
import shutil
import subprocess
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
PAGE = os.path.join(HERE, '..', 'src', 'opnsense', 'mvc', 'app', 'views', 'OPNsense', 'KernelFollow',
                    'index.volt')

STUB = """
const $ = { each: function (list, fn) { list.forEach(function (v, i) { fn(i, v); }); } };
"""


def function_text(source, name):
    """The text of `function name(...) { ... }` in source, to its closing brace."""
    start = source.index('function %s(' % name)
    depth = 0
    for at in range(source.index('{', start), len(source)):
        if source[at] == '{':
            depth += 1
        elif source[at] == '}':
            depth -= 1
            if depth == 0:
                return source[start:at + 1]
    raise ValueError('no end to function %s' % name)


def grid_rows(data):
    with open(PAGE, encoding='utf-8') as f:
        source = f.read()
    script = (STUB + function_text(source, 'short') + '\n' + function_text(source, 'grid_rows') + '\n' +
              'process.stdout.write(JSON.stringify(grid_rows(%s)));\n' % json.dumps(data))
    done = subprocess.run([shutil.which('node') or 'node', '-e', script], capture_output=True, text=True,
                          timeout=30)
    if done.returncode != 0:
        raise AssertionError(done.stderr)
    return json.loads(done.stdout)


STAMP = 'FreeBSD 15.1-RELEASE-p6 stable/26.7-n284176-c962f76493b6 SMP'


def project_module(module, last):
    return {'module': module, 'installed': True, 'stamp': STAMP, 'matches': True, 'prev_stamp': None,
            'followed_by': 'os-xgs-npu', 'last': last, 'built_at': 1763700000}


class GridRows(unittest.TestCase):

    @classmethod
    def setUpClass(cls):
        if not shutil.which('node'):
            # On a CI runner a skip would pass the step green with nothing tested, so it fails there.
            if os.environ.get('CI'):
                raise RuntimeError('node(1) is not on this runner')
            raise unittest.SkipTest('node(1) is not on this machine')

    def test_os_xgs_npu_s_module_shows_its_follower_s_last_run(self):
        rows = grid_rows({'modules': [], 'project_modules': [project_module(
            '/boot/modules/octep.ko',
            {'result': 'built', 'message': 'rebuilt for the next kernel', 'target': STAMP, 'at': 1763700000})]})
        self.assertEqual(len(rows), 1)
        row = rows[0]
        self.assertEqual(row['key'], 'project:/boot/modules/octep.ko')
        self.assertEqual(row['name'], 'octep')
        self.assertEqual(row['result'], 'built')
        self.assertEqual(row['message'], 'rebuilt for the next kernel')
        self.assertEqual(row['at'], 1763700000)
        # still os-xgs-npu's, shown quiet
        self.assertEqual(row['project'], 1)
        self.assertEqual(row['followed_by'], 'os-xgs-npu')
        self.assertEqual(row['stamp'], '26.7-n284176-c962f76493b6')

    def test_without_a_record_it_says_none(self):
        rows = grid_rows({'project_modules': [project_module(
            '/boot/modules/npuep.ko', {'result': None, 'message': None, 'target': None, 'at': None})]})
        self.assertEqual((rows[0]['result'], rows[0]['message'], rows[0]['at']), ('', '', 0))
        # and an entry with no last at all, as an older status.py gave it
        entry = project_module('/boot/modules/npuep.ko', None)
        del entry['last']
        rows = grid_rows({'project_modules': [entry]})
        self.assertEqual((rows[0]['result'], rows[0]['message'], rows[0]['at']), ('', '', 0))

    def test_registrations_first_then_os_xgs_npu_s_modules(self):
        rows = grid_rows({
            'modules': [{'name': 'hello', 'module': '/boot/modules/hello.ko', 'owner': 'os-hello',
                         'installed': True, 'stamp': STAMP, 'matches': False, 'followed_by': 'this plugin',
                         'last': {'result': 'failed', 'message': 'make failed', 'at': 1763600000}}],
            'project_modules': [project_module(
                '/boot/modules/octep.ko', {'result': 'ok', 'message': '', 'at': 1763700000})]})
        self.assertEqual([r['key'] for r in rows], ['registration:hello', 'project:/boot/modules/octep.ko'])
        self.assertEqual((rows[0]['result'], rows[0]['state'], rows[0]['project']), ('failed', 'rebuild', 0))
        self.assertEqual((rows[1]['result'], rows[1]['at'], rows[1]['project']), ('ok', 1763700000, 1))


if __name__ == '__main__':
    unittest.main()
