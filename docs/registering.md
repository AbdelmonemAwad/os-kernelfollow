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
| `CRITICAL` | no | `yes` when the network depends on the module: if it cannot be rebuilt, the next boot is sent to `/boot/kernel.old`, which it matches |

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

## Removing a registration

Delete the file. The module and its stamps stay where they are.

## os-xgs-npu's modules

`octep.ko` and `npuep.ko` are followed by os-xgs-npu's own follower while that is installed; a
registration for either is shown and left to it.
