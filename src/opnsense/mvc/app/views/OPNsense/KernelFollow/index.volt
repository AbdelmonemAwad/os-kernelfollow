{#
 # SPDX-License-Identifier: BSD-2-Clause
 # Copyright (c) 2026 Abdelmonem Awad <eg2@live.com>
 #
 # System: Kernel Follower (XGS: Kernel Follower when os-xgs-npu is installed) - the kernel running
 # and the one the next boot takes, each registered module against it, the kernel sources on disk,
 # and the settings.
 #}

<style>
    /* KIT-CSS-BEGIN */
    .xgs-cards { display: flex; flex-wrap: wrap; gap: 12px; padding: 15px; }
    .xgs-cards.xgs-top { padding: 0 0 15px; }
    .xgs-card { flex: 1 1 200px; min-width: 190px; border: 1px solid rgba(128, 128, 128, 0.25);
                border-inline-start: 4px solid #9e9e9e; border-radius: 3px; padding: 10px 14px;
                background-color: rgba(128, 128, 128, 0.04); }
    .xgs-card.ok { border-inline-start-color: #5cb85c; }
    .xgs-card.warn { border-inline-start-color: #f0ad4e; }
    .xgs-card.bad { border-inline-start-color: #d9534f; }
    .xgs-card .k { font-size: 11px; text-transform: uppercase; letter-spacing: .04em; opacity: 0.6; }
    .xgs-card .v { font-size: 19px; font-weight: 600; line-height: 1.3; margin: 2px 0; }
    .xgs-card .s { font-size: 12px; opacity: 0.7; }
    .xgs-card .fa { opacity: 0.35; float: inline-end; font-size: 18px; margin-top: 2px; }
    .xgs-head { padding-top: 5px; padding-bottom: 5px; font-size: 16px; }
    /* KIT-CSS-END */
    /* a run's output, in English and read left to right in every language */
    .kf-pre { white-space: pre-wrap; direction: ltr; text-align: start; max-height: 420px; overflow: auto; margin: 0 15px 15px; }
    /* as on XGS: Ports: columns that fill the width show a one-pixel sideways bar without this */
    @media (min-width: 768px) {
        #grid-modules .tabulator-tableholder { overflow-x: hidden; }
    }
</style>

<script>
    $(document).ready(function () {
        /* KIT-JS-BEGIN */
        /* A string as OPNsense's API and Volt's lang._() hand it over - escaped - made plain for .text(). */
        function plain(value) {
            return $('<textarea/>').html(value === null || value === undefined ? '' : String(value)).text();
        }

        /* One card: cls '' (grey, no judgement), 'ok', 'warn' or 'bad'; icon a Font Awesome name. */
        function card(cls, icon, key, value, sub) {
            return $('<div class="xgs-card"/>').addClass(cls)
                .append($('<i class="fa"/>').addClass(icon))
                .append($('<div class="k"/>').text(plain(key)))
                .append($('<div class="v"/>').text(plain(value)))
                .append($('<div class="s"/>').text(plain(sub || ' ')));
        }

        /* Until the first reading: the same cards, their keys, and an ellipsis for every value. */
        function cards_wait(target, keys) {
            $(target).empty();
            $.each(keys, function (i, key) {
                $(target).append(card('', 'fa-ellipsis-h', key, '…', ''));
            });
        }

        /* The selected tab kept in the address, as on OPNsense's own tabbed pages. */
        function keep_tab() {
            if (window.location.hash !== '') {
                $('a[href="' + window.location.hash + '"]').tab('show');
            }
            $('.nav-tabs a').on('shown.bs.tab', function (e) {
                history.pushState(null, null, e.target.hash);
            });
        }
        /* KIT-JS-END */

        /* The kernel by its source token, stable/26.7-n283674-12334a596709: the part that changes. */
        function short(version) {
            const found = (version || '').match(/stable\/\S+/);
            return found ? found[0].replace(/^stable\//, '') : (version || '-');
        }

        /* A kernel token isolated left to right: in an Arabic page its leading number would
           otherwise move to the far end. */
        function ltr(text) {
            return '⁦' + text + '⁩';
        }

        function when(at) {
            return at ? new Date(at * 1000).toLocaleString() : '';
        }

        let polling = null;

        function draw(data) {
            const $cards = $('#kf-cards').empty();
            if (!data || data.error) {
                $cards.append(card('bad', 'fa-cogs', "{{ lang._('Kernel Follower') }}",
                    "{{ lang._('The status could not be read.') }}", ''));
                return;
            }
            const same = data.target && data.running === data.target;
            $cards.append(card('ok', 'fa-microchip', "{{ lang._('Kernel running') }}", ltr(short(data.running)), ''));
            $cards.append(card(same ? 'ok' : 'warn', 'fa-forward', "{{ lang._('Next boot') }}",
                ltr(short(data.target)), same ? "{{ lang._('the same kernel') }}" :
                    (data.where === 'staged' ? "{{ lang._('staged by an update, not applied yet') }}" :
                                               "{{ lang._('installed, not booted yet') }}")));
            const mine = data.modules.filter(function (m) { return m.followed_by === 'this plugin'; });
            const behind = mine.filter(function (m) { return m.installed && !m.matches; }).length;
            $cards.append(card(!mine.length ? '' : (behind ? 'warn' : 'ok'), 'fa-cube', "{{ lang._('Modules') }}",
                mine.length ? String(mine.length) : "{{ lang._('none registered') }}",
                behind ? behind + ' ' + "{{ lang._('to rebuild') }}" :
                    (mine.length ? "{{ lang._('all match the next boot') }}" : '')));
            const bytes = data.pool.reduce(function (n, a) { return n + a.bytes; }, 0);
            $cards.append(card('', 'fa-archive', "{{ lang._('Kernel sources') }}", String(data.trees.length),
                data.pool.length ? data.pool.length + ' ' + "{{ lang._('archives') }}" + ', ' +
                    Math.round(bytes / 1048576) + ' MB' : "{{ lang._('no archives carried') }}"));

            $('#kf-project').toggle(!!data.project);
            $('#kf-pinned').toggle(!!data.pinned);
            $('#kf-none').toggle(!data.modules.length && !(data.project_modules || []).length);

            $('#kf-trees').text(data.trees.length ? data.trees.join('  ') : '-');
            $('#kf-lastrun').text(data.last_run && data.last_run.length ? data.last_run.join('\n') : '-');
            /* Neither button while a run is under way: Follow now would wait behind it, and Check
               would only say that a run is under way (2026-10-29). */
            $('#runAct').prop('disabled', !!data.running_now);
            $('#checkAct').prop('disabled', !!data.running_now);
            if (data.running_now && !polling) {
                polling = setInterval(refresh, 5000);
            } else if (!data.running_now && polling) {
                clearInterval(polling);
                polling = null;
            }
        }

        function read_state() {
            ajaxGet('/api/kernelfollow/service/status', {}, draw);
        }

        /* What the cards and the tabs show, read again: the state and the modules' grid. */
        function refresh() {
            read_state();
            $('#grid-modules').bootgrid('reload');
        }

        /* Each row as Api/ServiceController::searchAction built it, its strings escaped by the API and
           put in as they come; os-xgs-npu's own modules quiet, as it follows them itself. */
        function quiet(row, html) {
            return Number(row.project) ? '<span class="text-muted">' + html + '</span>' : html;
        }

        /* What the last run did with a module, in the page's language: follow.sh records it as one
           English word, which the column used to show as it came (2026-10-29). */
        const results = {
            ok: "{{ lang._('matches') }}",
            built: "{{ lang._('rebuilt') }}",
            failed: "{{ lang._('failed') }}",
            skipped: "{{ lang._('skipped') }}"
        };

        $('#grid-modules').UIBootgrid({
            search: '/api/kernelfollow/service/search',
            options: {
                selection: false,
                formatters: {
                    text: function (column, row) {
                        return quiet(row, row[column.id] || '-');
                    },
                    module: function (column, row) {
                        return quiet(row, '<code>' + row.module + '</code>');
                    },
                    stamp: function (column, row) {
                        return quiet(row, '<bdi dir="ltr">' + row.stamp + '</bdi>');
                    },
                    state: function (column, row) {
                        return quiet(row, row.state === 'missing' ? "{{ lang._('not installed') }}" :
                            (row.state === 'matches' ? "{{ lang._('matches') }}" : "{{ lang._('to rebuild') }}"));
                    },
                    followed: function (column, row) {
                        return quiet(row, row.followed_by === 'this plugin' ? "{{ lang._('this plugin') }}" : row.followed_by);
                    },
                    last: function (column, row) {
                        if (!row.result) {
                            return quiet(row, '-');
                        }
                        const text = (results[row.result] || row.result) +
                            (Number(row.at) ? ', ' + when(Number(row.at)) : '');
                        /* and what follow.sh said, on hover: why a module failed or was skipped */
                        return quiet(row, $('<span/>').attr('title', plain(row.message)).text(plain(text))[0].outerHTML);
                    }
                }
            }
        });

        mapDataToFormUI({'frm_general': '/api/kernelfollow/settings/get'}).done(function () {
            $('.selectpicker').selectpicker('refresh');
        });
        cards_wait('#kf-cards', ["{{ lang._('Kernel running') }}", "{{ lang._('Next boot') }}",
            "{{ lang._('Modules') }}", "{{ lang._('Kernel sources') }}"]);
        read_state();

        $('#refreshAct').click(function () {
            refresh();
        });

        /* Saving is all there is: follow.sh reads the settings at each run, so no service is told. */
        $('#saveAct').click(function () {
            const $button = $(this).prop('disabled', true);
            const $progress = $('#frm_general_progress').addClass('fa fa-spinner fa-pulse');
            const done = function () {
                $progress.removeClass('fa fa-spinner fa-pulse');
                $button.prop('disabled', false);
            };
            saveFormToEndpoint('/api/kernelfollow/settings/set', 'frm_general', function () {
                done();
                read_state();
            }, false, done);
        });

        $('#checkAct').click(function () {
            const $button = $(this).prop('disabled', true);
            ajaxCall('/api/kernelfollow/service/check', {}, function (data) {
                $button.prop('disabled', false);
                $('#kf-check').text(data && data.output ? data.output : '-').show();
                read_state();
            });
        });

        $('#runAct').click(function () {
            stdDialogConfirm("{{ lang._('Follow now') }}",
                "{{ lang._('Every registered module that does not match the kernel the next boot will use is rebuilt now: its sources fetched if they are not here, built, and installed beside the old one. It takes minutes; the page follows it.') }}",
                "{{ lang._('Yes') }}", "{{ lang._('Cancel') }}", function () {
                    ajaxCall('/api/kernelfollow/service/run', {}, function () {
                        $('a[href="#lastrun"]').tab('show');
                        setTimeout(refresh, 1500);
                        if (!polling) {
                            polling = setInterval(refresh, 5000);
                        }
                    });
                });
        });

        keep_tab();
    });
</script>

<div class="xgs-cards xgs-top" id="kf-cards"></div>
<div class="clearfix" style="margin-bottom: 10px;">
    <button id="refreshAct" class="btn btn-default btn-xs pull-right" type="button" title="{{ lang._('Refresh') }}"><i class="fa fa-fw fa-refresh"></i></button>
    <span id="kf-project" class="text-muted" style="display: none;">
        {{ lang._('os-xgs-npu follows its own two modules on this host with its own follower. This plugin leaves them to it and only shows them, and leaves the old kernel sources in /usr/src for it to remove.') }}
    </span>
</div>
<div id="kf-pinned" class="alert alert-warning" role="alert" style="display: none;">
    {{ lang._('A module the network needs could not be rebuilt, so the next boot takes the previous kernel, which it matches. The next run that rebuilds it cancels this.') }}
</div>

<ul class="nav nav-tabs" data-tabs="tabs" id="maintabs">
    <li class="active"><a data-toggle="tab" href="#modules">{{ lang._('Modules') }}</a></li>
    <li><a data-toggle="tab" href="#settings">{{ lang._('Settings') }}</a></li>
    <li><a data-toggle="tab" href="#lastrun">{{ lang._('Last run') }}</a></li>
</ul>

<div class="tab-content content-box">
    <div id="modules" class="tab-pane active">
        <table id="grid-modules" class="table table-condensed table-hover table-striped table-responsive">
            <thead>
                <tr>
                    <th data-column-id="name" data-formatter="text" data-type="string">{{ lang._('Name') }}</th>
                    <th data-column-id="module" data-formatter="module" data-type="string" data-identifier="true">{{ lang._('Module') }}</th>
                    <th data-column-id="owner" data-formatter="text" data-type="string">{{ lang._('Registered by') }}</th>
                    <th data-column-id="stamp" data-formatter="stamp" data-type="string">{{ lang._('Built for') }}</th>
                    <th data-column-id="state" data-formatter="state" data-type="string" data-width="9em">{{ lang._('State') }}</th>
                    <th data-column-id="followed_by" data-formatter="followed" data-type="string">{{ lang._('Followed by') }}</th>
                    <th data-column-id="result" data-formatter="last" data-type="string">{{ lang._('Last run') }}</th>
                </tr>
            </thead>
            <tbody></tbody>
            <tfoot></tfoot>
        </table>
        <div id="kf-none" class="text-muted" style="display: none; padding: 0 15px 10px;">
            {{ lang._('No module is registered. A plugin that installs one registers it in /usr/local/etc/kernelfollow.d.') }}
        </div>
        <div style="padding: 0 15px 10px;">
            {{ lang._('Kernel sources on disk') }}: <code id="kf-trees">-</code>
        </div>
        <div style="padding: 0 15px 15px;">
            <button class="btn btn-default" id="checkAct" type="button">{{ lang._('Check') }}</button>
            <button class="btn btn-primary" id="runAct" type="button">{{ lang._('Follow now') }}</button>
        </div>
        <pre id="kf-check" class="kf-pre" style="display: none;"></pre>
    </div>
    <div id="settings" class="tab-pane">
        {{ partial("layout_partials/base_form", ['fields': generalForm, 'id': 'frm_general', 'apply_btn_id': 'saveAct']) }}
    </div>
    <div id="lastrun" class="tab-pane">
        <pre id="kf-lastrun" class="kf-pre" style="margin-top: 15px;">-</pre>
    </div>
</div>

{{ partial("OPNsense/KernelFollow/credit") }}
