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
     * the kernels, the registered modules and the sources (scripts/kernelfollow/status.py): the
     * page's cards and its grid both, from one call since 2026-10-29, when the grid's own search
     * - status.py run a second time at every refresh - went
     */
    public function statusAction()
    {
        $status = json_decode((new Backend())->configdRun('kernelfollow status'), true);
        return is_array($status) ? $status : ['error' => gettext('The status could not be read.')];
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
