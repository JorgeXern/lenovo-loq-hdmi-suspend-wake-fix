# Hang history (before the fix)

Source: `journalctl -b <N> -k` for every boot on Fedora 44, Lenovo LOQ 15ARP10E.
A boot whose **last** suspend line is `PM: suspend entry` (never followed by
`PM: suspend exit`) ended in a hang that required a forced power-off.

```
boot | result   | kernel                       | nvidia       | suspends in boot
 -36 | ok       | 6.19.10-300.fc44.x86_64      | (not yet)    |  7
 -30 | ok       | 7.2.9-200.fc44.x86_64        | 615.71.09    |  1
 -29 | ok       | 7.2.9-200.fc44.x86_64        | 615.71.09    |  1
 -28 | HUNG     | 7.2.9-200.fc44.x86_64        | 615.71.09    | 26
 -27 | ok       | 7.2.9-200.fc44.x86_64        | 615.71.09    |  1
 -26 | HUNG     | 7.2.9-200.fc44.x86_64        | 615.71.09    |  1
 -25 | ok       | 7.2.9-200.fc44.x86_64        | 615.71.09    | 10
 -24 | ok       | 7.2.9-200.fc44.x86_64        | 615.71.09    |  1
 -23 | ok       | 7.2.10-200.fc44.x86_64       | 615.78.08    | 42
 -20 | HUNG     | 7.2.10-200.fc44.x86_64       | 615.78.08    |  8
 -19 | ok       | 7.2.10-200.fc44.x86_64       | 615.78.08    |  4
 -17 | ok       | 7.2.10-200.fc44.x86_64       | 615.78.08    |  8
 -16 | ok       | 7.2.10-200.fc44.x86_64       | 615.78.08    |  1
 -13 | ok       | 7.2.10-200.fc44.x86_64       | 615.78.08    | 54
 -12 | HUNG     | 7.2.10-200.fc44.x86_64       | 615.78.08    | 35
 -10 | ok       | 7.2.10-200.fc44.x86_64       | 615.78.08    |  2
  -8 | HUNG     | 7.2.11-200.fc44.x86_64       | 615.78.08    | 11
  -6 | ok       | 7.2.11-200.fc44.x86_64       | 615.78.08    |  1
  -2 | ok       | 7.2.11-200.fc44.x86_64       | 615.78.08    | 17
  -1 | HUNG     | 7.2.11-200.fc44.x86_64       | 615.78.08    | 99
```

Totals: 6 hangs (Oct 11, 13, 16, 18, 19, 24) in ~330 suspend cycles over 15 days
(≈ 1 hang per 55 cycles). Three kernel versions and two NVIDIA driver versions
are affected, so the hang is not tied to a single release.

The hung boot's kernel log simply stops:

```
oct 24 16:09:03 host kernel: PM: suspend exit
oct 24 17:23:06 host kernel: PM: suspend entry (s2idle)
<end of boot>
```

Userspace side of that last cycle: the NVIDIA systemd service is skipped on
purpose because the driver uses kernel suspend notifiers:

```
systemd[1]: Starting nvidia-suspend.service - NVIDIA system suspend actions...
systemd[1]: nvidia-suspend.service: Skipped due to 'exec-condition'.
systemd[1]: Starting systemd-suspend.service - System Suspend...
systemd-sleep[...]: User sessions remain unfrozen on explicit request ($SYSTEMD_SLEEP_FREEZE_USER_SESSIONS=0).
systemd-sleep[...]: Performing sleep operation 'suspend'...
kernel: PM: suspend entry (s2idle)
```

```
$ grep -iE 'notifier|S0ix|Preserve|TemporaryFilePath' /proc/driver/nvidia/params
PreserveVideoMemoryAllocations: 1
TemporaryFilePath: ""
UseKernelSuspendNotifiers: 1
EnableS0ixPowerManagement: 0
S0ixPowerManagementVideoMemoryThreshold: 256

$ systemctl cat nvidia-suspend.service | grep -i ExecCondition
ExecCondition=sh -c "/usr/bin/grep -qs 'UseKernelSuspendNotifiers: 0' /proc/driver/nvidia/params"
```

No virtual machines were running during the Oct 24 hang (libvirt logs show the
last guest shut down on Oct 23).
