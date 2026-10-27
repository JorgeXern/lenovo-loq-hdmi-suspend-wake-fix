# Lenovo LOQ: wakes from suspend seconds after sleeping when an HDMI monitor is connected

**[Leer en español](README.es.md)**

> **Update 2026-10-26: second failure mode and corrected recommendation.**
> With the lid closed **on battery** (for example inside a bag) the Embedded Controller can also wake the laptop in a loop: about 9 s asleep and 24 s awake, repeated for over an hour, enough to make it hot with the fans running inside the bag. `gpiolib_acpi.ignore_wake` does not cover this; `acpi.ec_no_wakeup=1` does.
> Earlier versions of this README said `ec_no_wakeup` was not needed and would block the lid. **Both claims were wrong.** The recommended configuration is now **both parameters**. Details in [Second failure mode](#second-failure-mode-ec-wake-loop-lid-closed-on-battery).

On the Lenovo LOQ 15ARP10E (AMD Ryzen 7 7735HS + NVIDIA RTX 4050, HDMI wired to the dGPU), suspending with an external HDMI monitor connected makes the laptop wake up again after 5–7 seconds. GNOME suspends it again after the idle timeout and the cycle repeats all night. Every cycle is a new chance for the suspend/resume transition to hang, which shows up as the classic *"it went to sleep and never came back"*.

**Fix (workaround):** two kernel parameters, one per failure mode.

```bash
sudo grubby --update-kernel=ALL --args="gpiolib_acpi.ignore_wake=AMDI0030:00@4 acpi.ec_no_wakeup=1"
sudo reboot
```

| Parameter | What it stops |
|---|---|
| `gpiolib_acpi.ignore_wake=AMDI0030:00@4` | GPIO pin 4 (dGPU) waking the system seconds after suspend when an HDMI monitor is connected |
| `acpi.ec_no_wakeup=1` | Embedded Controller events waking the system from s2idle, which loops when the lid is closed on battery |

Pin 4 keeps working as a runtime ACPI event and the EC keeps working while awake; they just can no longer wake the system. The power button, the USB keyboard/mouse and the lid keep waking it (all verified with the two parameters); see [What still wakes the machine](#what-still-wakes-the-machine).

That command is for Fedora/RHEL (`grubby`). For Ubuntu, Debian, Mint, Arch, Pop!_OS and others see [Other distributions](#other-distributions), or let [`diagnose-spurious-wake.sh`](#diagnosing-and-fixing-with-the-script) find the wake source and apply the fix for you after asking. The script currently handles the HDMI part only; add `acpi.ec_no_wakeup=1` by hand.

---

## Contents

- [Tested system](#tested-system)
- [Symptoms](#symptoms)
- [Root cause](#root-cause)
- [Second failure mode: EC wake loop (lid closed, on battery)](#second-failure-mode-ec-wake-loop-lid-closed-on-battery)
- [Applying and verifying the fix](#applying-and-verifying-the-fix)
- [Other distributions](#other-distributions)
- [What still wakes the machine](#what-still-wakes-the-machine)
- [Things that did not fix it](#things-that-did-not-fix-it)
- [Diagnosing and fixing with the script](#diagnosing-and-fixing-with-the-script)
- [Reverting](#reverting)
- [Related reports and upstream position](#related-reports-and-upstream-position)

## Tested system

| | |
|---|---|
| DMI | `LENOVO` / `83S0` / `LOQ 15ARP10E` |
| Board | `LNVNB161216` |
| BIOS | `SUCN18WW` (2026-04-22) |
| CPU / iGPU | AMD Ryzen 7 7735HS (Rembrandt), Radeon 680M — drives the internal panel |
| dGPU | NVIDIA RTX 4050 Laptop — drives the **HDMI** port |
| GPIO controller | `AMDI0030:00` (`pinctrl_amd`, IRQ 7) |
| Sleep states | `mem_sleep` = `[s2idle]` only (no S3) |
| OS | Fedora 44 Workstation, GNOME (Wayland), LUKS2 + Btrfs, Secure Boot on |
| Kernels | 7.2.9, 7.2.10, 7.2.11 (`-200.fc44`) — all affected |
| NVIDIA | 615.71.09 and 615.78.08 (RPM Fusion akmod), `UseKernelSuspendNotifiers=1` — both affected |
| Monitor | Samsung Odyssey G7 G70D over HDMI |

The board name `LNVNB161216` is the same one reported for the Lenovo Legion Pro 5 16ARX8 with the same problem on the same pin (see [related reports](#related-reports-and-upstream-position)), so other LOQ/Legion models on this board family are likely affected too.

## Symptoms

- With the HDMI monitor connected, `systemctl suspend` (or idle auto-suspend) wakes the laptop **5–7 seconds later**. The monitor lights up showing nothing or the GDM login, then blanks again.
- Without an external monitor, suspend works fine (power LED pulses, the machine stays asleep).
- In one day the journal showed **99 suspend cycles** in a single boot, every ~15 minutes from 04:39 to 16:08, each one lasting 5–7 seconds:

  ```
  24 04:39:08  slept       5 s
  24 04:54:14  slept       5 s
  24 05:09:20  slept       5 s
  ...
  24 15:53:45  slept       7 s
  24 16:08:55  slept       7 s
  ```

- Occasionally one of those transitions **hangs**: power LED solid (not pulsing), no keyboard backlight, screen off, no response. Only a forced power-off recovers it. The kernel log of that boot ends at `PM: suspend entry (s2idle)` with nothing after it.
- Over 15 days: **6 hangs in ~330 suspend cycles** (≈ 1 in 55), spread across three kernel versions and two NVIDIA driver versions — not a single bad release.

## Root cause

Measured with `pm_debug_messages` enabled (`echo 1 | sudo tee /sys/power/pm_debug_messages`):

With the monitor connected, every self-wake reports **`GPIO 4 is active`**. Without the monitor, the only wake is the one you trigger (e.g. `GPIO 0` for the power button).

| Test | Wake reported | Result |
|---|---|---|
| HDMI connected | EC GPE dispatched → `Wakeup after ACPI Notify` → `GPIO 4 is active` | wakes after ~5 s |
| HDMI disconnected | `GPIO 0 is active` (power button, pressed by hand) | stays asleep |
| HDMI connected + `acpi.ec_no_wakeup=1` | IRQ 7 (`pinctrl_amd`), `Wakeup unrelated to ACPI SCI`, `GPIO 4 is active` | still wakes |
| HDMI connected + `gpiolib_acpi.ignore_wake=AMDI0030:00@4` | `GPIO 59 is active` (USB keyboard, pressed by hand) | stays asleep ✔ |

The firmware explains why. In `SSDT22`, the GPIO controller's `_AEI` declares pin 4 as a both-edge **wake-capable** interrupt, and its `_EVT` handler notifies the NVIDIA dGPU:

```asl
// _SB.GPIO._AEI
GpioInt (Edge, ActiveBoth, ExclusiveAndWake, PullNone, 0x0000,
    "\\_SB.GPIO", 0x00, ResourceConsumer, ,)
    {   // Pin list
        0x0004
    }

// _SB.GPIO._EVT
Case (0x04)
{
    If (((DSMF == 0x03) || (DSMF == 0x04)))
    {
        \_SB.GZFD.HTPE ()
        Sleep (0x05)
    }
    Notify (\_SB.PCI0.GPP0.PEGP, 0x81) // Information Change -> dGPU
}
```

So: while suspending with the dGPU driving the HDMI output, pin 4 sees a transition; because the BIOS marked it `ExclusiveAndWake`, that transition wakes the whole system. Pin 4's exact electrical function isn't documented. It is a dGPU→platform signal, but it is **not** necessarily the HDMI hot-plug line.

Because pin 4 **is declared in ACPI**, `gpiolib_acpi.ignore_wake=` can target it: the kernel skips `enable_irq_wake()` for that pin, while the `_EVT` notification still runs at runtime.

The rest of the `_EVT` table matches what was observed:

| Pin | `_EVT` action | Observed |
|---|---|---|
| 0 | EC `HWAK` → `LID0` / `ADP0` / `BAT0` / `PWRB` | power button wake |
| 4 | `Notify (GPP0.PEGP, 0x81)` (dGPU) | the spurious wake |
| 0x3B (59) | `Notify (GP17.XHC1, 0x02)` (USB controller) | wake from the USB keyboard receiver |

`GZFD.HTPE` / `DSMF` look like Lenovo "Gaming Zone" / GPU-mode logic; their exact role is unknown and not needed for the workaround.

Full logs and table excerpts are in [`evidence/`](evidence/): [hang history](evidence/01-hang-history.md), [bounce cycles](evidence/02-bounce-cycles.md), [wake source tests A–H](evidence/03-wake-source-tests.md), [ACPI `_AEI`/`_EVT`](evidence/04-acpi-excerpts.md) and [EC wake loop](evidence/05-ec-wake-loop.md).

## Second failure mode: EC wake loop (lid closed, on battery)

Found two days after the HDMI fix was in place: the laptop was put in a bag with the lid closed, **on battery**, no external monitor. Opened 73 minutes later, it was hot with the fans running.

**Symptoms** (from the journal of that boot):

- **119 suspend/resume cycles** between 18:10 and 19:22. Each one slept about 9 s (kernel `suspend entry` → `suspend exit`), then stayed awake about 24 s until logind saw the lid still closed and suspended it again. The machine was awake roughly two thirds of the time.
- Battery: **75 % → 63 % in 23 minutes**, about **17 W** on average, against about 0.5 W in a healthy suspend. Inside a bag that power turns into heat.
- The same loop had already happened the night before (33 cycles in 21 minutes, lid closed) and in shorter bursts.
- No `Lid opened` events during the loop, `HandleLidSwitch=suspend`, 0 failed suspends: logind and the suspend itself were working as designed.

**Wake chain** (`pm_debug_messages` was still enabled in that boot):

```
PM: suspend entry (s2idle)
PM: Triggering wakeup from IRQ 9               <- ACPI SCI
ACPI: EC: ACPI EC GPE status set
ACPI: EC: ACPI EC GPE dispatched               <- EC event handled, back to sleep
ACPI: PM: Rearming ACPI SCI for wakeup
...                                            (repeats several times)
PM: Triggering wakeup from IRQ 7               <- pinctrl_amd
ACPI: EC: ACPI EC GPE dispatched
ACPI: PM: Wakeup after ACPI Notify sync        <- a Notify reached a wake-armed device
GPIO 0 is active: 0x3805f800                   <- EC wake pin (_EVT pin 0)
PM: suspend exit
```

| Evidence | Value | Meaning |
|---|---|---|
| `/sys/power/pm_wakeup_irq` | `9` | ACPI SCI, not a device interrupt |
| EC GPE (boot log) | `ACPI: EC: GPE=0x3` | the EC uses GPE 0x03 |
| `/sys/firmware/acpi/interrupts/gpe03` | 573,700 of 573,705 GPE events | practically all SCI traffic comes from the EC |
| xHCI wakeup counters | 5 and 39 events | USB cannot explain more than 100 wakes |
| Every resume in the loop | `EC GPE dispatched` → `Wakeup after ACPI Notify` → `GPIO 0` | an EC event runs a handler that Notifies a device, and the kernel resumes |

The loop started after 53 minutes of clean sleep, with an incidental USB wake at 18:09:53 (`GPIO 59`, the Bolt receiver, reported as `ACPI non-EC GPE wakeup`). From the next suspend on, every wake came from the EC.

**Not determined:** whether the EC events began with that resume or with a power-source change, and which `_Qxx` method and which device received the Notify. Pin 0's `_EVT` handler serves `LID0`, `ADP0`, `BAT0` and `PWRB`. With the lid closed, no AC change and the battery discharging, `BAT0` is the most plausible target, but it was not confirmed.

**Why `acpi.ec_no_wakeup=1` fixes it:** it disables the EC GPE as a wake source during s2idle, so these EC events are no longer processed while suspended and never reach the Notify that resumes the system. The lid still wakes this machine with the parameter set, which suggests the EC asserts its wake pin directly for the lid but only through a query for these other events. That last part is inferred, not measured. It is consistent with the power button test: with both parameters set, the power button wakes the machine as a direct GPIO interrupt (`Wakeup unrelated to ACPI SCI`, `GPIO 0 is active`), so pin 0 is still a wake source and only the EC GPE path is gone.

**Validation** with both parameters, on battery, lid closed, no monitor: **one suspend of 2 h 22 min** (19:42 → 22:04), woken by opening the lid. Battery 81 % → 79 %, about 0.85 %/h or 0.5 W. Before: 119 cycles in 73 minutes. With the HDMI monitor connected and both parameters: 66 s asleep untouched, woken by the power button.

`ACPI EC GPE …` lines are printed only while `pm_debug_messages` is enabled, and that setting does not survive a reboot. Their absence after a reboot proves nothing; judge by how long the machine actually stayed asleep.

**Why the original tests missed it:** tests A–H ran on AC power, at a desk, mostly with the monitor connected. This failure mode needs the lid closed on battery for several minutes.

Logs and counters: [`evidence/05-ec-wake-loop.md`](evidence/05-ec-wake-loop.md).

## Applying and verifying the fix

```bash
# 1) Confirm your GPIO controller name (on Rembrandt/Raphael it is AMDI0030:00)
ls /sys/bus/platform/drivers/amd_gpio/

# 2) Add both parameters to all installed kernels (Fedora)
sudo grubby --update-kernel=ALL --args="gpiolib_acpi.ignore_wake=AMDI0030:00@4 acpi.ec_no_wakeup=1"
sudo reboot

# 3) After reboot
cat /sys/module/gpiolib_acpi/parameters/ignore_wake   # AMDI0030:00@4
sudo dmesg | grep -i 'ignoring wake'                   # amd_gpio AMDI0030:00: Ignoring wakeup on pin 4
cat /sys/module/acpi/parameters/ec_no_wakeup           # Y
```

Then test both scenarios:

1. **HDMI:** suspend with the monitor connected and don't touch anything for a minute. The power LED should keep pulsing. Or run [`diagnose-spurious-wake.sh`](#diagnosing-and-fixing-with-the-script).
2. **Lid closed on battery:** unplug the charger, close the lid and leave it 15–20 minutes, then open it. It should wake on lid open, and the journal should show a single suspend:

   ```bash
   journalctl -b --since "-25 min" -o short-iso | grep -E "PM: suspend (entry|exit)|Lid (opened|closed)"
   ```

   Check that opening the lid wakes it. If on your model it doesn't, the power button and a USB keyboard still do; please open an issue.

Validation on the tested system: 23.5 minutes of uninterrupted sleep with the HDMI monitor connected, **including a real 6-minute power outage** (AC unplugged/replugged and the monitor power-cycled) without a single wake; woken only by the keyboard.

First full night with the fix: **one** suspend of **9 h 51 min** (00:10 → 10:02), woken by the keyboard (`GPIO 59`). The night before, without the fix, there were about 60 suspends of 5–7 s each, ending in a hang.

With both parameters, on battery and with the lid closed: one suspend of 2 h 22 min, woken by opening the lid ([second failure mode](#second-failure-mode-ec-wake-loop-lid-closed-on-battery)).

After a kernel update, check `cat /proc/cmdline` still contains both parameters. After a **BIOS update**, re-run the diagnosis: the pin number could change.

## Other distributions

The workaround is two plain kernel parameters, so it works on any distribution; only the way to add it changes. Check your controller name first with `ls /sys/bus/platform/drivers/amd_gpio/`, then:

| Distribution / bootloader | Add the parameter | Then |
|---|---|---|
| Fedora, RHEL, CentOS Stream | `sudo grubby --update-kernel=ALL --args="gpiolib_acpi.ignore_wake=AMDI0030:00@4 acpi.ec_no_wakeup=1"` | reboot |
| Ubuntu, Debian, Linux Mint, Zorin (GRUB) | append `gpiolib_acpi.ignore_wake=AMDI0030:00@4 acpi.ec_no_wakeup=1` inside the quotes of `GRUB_CMDLINE_LINUX_DEFAULT` in `/etc/default/grub` | `sudo update-grub`, reboot |
| Arch, Manjaro, EndeavourOS (GRUB) | same edit of `/etc/default/grub` | `sudo grub-mkconfig -o /boot/grub/grub.cfg`, reboot |
| openSUSE (GRUB 2) | same edit of `/etc/default/grub` (or YaST → Boot Loader) | `sudo grub2-mkconfig -o /boot/grub2/grub.cfg`, reboot |
| Pop!_OS (kernelstub) | `sudo kernelstub -a "gpiolib_acpi.ignore_wake=AMDI0030:00@4 acpi.ec_no_wakeup=1"` | reboot |
| systemd-boot | add both to the `options` line of your entries in `/boot/loader/entries/*.conf`, or to `/etc/kernel/cmdline` if your distro regenerates entries with `kernel-install` | reboot |

Verify exactly as above (`cat /sys/module/gpiolib_acpi/parameters/ignore_wake`, `dmesg | grep -i 'ignoring wake'` and `cat /sys/module/acpi/parameters/ec_no_wakeup`).

Models whose USB-C/DisplayPort output also self-wakes may need a second pin: the Legion Pro 5 16ARX8 uses `AMDI0030:00@2,AMDI0030:00@4`. The script below finds the right pins for your machine.

## What still wakes the machine

Status with both parameters (`ignore_wake` + `ec_no_wakeup`):

| Source | Pin | Status |
|---|---|---|
| USB keyboard/mouse (Logi Bolt receiver) | GPIO 59 → `XHC1` | ✔ verified, works with the lid closed ([test E](evidence/03-wake-source-tests.md)) |
| Lid open | GPIO 0 (EC → `LID0`) | ✔ verified on 2026-10-26 (2 h 22 min suspend, on battery) |
| Power button | GPIO 0 | ✔ verified on 2026-10-26 (direct GPIO wake: `Wakeup unrelated to ACPI SCI`, `GPIO 0 is active`) |
| AC adapter plug/unplug | GPIO 0 (EC → `ADP0`) | does **not** wake (observed during a power outage, with `ignore_wake` alone) |

Lid wake with `ec_no_wakeup` is verified on this model only. Other models may route the lid through the EC differently: check it after applying.

## Things that did not fix it

- **Monitor settings:** turning off Anynet+ (HDMI-CEC) and changing source detection on the Samsung did not help.
- **`acpi.ec_no_wakeup=1` alone, for the HDMI wake:** it removed the EC path from the picture, but the wake then arrived directly as a GPIO interrupt (`Wakeup unrelated to ACPI SCI`, still `GPIO 4`), so it does not fix the HDMI case by itself. It **is** needed for the [second failure mode](#second-failure-mode-ec-wake-loop-lid-closed-on-battery), and on this model it does not block the lid. *An earlier version of this README said it was not needed and would block the lid; both statements were wrong.*
- **NVIDIA suspend services:** with `UseKernelSuspendNotifiers: 1`, `nvidia-suspend.service` / `nvidia-resume.service` are **skipped by design** (`ExecCondition` only runs them when that value is 0). `PreserveVideoMemoryAllocations: 1` and empty `TemporaryFilePath` are also expected in that mode. Neither is the cause.
- **Longer idle timeout:** it would only reduce the number of cycles, not stop the self-wakes.

## Diagnosing and fixing with the script

[`diagnose-spurious-wake.sh`](diagnose-spurious-wake.sh) runs the whole procedure in one go:

1. Enables PM debug messages, suspends, and waits for the resume.
2. Reports the real sleep time, the wake IRQ and its owner, the `GPIO N is active` lines, EC/Notify activity and GPE deltas.
3. If `acpica-tools` is installed, looks up each waking pin in `_AEI` and `_EVT`.
4. If, and only if, the wake was spurious (slept less than 30 s) and the pin is not a legitimate wake source, it proposes the `gpiolib_acpi.ignore_wake=` value and asks **`[y/N]`** before changing anything.

```bash
sudo dnf install acpica-tools          # Fedora  (Debian/Ubuntu: sudo apt install acpica-tools)
chmod +x diagnose-spurious-wake.sh
./diagnose-spurious-wake.sh            # diagnose; offer the fix only if it is needed
./diagnose-spurious-wake.sh --dry-run  # same, but only show what it would change
./diagnose-spurious-wake.sh --revert   # remove the parameter again
```

Run it with the external monitor connected and **don't touch the keyboard or mouse** until it reports. If the machine doesn't wake by itself within a minute, wake it yourself: a long sleep woken by your own input is the healthy result, and the script will say there is nothing to fix.

**Scope:** the script currently detects GPIO wakes only (the HDMI case). It does not yet detect the EC wake loop, which rarely reproduces in a one-minute test because it needs the lid closed on battery. To look for it in your journal, list the real sleep time of each cycle:

```bash
journalctl -b -o short-unix -q -u systemd-suspend.service \
  --grep 'Performing sleep|returned from sleep' |
awk '/Performing/{t=$1} /returned/{printf "%s  slept %7.0f s\n", strftime("%d %H:%M:%S",t), $1-t}'
```

Dozens of sleeps of 10 s or less, about 30 s apart, with the lid closed and `cat /sys/power/pm_wakeup_irq` showing `9` (the ACPI SCI), point to the EC loop.

**Safeguards**

- Pin 0, and any pin whose `_EVT` notifies a USB controller, the lid, the power/sleep button, the AC adapter or the battery, is **never** proposed: those are how you wake the laptop on purpose.
- Pins that are not declared in `_AEI` are reported but not proposed, because `ignore_wake=` cannot act on them.
- Without `acpica-tools` pins cannot be classified: the script warns, and still asks with "No" as the default.
- Existing `ignore_wake=` entries are merged, not overwritten. GRUB edits back up `/etc/default/grub` first and show the diff.

**How it changes the kernel command line:** it detects `kernelstub` (Pop!_OS), `grubby` (Fedora/RHEL) or `/etc/default/grub` plus `update-grub` / `grub-mkconfig` / `grub2-mkconfig`. Anything else (for example plain systemd-boot entries, which differ between distros) gets printed manual instructions instead of an automatic change.

**Test status:** the diagnosis was run on the tested system above. The apply and revert paths were tested against mocked `grubby`, `kernelstub` and GRUB setups. If you use it on another distribution, please open an issue with the output.

Manual equivalent of the diagnosis:

```bash
echo 1 | sudo tee /sys/power/pm_debug_messages        # not persistent across reboots
systemctl suspend
# after it wakes:
journalctl -k -b --since "-3 min" | grep -E 'Triggering wakeup|GPIO [0-9]+ is active|EC GPE|Notify|SCI'
irq=$(cat /sys/power/pm_wakeup_irq); grep -E "^ *$irq:" /proc/interrupts

# what the pin does in ACPI
sudo dnf install acpica-tools
mkdir acpi && cd acpi && sudo acpidump -b && sudo chown $USER: *.dat && iasl -d *.dat
grep -n 'Method (_EVT' *.dsl
```

Before posting your own logs anywhere, remove lines that identify your network (e.g. `wlp…: authenticate with <BSSID>` contains your router's BSSID and your MAC address).

## Reverting

```bash
./diagnose-spurious-wake.sh --revert          # removes ignore_wake only; any supported distro, asks first
# or by hand on Fedora (both parameters):
sudo grubby --update-kernel=ALL --remove-args="gpiolib_acpi.ignore_wake=AMDI0030:00@4 acpi.ec_no_wakeup=1"
sudo reboot
```

On other distributions, remove both tokens from wherever you added them ([table above](#other-distributions)), regenerate the boot configuration and reboot.

## Related reports and upstream position

- **Lenovo Legion Pro 5 16ARX8** (Ryzen 7745HX + RTX 4060, same board `LNVNB161216`): same self-wake with an external display, same `pinctrl_amd` GPIO 4, `_EVT` case 4 notifying `GPP0.PEGP`; fixed with `gpiolib_acpi.ignore_wake=AMDI0030:00@2,AMDI0030:00@4` (pin 2 covers its USB-C/DP output). Reported on LKML in June 2026:
  - [Original report](https://lkml.rescloud.iu.edu/hypermail/linux/kernel/2606.1/07381.html)
  - [Follow-up with the `_EVT` finding and the maintainer's reply](https://lkml.rescloud.iu.edu/hypermail/linux/kernel/2606.1/08307.html)
- **Upstream position:** the AMD maintainer's view in that thread is that this should **not** be handled with a kernel quirk. If the NVIDIA stack asserts this GPIO during suspend, the fix belongs there, so the kernel parameter remains a workaround. A paragraph describing the debugging method was proposed for the kernel's [AMD debugging documentation](https://docs.kernel.org/arch/x86/amd-debugging.html).

This repository documents a **second model, from a different CPU generation** (Rembrandt, s2idle-only, versus Raphael), with the same pin, the same `_EVT` target and the same workaround. That supports a Lenovo + NVIDIA platform pattern rather than a one-off.

## License

[MIT](LICENSE). ACPI excerpts are quoted from the machine's firmware for interoperability and diagnosis.

Provided as-is. Changing kernel parameters can affect wake behavior: verify on your own hardware before relying on it.
