<?php

/*
 * SPDX-License-Identifier: BSD-2-Clause
 * Copyright (c) 2026 Abdelmonem Awad <eg2@live.com>
 */

namespace OPNsense\KernelFollow\Api;

use OPNsense\Base\ApiControllerBase;
use OPNsense\Core\Backend;

class ServiceController extends ApiControllerBase
{
    /**
     * the kernels, the registered modules and the sources (scripts/kernelfollow/status.py)
     */
    public function statusAction()
    {
        $status = json_decode((new Backend())->configdRun('kernelfollow status'), true);
        return is_array($status) ? $status : ['error' => gettext('The status could not be read.')];
    }

    /**
     * the page's grid: one row for each registered module, then one for each of os-xgs-npu's own
     * where its follower is installed (project = 1), out of the same status
     */
    public function searchAction()
    {
        $status = json_decode((new Backend())->configdRun('kernelfollow status'), true);
        $rows = [];
        foreach ((is_array($status) ? ($status['modules'] ?? []) : []) as $module) {
            $rows[] = [
                'name' => (string)($module['name'] ?? ''),
                'module' => (string)($module['module'] ?? ''),
                'owner' => (string)($module['owner'] ?? ''),
                'stamp' => $this->shortKernel($module['stamp'] ?? null),
                'state' => empty($module['installed']) ? 'missing' : (empty($module['matches']) ? 'rebuild' : 'matches'),
                'followed_by' => (string)($module['followed_by'] ?? ''),
                'result' => (string)($module['last']['result'] ?? ''),
                'at' => (int)($module['last']['at'] ?? 0),
                'project' => 0,
            ];
        }
        foreach ((is_array($status) ? ($status['project_modules'] ?? []) : []) as $module) {
            $path = (string)($module['module'] ?? '');
            $rows[] = [
                'name' => preg_replace('/\.ko$/', '', basename($path)),
                'module' => $path,
                'owner' => 'os-xgs-npu',
                'stamp' => $this->shortKernel($module['stamp'] ?? null),
                'state' => empty($module['matches']) ? 'rebuild' : 'matches',
                'followed_by' => 'os-xgs-npu',
                'result' => '',
                'at' => 0,
                'project' => 1,
            ];
        }
        return $this->searchRecordsetBase($rows);
    }

    /**
     * the kernel by its source token, stable/26.7-n283674-12334a596709: the part that changes
     */
    private function shortKernel($version)
    {
        $version = (string)($version ?? '');
        if (preg_match('/stable\/(\S+)/', $version, $found)) {
            return $found[1];
        }
        return $version !== '' ? $version : '-';
    }

    /**
     * what a run would do, changing nothing
     */
    public function checkAction()
    {
        if (!$this->request->isPost()) {
            return ['status' => 'failed'];
        }
        return ['status' => 'ok', 'output' => trim((new Backend())->configdRun('kernelfollow check'))];
    }

    /**
     * a run now, detached: a fetch and a build take minutes; the page reads last-run.log afterwards
     */
    public function runAction()
    {
        if (!$this->request->isPost()) {
            return ['status' => 'failed'];
        }
        (new Backend())->configdRun('kernelfollow run', true);
        return ['status' => 'ok'];
    }
}
