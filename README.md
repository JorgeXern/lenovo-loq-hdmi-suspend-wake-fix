# Lenovo LOQ: wakes from suspend seconds after sleeping when an HDMI monitor is connected

**[Leer en español](README.es.md)**

On the Lenovo LOQ 15ARP10E (AMD Ryzen 7 7735HS + NVIDIA RTX 4050, HDMI wired to the dGPU), suspending with an external HDMI monitor connected makes the laptop wake up again after 5–7 seconds. GNOME suspends it again after the idle timeout and the cycle repeats all night. Every cycle is a new chance for the suspend/resume transition to hang, which shows up as the classic *"it went to sleep and never came back"*.

**Fix (workaround):** stop GPIO pin 4 from being a wake source.

```bash
sudo grubby --update-kernel=ALL --args="gpiolib_acpi.ignore_wake=AMDI0030:00@4"
sudo reboot
```

The pin keeps working as a runtime ACPI event; it just can no longer wake the system. Power button, USB keyboard/mouse and (expected) lid keep waking it normally.

---

## Contents

- [Tested system](#tested-system)
- [Symptoms](#symptoms)
- [Root cause](#root-cause)
- [Applying and verifying the fix](#applying-and-verifying-the-fix)
- [What still wakes the machine](#what-still-wakes-the-machine)
- [Things that did not fix it](#things-that-did-not-fix-it)
- [Diagnosing your own machine](#diagnosing-your-own-machine)
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

Full logs and table excerpts are in [`evidence/`](evidence/): [hang history](evidence/01-hang-history.md), [bounce cycles](evidence/02-bounce-cycles.md), [wake source tests A–G](evidence/03-wake-source-tests.md) and [ACPI `_AEI`/`_EVT`](evidence/04-acpi-excerpts.md).

## Applying and verifying the fix

```bash
# 1) Confirm your GPIO controller name (on Rembrandt/Raphael it is AMDI0030:00)
ls /sys/bus/platform/drivers/amd_gpio/

# 2) Add the parameter to all installed kernels (Fedora)
sudo grubby --update-kernel=ALL --args="gpiolib_acpi.ignore_wake=AMDI0030:00@4"
sudo reboot

# 3) After reboot
cat /sys/module/gpiolib_acpi/parameters/ignore_wake   # AMDI0030:00@4
sudo dmesg | grep -i 'ignoring wake'                   # amd_gpio AMDI0030:00: Ignoring wakeup on pin 4
```

Then suspend with the monitor connected and don't touch anything for a minute. The power LED should keep pulsing. Or run [`diagnose-spurious-wake.sh`](#diagnosing-your-own-machine).

Validation on the tested system: 23.5 minutes of uninterrupted sleep with the HDMI monitor connected, **including a real 6-minute power outage** (AC unplugged/replugged and the monitor power-cycled) without a single wake; woken only by the keyboard.

After a kernel update, check `cat /proc/cmdline` still contains the parameter. After a **BIOS update**, re-run the diagnosis: the pin number could change.

## What still wakes the machine

| Source | Pin | Status |
|---|---|---|
| Power button | GPIO 0 | ✔ verified |
| USB keyboard/mouse (Logi Bolt receiver) | GPIO 59 → `XHC1` | ✔ verified, works with the lid closed |
| Lid open | GPIO 0 (EC → `LID0`) | expected, not yet verified |
| AC adapter plug/unplug | GPIO 0 (EC → `ADP0`) | does **not** wake (observed during a power outage) |

## Things that did not fix it

- **Monitor settings:** turning off Anynet+ (HDMI-CEC) and changing source detection on the Samsung did not help.
- **`acpi.ec_no_wakeup=1`:** it removed the EC path from the picture, but the wake then arrived directly as a GPIO interrupt (`Wakeup unrelated to ACPI SCI`, still `GPIO 4`). It is not needed with `ignore_wake`, and keeping it would also block legitimate EC wakes such as the lid.
- **NVIDIA suspend services:** with `UseKernelSuspendNotifiers: 1`, `nvidia-suspend.service` / `nvidia-resume.service` are **skipped by design** (`ExecCondition` only runs them when that value is 0). `PreserveVideoMemoryAllocations: 1` and empty `TemporaryFilePath` are also expected in that mode. Neither is the cause.
- **Longer idle timeout:** it would only reduce the number of cycles, not stop the self-wakes.

## Diagnosing your own machine

[`diagnose-spurious-wake.sh`](diagnose-spurious-wake.sh) automates the procedure: it enables PM debug messages, suspends, waits for the resume and reports the real sleep time, the wake IRQ and its owner, the `GPIO N is active` lines, EC/Notify activity and GPE deltas, and suggests the `ignore_wake=` value for `pinctrl_amd` wakes.

```bash
chmod +x diagnose-spurious-wake.sh
./diagnose-spurious-wake.sh            # basic
./diagnose-spurious-wake.sh --acpi     # also look the pin up in _AEI/_EVT (needs acpica-tools)
```

Run it with the external monitor connected and **don't touch the keyboard or mouse** until it reports. If the machine doesn't wake by itself within a minute, wake it yourself: a long sleep woken by your own input is the good result.

Manual equivalent:

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
sudo grubby --update-kernel=ALL --remove-args="gpiolib_acpi.ignore_wake=AMDI0030:00@4"
sudo reboot
```

## Related reports and upstream position

- **Lenovo Legion Pro 5 16ARX8** (Ryzen 7745HX + RTX 4060, same board `LNVNB161216`): same self-wake with an external display, same `pinctrl_amd` GPIO 4, `_EVT` case 4 notifying `GPP0.PEGP`; fixed with `gpiolib_acpi.ignore_wake=AMDI0030:00@2,AMDI0030:00@4` (pin 2 covers its USB-C/DP output). Reported on LKML in June 2026:
  - [Original report](https://lkml.rescloud.iu.edu/hypermail/linux/kernel/2606.1/07381.html)
  - [Follow-up with the `_EVT` finding and the maintainer's reply](https://lkml.rescloud.iu.edu/hypermail/linux/kernel/2606.1/08307.html)
- **Upstream position:** the AMD maintainer's view in that thread is that this should **not** be handled with a kernel quirk. If the NVIDIA stack asserts this GPIO during suspend, the fix belongs there, so the kernel parameter remains a workaround. A paragraph describing the debugging method was proposed for the kernel's [AMD debugging documentation](https://docs.kernel.org/arch/x86/amd-debugging.html).

This repository documents a **second model, from a different CPU generation** (Rembrandt, s2idle-only, versus Raphael), with the same pin, the same `_EVT` target and the same workaround. That supports a Lenovo + NVIDIA platform pattern rather than a one-off.

## License

[MIT](LICENSE). ACPI excerpts are quoted from the machine's firmware for interoperability and diagnosis.

Provided as-is. Changing kernel parameters can affect wake behavior: verify on your own hardware before relying on it.
