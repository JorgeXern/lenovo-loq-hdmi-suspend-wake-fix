# Wake source tests (pm_debug_messages enabled)

All tests: `echo 1 | sudo tee /sys/power/pm_debug_messages`, then
`systemctl suspend`, hands off the input devices. Wi-Fi association lines
(which contain the router BSSID and the card's MAC) have been removed.

GPE counters were snapshotted from `/sys/firmware/acpi/interrupts/` before and
after each test. `gpe03` is the Embedded Controller GPE; its delta includes EC
traffic while awake, so only its presence matters, not its size.

## Test A — HDMI monitor connected, no kernel parameters

```
PM: Triggering wakeup from IRQ 9
PM: noirq suspend of devices complete after 177.627 msecs
ACPI: PM: Rearming ACPI SCI for wakeup
amd_pmc: SMU idlemask s0i3: 0x8fff1eb5
PM: Triggering wakeup from IRQ 9
PM: Triggering wakeup from IRQ 7
ACPI: PM: Wakeup after ACPI Notify sync
PM: noirq resume of devices complete after 329.139 msecs

$ cat /sys/power/pm_wakeup_irq
9
   9:  ...  IR-IO-APIC    9-fasteoi   acpi
```

Second run, with GPIO/EC detail:

```
Clearing debounce for GPIO #0 during suspend.
Disabling GPIO #8 interrupt for suspend.
Setting wake for GPIO 8 to enable
ACPI: EC: interrupt blocked
ACPI: EC: ACPI EC GPE status set
ACPI: EC: ACPI EC GPE status set
ACPI: EC: ACPI EC GPE dispatched
ACPI: EC: ACPI EC work flushed
ACPI: PM: Wakeup after ACPI Notify sync
ACPI: EC: interrupt unblocked
GPIO 4 is active: 0x30047c00
Setting wake for GPIO 8 to disable

GPE delta: gpe03 +393, sci +393
   7:  ...  IR-IO-APIC    7-fasteoi   pinctrl_amd
```

Result: woke by itself after ~5 s.

## Test B — HDMI cable disconnected

```
Clearing debounce for GPIO #0 during suspend.
Disabling GPIO #8 interrupt for suspend.
Setting wake for GPIO 8 to enable
ACPI: EC: interrupt blocked
ACPI: EC: ACPI EC GPE status set
ACPI: EC: ACPI EC GPE status set
ACPI: PM: Wakeup after ACPI Notify sync
ACPI: EC: interrupt unblocked
GPIO 0 is active: 0x3805f800
Setting wake for GPIO 8 to disable
```

Result: stayed asleep (power LED pulsing) until the power button was pressed
(`GPIO 0`). No `EC GPE dispatched`, no `GPIO 4`.

## Test C — HDMI connected, Samsung Anynet+ (HDMI-CEC) off, source detection changed

```
ACPI: EC: ACPI EC GPE dispatched
ACPI: EC: ACPI EC work flushed
ACPI: PM: Wakeup after ACPI Notify sync
GPIO 4 is active: 0x30047c00

PM: suspend entry (s2idle)   18:01:26
PM: suspend exit             18:01:32
```

Result: still woke by itself. Monitor settings are not the fix.

## Test D — HDMI connected, `acpi.ec_no_wakeup=1`

```
$ cat /sys/module/acpi/parameters/ec_no_wakeup
Y

PM: Triggering wakeup from IRQ 7
ACPI: PM: Wakeup unrelated to ACPI SCI
PM: Triggering wakeup from IRQ 9
GPIO 4 is active: 0x30047c00
PM: Triggering wakeup from IRQ 0

$ cat /sys/power/pm_wakeup_irq
7
   7:  ...  IR-IO-APIC    7-fasteoi   pinctrl_amd
```

Result: still woke by itself. With the EC path blocked, the same pin 4 now
wakes the system directly as a `pinctrl_amd` interrupt.

## Test E — HDMI connected, `gpiolib_acpi.ignore_wake=AMDI0030:00@4` (+ ec_no_wakeup)

```
$ cat /sys/module/gpiolib_acpi/parameters/ignore_wake
AMDI0030:00@4
$ sudo dmesg | grep -i 'ignoring wake'
[    0.706137] amd_gpio AMDI0030:00: Ignoring wakeup on pin 4

PM: Triggering wakeup from IRQ 7
PM: Triggering wakeup from IRQ 9
PM: Triggering wakeup from IRQ 0
GPIO 59 is active: 0x3801f900
```

Result: stayed asleep; woken only by the USB keyboard (`GPIO 59`).

## Test F — HDMI connected, `ignore_wake` only (ec_no_wakeup removed) — final config

```
$ cat /proc/cmdline | tr ' ' '\n' | grep -E 'ec_no_wakeup|ignore_wake'
gpiolib_acpi.ignore_wake=AMDI0030:00@4
$ cat /sys/module/acpi/parameters/ec_no_wakeup
N

PM: suspend entry (s2idle)        18:22:29
PM: Triggering wakeup from IRQ 9
ACPI: PM: Rearming ACPI SCI for wakeup
PM: Triggering wakeup from IRQ 9
PM: Triggering wakeup from IRQ 7
PM: Triggering wakeup from IRQ 0
GPIO 59 is active: 0x3801f900   18:23:23
PM: suspend exit                  18:23:25
```

Result: 54 s asleep, woken only by the USB keyboard. `ignore_wake` alone is enough.

## Test G — real power outage during suspend (final config)

```
18:50:58  slept    1409 s

PM: suspend entry (s2idle)        18:50:58
PM: Triggering wakeup from IRQ 9
PM: Triggering wakeup from IRQ 9
PM: Triggering wakeup from IRQ 7
PM: Triggering wakeup from IRQ 0
GPIO 59 is active: 0x3801f900     19:14:25
PM: suspend exit                  19:14:27
```

A ~6-minute mains power cut happened during this sleep: the laptop switched to
battery and back, and the HDMI monitor lost power and came back on. Neither
woke the machine; only the keyboard did, 23.5 minutes after it went to sleep.
