# EC wake loop with the lid closed, on battery (open investigation)

**Status: root cause unknown, no fix.** `acpi.ec_no_wakeup=1` was tried and does not stop the
loop (sections 5–7). Recommendation for now: shut the laptop down before carrying it in a bag.

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

## 5. First attempt: `acpi.ec_no_wakeup=1` (did not fix it)

Because every resume in sections 1–2 went through the EC GPE, `acpi.ec_no_wakeup=1` was
added next to the HDMI fix:

```
$ cat /proc/cmdline | tr ' ' '\n' | grep -E 'ec_no_wakeup|ignore_wake'
gpiolib_acpi.ignore_wake=AMDI0030:00@4
acpi.ec_no_wakeup=1
$ cat /sys/module/acpi/parameters/ec_no_wakeup
Y
```

Two clean sleeps followed, which at first looked like a fix:

| Test | Conditions | Result |
|---|---|---|
| 26 Oct 19:42 → 22:04 | battery, lid closed, no monitor | one suspend of 2 h 22 min, woken by the lid; ~0.5 W |
| 26 Oct 23:38 → 27 Oct 07:14 | battery (99 % → 93 %), lid closed, no monitor | one suspend of 7 h 36 min, woken by the lid; 0.46 W (`energy_now`) |

Power button check in the same boot (HDMI connected, lid open, `pm_debug_messages` on):

```
22:48:49  PM: suspend entry (s2idle)
22:49:55  PM: Triggering wakeup from IRQ 7
22:49:55  ACPI: PM: Wakeup unrelated to ACPI SCI
22:49:55  PM: Triggering wakeup from IRQ 9
22:49:55  GPIO 0 is active: 0x3805f800           <- power button, pressed by hand
22:49:57  PM: suspend exit
```

This already showed that pin 0 still wakes the system directly as a GPIO interrupt with
`ec_no_wakeup=1`. The next morning the loop came back (section 6): the two clean sleeps
happened because the trigger was absent, not because of the parameter.

## 6. Recurrence on 27 Oct with both parameters

The lid was closed at 07:21:03, on battery, after about 7 minutes of use; the laptop was
later carried in a bag. The loop started with the very first suspend and ran until the lid
was opened at 08:14:

```
07:21:03  Lid closed.
07:21:05  PM: suspend entry (s2idle)
07:21:12  PM: suspend exit
07:21:37  PM: suspend entry (s2idle)
07:21:44  PM: suspend exit
...                                               (same ~32 s cycle)
08:13:32  PM: suspend entry (s2idle)
08:13:40  PM: suspend exit
08:14:19  Lid opened.
```

About 98 cycles in 53 minutes. There was no charger at any point:

```
07:14:02  93 %  discharging       <- normal use, lid open: ~0.43 %/min (~15 W)
07:21:17  90 %  discharging       <- loop starts
08:11:48  41 %  discharging       <- ~0.97 %/min, about 33 W
```

Wake source, same boot:

```
$ cat /sys/power/pm_wakeup_irq
7                                                 <- pinctrl_amd, not the SCI

$ grep amd_gpio /proc/interrupts    (per-CPU columns summed)
amd_gpio  0   ACPI:Event      106     <- EC wake pin: ~98 loop wakes + lid/button wakes
amd_gpio  59  ACPI:Event        1     <- USB (Bolt receiver)
amd_gpio  4   ACPI:Event        0     <- HDMI pin, ignored
amd_gpio  8   SYNA2BA6:00    6254     <- touchpad interrupts while awake (normal use)
```

With the GPE path blocked, the EC now wakes the system through pin 0 directly, as pin 4 did
in Test D of [03-wake-source-tests.md](03-wake-source-tests.md). Pin 0 cannot be ignored: it
carries the lid and the power button.

One `NVRM: RmHandleDNotifierEvent: Failed to handle ACPI D-Notifier event, status=0x11`
appeared during the loop (a firmware power-limit notification to the dGPU).

## 7. Controlled reproduction (27 Oct 08:23)

Laptop warm from the previous loop (`acpitz` 44 °C), on battery, no monitor, lid closed on a
desk. `pm_debug_messages` on, `udevadm monitor --kernel --subsystem-match=power_supply
--subsystem-match=thermal` recording.

Result over 123 minutes: **56 suspends, 56 pin-0 interrupts**, 4.7 W average.

Every wake has the same chain:

```
08:24:00  PM: suspend entry (s2idle)
08:24:07  PM: Triggering wakeup from IRQ 7
08:24:07  ACPI: PM: Wakeup unrelated to ACPI SCI
08:24:07  PM: Triggering wakeup from IRQ 9
08:24:07  GPIO 0 is active: 0x3805f800
08:24:08  PM: suspend exit
```

udev recorded **3,446 `change` events for `BAT0`**, at a fixed ~0.5 s cadence while awake,
with bursts of identical timestamps right after each resume (notifications queued during sleep):

```
KERNEL[9760.232503] change  .../PNP0C09:00/PNP0C0A:00/power_supply/BAT0 (power_supply)
KERNEL[9760.732490] change  .../PNP0C09:00/PNP0C0A:00/power_supply/BAT0 (power_supply)
KERNEL[9761.299811] change  .../PNP0C09:00/PNP0C0A:00/power_supply/BAT0 (power_supply)
KERNEL[9761.732483] change  .../PNP0C09:00/PNP0C0A:00/power_supply/BAT0 (power_supply)
...
KERNEL[9767.824665] change  .../PNP0C09:00/PNP0C0A:00/power_supply/BAT0 (power_supply)
KERNEL[9767.824816] change  .../PNP0C09:00/PNP0C0A:00/power_supply/BAT0 (power_supply)
KERNEL[9767.824886] change  .../PNP0C09:00/PNP0C0A:00/power_supply/BAT0 (power_supply)
```

`PNP0C09` is the EC and `PNP0C0A` the battery under it. A 0.5 s period is a timer, not a
physical change.

This time the loop **stopped by itself** on the desk:

```
08:51:53  slept      9 s
08:52:27  slept      8 s
08:53:00  slept      7 s
08:53:32  slept      8 s
08:54:05  slept   5514 s      <- 1 h 32 min, woken by opening the lid
```

```
          before (08:23)   after (10:26)
acpitz        44 °C            26 °C
```

Afterwards, awake, cool and on AC: `udevadm monitor` for 10 s showed **0** `BAT0` events.

## 8. Suspend hang without HDMI (27 Oct 11:05)

During later tests (a few suspends after a reboot; about 160 cycles earlier that day), one
suspend hung: power LED solid,
black screen, no response, forced power-off. The journal of that boot ends at:

```
11:05:57  systemd[1]: nvidia-suspend.service: Skipped due to 'exec-condition'.
11:05:57  systemd[1]: Starting systemd-suspend.service - System Suspend...
11:05:57  systemd-sleep: Performing sleep operation 'suspend'...
11:05:57  kernel: PM: suspend entry (s2idle)
```

Same signature as the hangs in [01-hang-history.md](01-hang-history.md), but with **no
external monitor connected**. The hang is not specific to the HDMI case; the loop raises the
odds simply by multiplying suspend cycles.

Earlier that morning, after the loops in sections 6–7, HDMI hot-plug detection had also
stopped working (the monitor stayed `disconnected` in `/sys/class/drm`) until a reboot.

## 9. Hypotheses and open questions

- **Why the EC notifies `BAT0` every 0.5 s.** Leading hypothesis: a battery or thermal
  condition reached while the machine is warm. It fits all observations so far (loops started
  when the lid was closed soon after use; clean sleeps started cool; the desk loop stopped as
  it cooled). Not confirmed: no battery temperature reading is exposed under Linux here.
- **Which EC query and wake reason.** Pin 0's `_EVT` handler calls `HWAK`, which reads the
  EC's wake reason and notifies `LID0`, `ADP0`, `BAT0` or `PWRB`
  ([04-acpi-excerpts.md](04-acpi-excerpts.md)). Identifying the `_Qxx` method needs the EC
  query trace (`dyndbg` for `drivers/acpi/ec.c`, passed as a boot parameter because Secure
  Boot lockdown blocks debugfs) and the disassembled DSDT.
- **Why Linux resumes fully.** A battery status notification is not a reason to wake the
  user. The kernel cannot tell it apart from a lid or power-button event when it arrives
  through pin 0, so it resumes. How the platform is meant to handle this (e.g. under Windows
  Modern Standby) is not known.
- **Lid wake with `ec_no_wakeup=1`.** Works on this model; the power button test above
  shows pin 0 remains a direct wake source with the parameter set.
