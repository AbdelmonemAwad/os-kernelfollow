# Registering a module

A plugin that installs an out-of-tree kernel module asks this one to keep it built for the kernel by
dropping one file into `/usr/local/etc/kernelfollow.d/`, named after the module:

```sh
# /usr/local/etc/kernelfollow.d/hello.conf
MODULE=/boot/modules/hello.ko
SOURCES=/usr/local/share/os-hello/hello
ATTACHED=dev.hello.0.%desc
OWNER=os-hello
CRITICAL=no
```

| key | required | what it is |
|---|---|---|
| `MODULE` | yes | where the module is installed; the stamp is kept beside it as `<MODULE>.kernel` |
| `SOURCES` | yes | a directory with the module's `Makefile`, `*.c` and `*.h`, exactly as shipped - nothing is ever built in it |
| `ATTACHED` | no | a sysctl that exists once the driver has attached; old kernel sources are removed only when it does |
| `OWNER` | no | who registered it, shown on the page |
| `CRITICAL` | no | `yes` when the network depends on the module: ~~if it cannot be rebuilt,~~ the next boot is sent to `/boot/kernel.old`, which it matches, before a rebuild for a new kernel starts, and again at every boot until the module matches (since 1.0.2); a rebuild that cannot be done leaves it there. Not where `kernel.old` is of another FreeBSD major release, as after a major upgrade (since 2026-11-06): the next boot then takes `/boot/kernel`, without the module if it could not be rebuilt |

One `KEY=value` a line; the file is read, never executed. The follower and the page read it the same
way (since 2026-10-29): spaces around the `=` and at either end of a line are ignored, and so is a
carriage return; one pair of quotes around a value, `"..."` or `'...'`, is taken off; a line
starting with `#` is skipped; and the last line for a key wins. The module's `Makefile` builds
`<name>.ko`, where `<name>` is the file name of `MODULE` without `.ko` - the usual `KMOD=` line does
that.

## What the follower keeps beside the module

- `<MODULE>.kernel` - the kernel the module was built for, as the kernel's banner says it:
  `FreeBSD 15.1-RELEASE-p1 stable/26.7-n283674-12334a596709 SMP`;
- `<MODULE>.prev` and `<MODULE>.prev.kernel` - the build it replaced, when that was for another
  kernel.

What loads the module should compare `<MODULE>.kernel` with `uname -v` and refuse a mismatch - a
module built for another kernel of the same branch loads without complaint and reads moved
structures at the wrong offsets - and take `<MODULE>.prev` when its stamp is the one that matches.
That part is the owner's: the follower builds and stamps, it does not load.

## What the follower records, and what the status says

Every whole run - not `DRY=1`, not `PINONLY=1` - records what it found or did with each registration in
`/var/db/os-kernelfollow/results/<name>`, one `KEY=value` a line: `result` (`ok`, `built`, `failed` or
`skipped`), `message`, `target` (the kernel it followed), `at` (when, in seconds since the epoch) and,
since 2026-11-17, `module` - the `MODULE` the registration named - and `built_at` - when this plugin
last built and installed that module, kept from one run to the next while it is installed and the
record before names it, and empty when it is not installed, has not been built since, or the
registration's `MODULE` has been changed to another file since its last build.

`status.py` - the page's, and configd's `kernelfollow status` - gives each module, registered or
os-xgs-npu's (`project_modules`), what the follower that follows it recorded:

| field | what it is |
|---|---|
| `followed_by` | `this plugin`, or `os-xgs-npu` for `octep.ko` and `npuep.ko` while that plugin's follower is installed |
| `last` | `result`, `message`, `target` and `at` of that follower's last run; each `null` where it has recorded none |
| `built_at` | when that follower last built the module; `null` when it has not said, or the module is not installed |

beside `module`, `installed`, `stamp`, `matches` (the stamp is the kernel the next boot takes) and
`prev_stamp`.

## When the sources change

The follower rebuilds a module when its stamp names another kernel than the one to follow - not
when its sources change. A new version of the module's sources, with the kernel the same, still
matches the stamp, and neither the five-minute run nor **Follow now** builds it again. The plugin
that changed `SOURCES` asks for the build itself, in its install or update, by the name of its
registration's file:

```sh
FORCE=1 ONLY=hello sh /usr/local/opnsense/scripts/kernelfollow/follow.sh
```

`FORCE=1` builds although the stamp matches; `ONLY=hello` keeps it to `hello.conf`. The build is
checked and installed as any other, and `<MODULE>.prev` is left as it is, the kernel being the same.

## Removing a registration

Delete the file. The module and its stamps stay where they are.

## os-xgs-npu's modules

`octep.ko` and `npuep.ko` are followed by os-xgs-npu's own follower while that is installed; a
registration for either is shown and left to it. Their `last` and `built_at` come from that follower's
own record, `/var/db/os-xgs-npu/kernel-follow.result` - the same keys, `module` the module it follows -
where it keeps one, and are `null` where it does not; XGS: Updates reads the same record.
