#!/usr/bin/env bash
# diagnose-spurious-wake.sh
#
# Find out what wakes an AMD laptop from s2idle by itself.
# Enables PM debug messages, suspends, waits for resume and reports:
#   - how long the machine really slept
#   - the wake IRQ and which driver owns it
#   - "GPIO N is active" lines from pinctrl_amd
#   - EC / ACPI Notify activity and GPE counter deltas
#   - (with --acpi) where the pin is declared in _AEI and what its _EVT case notifies
# and, for pinctrl_amd wakes, the gpiolib_acpi.ignore_wake= value to try.
#
# Run it as your normal user (it calls sudo when needed) and DO NOT touch the
# keyboard or mouse after it suspends: the point is to catch what wakes the
# machine on its own.
#
# License: MIT — https://github.com/JorgeXern/lenovo-loq-hdmi-suspend-wake-fix

set -euo pipefail

TIMEOUT=180
ACPI=0
SPURIOUS_THRESHOLD=30   # seconds; a self-wake shorter than this is almost certainly spurious

usage() {
    cat <<EOF
Usage: ${0##*/} [--acpi] [--timeout SECONDS]

  --acpi             also dump and decompile the ACPI tables (needs acpica-tools)
                     and look up the waking pin in _AEI and _EVT
  --timeout SECONDS  how long to wait for the machine to resume (default: ${TIMEOUT})
  -h, --help         show this help

Leave the keyboard and mouse alone after the suspend starts.
If the machine does not wake by itself, wake it manually after ~1 minute:
that result (a long sleep, woken by your own input) is the "good" case.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --acpi) ACPI=1 ;;
        --timeout) TIMEOUT="${2:?--timeout needs a value}"; shift ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; exit 1 ;;
    esac
    shift
done

if [[ $EUID -eq 0 ]]; then
    echo "Run this as your normal user; it calls sudo when it needs root." >&2
    exit 1
fi

say() { printf '\n== %s\n' "$*"; }
kv()  { printf '  %-18s %s\n' "$1" "$2"; }

gpe_snapshot() {
    local f
    for f in /sys/firmware/acpi/interrupts/gpe[0-9A-F][0-9A-F] /sys/firmware/acpi/interrupts/sci; do
        [[ -r $f ]] && printf '%s %s\n' "${f##*/}" "$(awk '{print $1}' "$f")"
    done | sort
}

irq_owner() {
    # Last column of /proc/interrupts is the handler name (acpi, pinctrl_amd, xhci_hcd, ...)
    grep -E "^ *${1}:" /proc/interrupts 2>/dev/null | awk '{print $NF}'
}

# ---------------------------------------------------------------- system info
say "System"
for f in sys_vendor product_name product_version board_name bios_version bios_date; do
    kv "$f" "$(cat "/sys/class/dmi/id/$f" 2>/dev/null || echo '?')"
done
kv kernel "$(uname -r)"
kv mem_sleep "$(cat /sys/power/mem_sleep 2>/dev/null || echo '?')"
kv ignore_wake "$(cat /sys/module/gpiolib_acpi/parameters/ignore_wake 2>/dev/null || echo '(n/a)')"
kv ec_no_wakeup "$(cat /sys/module/acpi/parameters/ec_no_wakeup 2>/dev/null || echo '(n/a)')"
if [[ -r /proc/driver/nvidia/params ]]; then
    kv nvidia "$(grep -E 'UseKernelSuspendNotifiers|PreserveVideoMemoryAllocations' /proc/driver/nvidia/params | tr -s ' ' | paste -sd ',' -)"
fi

# ---------------------------------------------------------------- suspend
sudo -v
echo 1 | sudo tee /sys/power/pm_debug_messages >/dev/null

before=$(gpe_snapshot)

say "Suspending in 5 seconds — hands off the keyboard and mouse"
sleep 5
t0=$(date '+%Y-%m-%d %H:%M:%S')
systemctl suspend

# `sleep` runs on the monotonic clock, which stops while suspended, so this loop
# waits up to TIMEOUT seconds of *awake* time for the resume to show up.
resumed=0
for ((i = 0; i < TIMEOUT / 2; i++)); do
    if sudo journalctl -k -q --since "$t0" 2>/dev/null | grep -q 'PM: suspend exit'; then
        resumed=1
        break
    fi
    sleep 2
done
if [[ $resumed -eq 0 ]]; then
    echo "No resume found in the kernel log within ${TIMEOUT}s." >&2
    exit 2
fi
sleep 3   # let journald catch up

klog=$(sudo journalctl -k -q --since "$t0")
after=$(gpe_snapshot)
wake_irq=$(cat /sys/power/pm_wakeup_irq 2>/dev/null || true)
slept=$(sudo journalctl -q -o short-unix --since "$t0" -u systemd-suspend.service \
        --grep 'Performing sleep|returned from sleep' 2>/dev/null |
        awk '/Performing/{t=$1} /returned/{printf "%.0f", $1 - t}')

# ---------------------------------------------------------------- report
say "Result"
kv "slept (wall clock)" "${slept:-?} s"
if [[ -n $wake_irq ]]; then
    kv pm_wakeup_irq "${wake_irq} ($(irq_owner "$wake_irq"))"
else
    kv pm_wakeup_irq "?"
fi

echo
echo "  Wake-related kernel messages:"
grep -E 'Triggering wakeup|GPIO [0-9]+ is active|EC GPE dispatched|Wakeup after ACPI Notify|Wakeup unrelated to ACPI SCI' \
    <<<"$klog" | sed -E 's/^/    /' || echo "    (none)"

echo
echo "  GPE counters that changed (includes EC traffic while awake, so look for the pattern, not the size):"
join <(echo "$before") <(echo "$after") | awk '$3 != $2 {printf "    %-6s +%d\n", $1, $3 - $2; n++} END {if (!n) print "    (none)"}'

mapfile -t pins < <(grep -oP 'GPIO \K[0-9]+(?= is active)' <<<"$klog" | sort -un)

if [[ -n ${slept:-} && ${slept} -lt ${SPURIOUS_THRESHOLD} ]]; then
    echo
    echo "  -> It slept less than ${SPURIOUS_THRESHOLD}s: this looks like a spurious wake."
fi

# ---------------------------------------------------------------- suggestion
ctrl=""
if [[ -d /sys/bus/platform/drivers/amd_gpio ]]; then
    ctrl=$(find /sys/bus/platform/drivers/amd_gpio/ -maxdepth 1 -name 'AMDI00*:*' -printf '%f\n' | head -n1)
fi

if [[ ${#pins[@]} -gt 0 && -n $ctrl ]]; then
    say "Candidate"
    for p in "${pins[@]}"; do
        kv "pin $p" "gpiolib_acpi.ignore_wake=${ctrl}@${p}"
    done
    cat <<EOF

  Only ignore a pin if the wake was NOT caused by you. Typical legitimate pins:
  the power button / lid / EC (often pin 0) and the USB controllers your
  keyboard is attached to. Use --acpi to see what each pin notifies.
  To apply one persistently on Fedora:
      sudo grubby --update-kernel=ALL --args="gpiolib_acpi.ignore_wake=${ctrl}@<pin>"
EOF
fi

# ---------------------------------------------------------------- ACPI lookup
if [[ $ACPI -eq 1 && ${#pins[@]} -gt 0 ]]; then
    say "ACPI lookup"
    if ! command -v acpidump >/dev/null || ! command -v iasl >/dev/null; then
        echo "  acpidump/iasl not found (Fedora: sudo dnf install acpica-tools)"
        exit 0
    fi
    work=$(mktemp -d -t acpi-wake.XXXXXX)
    (
        cd "$work"
        sudo acpidump -b >/dev/null
        sudo chown "$(id -u):$(id -g)" ./*.dat
        iasl -d ./*.dat >/dev/null 2>&1 || true
    )
    for p in "${pins[@]}"; do
        hex=$(printf '0x%04X' "$p")
        case $p in
            0) cs='Case (Zero)' ;;
            1) cs='Case (One)' ;;
            *) cs=$(printf 'Case (0x%02X)' "$p") ;;
        esac

        echo
        echo "  pin $p — _AEI declaration:"
        awk -v pin="$hex" '
            FNR == 1 { gl = 0 }
            /GpioInt/ { g = $0; gl = FNR }
            { t = $1; gsub(/,/, "", t) }
            t == pin && gl && FNR - gl <= 6 { sub(/^ +/, "", g); printf "    %s: %s\n", FILENAME, g }
        ' "$work"/*.dsl | sed "s|$work/||" || true

        echo "  pin $p — _EVT ${cs}:"
        awk -v cs="$cs" '
            /Method \(_EVT/ { inm = 1; match($0, /^ */); ind = RLENGTH; next }
            inm && $0 ~ ("^ {" ind "}\\}$") { inm = 0 }
            !inm { next }
            index($0, cs) { p = 1; next }
            p && /Case \(/ { p = 0 }
            p && /Notify|\(\)/ && !/M460/ { sub(/^ +/, ""); print "    " $0 }
        ' "$work"/*.dsl || true
    done
    echo
    echo "  Decompiled tables kept in: $work"
fi

echo
echo "(pm_debug_messages stays enabled until the next reboot)"
