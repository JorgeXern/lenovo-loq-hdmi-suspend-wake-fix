# EC wake loop with the lid closed, on battery (second failure mode)

Found on 2026-10-26, two days after the HDMI fix (`gpiolib_acpi.ignore_wake=AMDI0030:00@4`
only) was in place. The laptop was put in a bag with the lid closed and no external
monitor. Opened 73 minutes later, it was hot with the fans running.

Same machine as in the [README](../README.md#tested-system), kernel `7.2.11-200.fc44`.
Usernames, hostnames, disk/LUKS UUIDs and peripheral identifiers have been removed
from the output below.

## 1. Real sleep time per cycle

Kernel `PM: suspend entry` → `PM: suspend exit`, from the journal of that boot.
"awake before" is the time between the previous `suspend exit` and this `suspend entry`.

```
26 17:16:42  slept   3193 s                      <- lid closed 17:16:26, clean sleep
26 18:10:21  slept     26 s  awake before  26 s
26 18:11:12  slept     11 s  awake before  25 s
26 18:11:47  slept      9 s  awake before  24 s
26 18:12:21  slept      8 s  awake before  25 s
26 18:12:53  slept      9 s  awake before  24 s
26 18:13:26  slept      8 s  awake before  24 s
26 18:13:59  slept     13 s  awake before  25 s
...
26 19:19:38  slept     12 s  awake before  24 s
26 19:20:15  slept     11 s  awake before  25 s
26 19:20:50  slept     62 s  awake before  24 s
26 19:22:16  slept      9 s  awake before  24 s  <- lid opened 19:22:18
```

| Window | Cycles | Sleep (median, min–max) | Awake (median) | Share of time asleep |
|---|---|---|---|---|
| 26 Oct 18:10–19:22, in the bag | 119 | 9 s (8–62 s) | 24 s | 34 % |
| 25 Oct 23:10–23:31, lid closed | 33 | 8 s (8–40 s) | 25 s | 37 % |

The ~24 s awake phase is logind: after each resume it sees the lid still closed and
suspends again (`HandleLidSwitch=suspend`). There were no `Lid opened` events inside
either window.

```
$ grep -rhE "^\s*(HandleLid|LidSwitchIgnore)" /etc/systemd/logind.conf /etc/systemd/logind.conf.d/
HandleLidSwitch=suspend
HandleLidSwitchExternalPower=suspend
HandleLidSwitchDocked=ignore

$ grep -H . /sys/power/suspend_stats/{success,fail,failed_suspend,failed_resume}
/sys/power/suspend_stats/success:180
/sys/power/suspend_stats/fail:0
/sys/power/suspend_stats/failed_suspend:0
/sys/power/suspend_stats/failed_resume:0
```

Every suspend succeeded; the problem is what wakes the machine.

## 2. Wake chain

`pm_debug_messages` was still enabled in that boot (left on from the tests in
[03-wake-source-tests.md](03-wake-source-tests.md)), so the kernel logged the full chain.

```bash
journalctl -k -b -1 --since "2026-10-26 18:09:50" --until "2026-10-26 18:12:00" \
  | grep -E "Triggering wakeup|GPIO [0-9]+ is active|SCI|Notify|EC GPE|suspend (entry|exit)"
```

**First wake, 18:09:53: USB (it started the loop).** Something pressed or moved in the bag:

```
18:09:53  PM: Triggering wakeup from IRQ 9
18:09:53  ACPI: EC: ACPI EC GPE status set
18:09:53  ACPI: PM: Rearming ACPI SCI for wakeup
18:09:53  PM: Triggering wakeup from IRQ 7
18:09:53  PM: Triggering wakeup from IRQ 9
18:09:53  ACPI: PM: ACPI non-EC GPE wakeup
18:09:53  PM: Triggering wakeup from IRQ 0
18:09:53  GPIO 59 is active: 0x3801f900          <- XHC1, Logi Bolt receiver
18:09:55  PM: suspend exit
```

**Every following wake: the EC.** The kernel handles several EC events and goes back to
sleep each time, until one of them ends in an ACPI Notify that resumes the system:

```
18:11:12  PM: suspend entry (s2idle)
18:11:22  PM: Triggering wakeup from IRQ 9
18:11:22  ACPI: EC: ACPI EC GPE status set
18:11:22  ACPI: PM: Rearming ACPI SCI for wakeup
18:11:22  PM: Triggering wakeup from IRQ 9
18:11:22  ACPI: EC: ACPI EC GPE status set
18:11:22  ACPI: EC: ACPI EC GPE dispatched
18:11:22  ACPI: PM: Rearming ACPI SCI for wakeup
18:11:22  PM: Triggering wakeup from IRQ 9
18:11:22  ACPI: EC: ACPI EC GPE status set
18:11:22  ACPI: PM: Rearming ACPI SCI for wakeup
18:11:22  PM: Triggering wakeup from IRQ 9
18:11:22  PM: Triggering wakeup from IRQ 7
18:11:22  ACPI: EC: ACPI EC GPE status set
18:11:22  ACPI: EC: ACPI EC GPE dispatched
18:11:22  ACPI: PM: Wakeup after ACPI Notify sync
18:11:22  GPIO 0 is active: 0x3805f800           <- EC wake pin (_EVT pin 0)
18:11:23  PM: suspend exit

18:11:47  PM: suspend entry (s2idle)
18:11:54  PM: Triggering wakeup from IRQ 9
18:11:54  ACPI: EC: ACPI EC GPE status set
18:11:54  ACPI: PM: Rearming ACPI SCI for wakeup
18:11:54  PM: Triggering wakeup from IRQ 9
18:11:54  PM: Triggering wakeup from IRQ 7
18:11:54  ACPI: EC: ACPI EC GPE status set
18:11:54  ACPI: EC: ACPI EC GPE dispatched
18:11:54  ACPI: PM: Wakeup after ACPI Notify sync
18:11:54  GPIO 0 is active: 0x3805f800
18:11:56  PM: suspend exit
```

The resume at 18:10:46 has the same shape with more events before the Notify: 20 SCI
wakes and 8 EC dispatches, ending in `Wakeup after ACPI Notify sync` and `GPIO 0 is active`.

Across the boot, **all 118 resumes of this loop and all 32 of the 25 Oct loop** have
`ACPI EC GPE dispatched` at the same timestamp. Outside the loops it appears only in a
few isolated short self-wakes and in one 24-minute sleep; most long sleeps ended by
opening the lid or pressing a key show only `ACPI EC GPE status set`.

## 3. Counters (taken after the loop, same boot)

```
$ cat /sys/power/pm_wakeup_irq
9                                                 <- ACPI SCI

$ journalctl -k -b | grep "ACPI: EC: GPE"
ACPI: EC: GPE=0x3

$ grep -H . /sys/firmware/acpi/interrupts/gpe* | awk -F: '$2+0>0'
/sys/firmware/acpi/interrupts/gpe_all:  573705
/sys/firmware/acpi/interrupts/gpe03:  573700  EN     enabled      unmasked
/sys/firmware/acpi/interrupts/gpe19:       5  EN     enabled      unmasked
```

`gpe03` includes EC traffic while awake, so its size is not a wake count; what matters
is that the EC accounts for practically all GPE activity.

Wakeup sources (`/sys/class/wakeup/*`, `wakeup_count` / `event_count` / `name`):

```
0	8	PNP0C0D:00          <- lid
0	17	ADP0                <- AC adapter
0	17	3-2                 <- USB device (Bolt receiver port)
0	5	0000:05:00.3        <- xHCI
0	39	0000:05:00.4        <- xHCI
0	1	PNP0C0C:00          <- power button
```

`wakeup_count` is 0 for every source: s2idle wakes through the SCI are not attributed to
a device here, so this column cannot identify the source. The xHCI `event_count` values
(5 and 39) are far below the more than 100 wakes in the bag, which rules out USB as the
driver of the loop.

## 4. Power draw and hardware state

UPower battery history (timestamps converted to local time, UTC-3):

```
18:59:47  75 %  discharging
19:23:11  63 %  discharging          <- 12 % in 23 min 24 s
19:24:53  64 %  charging             <- plugged in after opening the bag
19:36:25  76 %  charging
```

12 % of 57.5 Wh in 23.4 minutes is about **17 W** on average, inside a closed bag.
Earlier samples were not recorded, so the total drain since 18:09 is larger.

After the episode:

```
$ upower -i $(upower -e | grep BAT) | grep -E "energy-full|capacity|cycle"
    energy-full:         57,5 Wh
    energy-full-design:  57,5 Wh
    charge-cycles:       26
    capacity:            100%

$ sudo smartctl -a /dev/nvme0n1 | grep -iE "critical warning|warning.*time|^temperature"
Critical Warning:                   0x00
Temperature:                        48 Celsius
Warning  Comp. Temperature Time:    0
Critical Comp. Temperature Time:    0
```

No measurable battery degradation and the NVMe never reached its warning temperature.
Heat damage to a battery cell can take a while to show; recheck `capacity` after a few weeks.

## 5. Fix and validation

```
$ sudo grubby --update-kernel=ALL --args="acpi.ec_no_wakeup=1"
$ sudo reboot

$ cat /proc/cmdline | tr ' ' '\n' | grep -E 'ec_no_wakeup|ignore_wake'
gpiolib_acpi.ignore_wake=AMDI0030:00@4
acpi.ec_no_wakeup=1
$ cat /sys/module/acpi/parameters/ec_no_wakeup
Y
```

Lid test: charger unplugged, lid closed, no monitor, left alone for over two hours.

```
$ journalctl -b --since "19:40" -o short-iso | grep -E "PM: suspend (entry|exit)|Lid (opened|closed)"
2026-10-26T19:41:59-03:00  systemd-logind: Lid closed.
2026-10-26T19:42:01-03:00  kernel: PM: suspend entry (s2idle)
2026-10-26T22:04:07-03:00  systemd-logind: Lid opened.
2026-10-26T22:04:09-03:00  kernel: PM: suspend exit

$ cat /sys/class/power_supply/BAT*/capacity     # 81 before, 79 after
```

Result: **one suspend of 2 h 22 min**, woken by opening the lid. 2 % of 57.5 Wh in
2.37 h is about 0.85 %/h, or 0.5 W. Before the fix: 119 cycles in 73 minutes.

`pm_debug_messages` was **off** during the lid test (it does not survive the reboot), so
the absence of `ACPI EC GPE dispatched` lines there is not evidence by itself. The evidence
is the uninterrupted sleep time.

Power button, same boot, HDMI monitor and charger connected, lid open,
`pm_debug_messages` enabled again for this test:

```
22:48:49  PM: suspend entry (s2idle)
22:49:55  PM: Triggering wakeup from IRQ 7
22:49:55  ACPI: PM: Wakeup unrelated to ACPI SCI
22:49:55  PM: Triggering wakeup from IRQ 9
22:49:55  GPIO 0 is active: 0x3805f800           <- power button, pressed by hand
22:49:57  PM: suspend exit
```

66 s asleep untouched with the HDMI monitor connected (so `ignore_wake` still holds with
both parameters), then woken by the power button as a **direct GPIO interrupt**: pin 0
remains a wake source with `ec_no_wakeup=1`.

## 6. Not determined

- Whether the EC events began with the USB resume at 18:09:53 or with a power-source
  change around that time. The 53 minutes before were clean.
- Which `_Qxx` method runs and which device receives the Notify. Pin 0's `_EVT` handler
  serves `LID0`, `ADP0`, `BAT0` and `PWRB` ([04-acpi-excerpts.md](04-acpi-excerpts.md)).
  With the lid closed, no AC change and the battery discharging, `BAT0` is the most
  plausible target. Confirming it needs EC query tracing during suspend, which this
  machine's Secure Boot lockdown makes harder (no debugfs; `dyndbg` only as a boot parameter).
- Why the lid still wakes the machine with `ec_no_wakeup=1`. The likely explanation is
  that the EC asserts its wake pin directly for the lid but only through a query for
  these other events. The power button test supports it (pin 0 wakes directly as a GPIO
  interrupt with the parameter set), but the lid wake itself was not traced with
  `pm_debug_messages`.
