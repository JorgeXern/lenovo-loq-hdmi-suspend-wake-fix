#!/usr/bin/env bash
# diagnose-spurious-wake.sh
#
# Find out what wakes an AMD laptop from s2idle by itself and, if it is a
# spurious GPIO wake, offer to apply the gpiolib_acpi.ignore_wake= workaround.
#
# It enables PM debug messages, suspends, waits for the resume and reports:
#   - how long the machine really slept
#   - the wake IRQ and which driver owns it
#   - "GPIO N is active" lines from pinctrl_amd
#   - EC / ACPI Notify activity and GPE counter deltas
#   - where each waking pin is declared in _AEI and what its _EVT case notifies
#     (needs acpica-tools; skipped with a hint if they are not installed)
# Then, only if the wake was spurious and the pin is not a legitimate wake
# source (USB, lid, power button, AC, battery), it asks before changing the
# kernel command line.
#
# Run it as your normal user (it calls sudo when needed) and DO NOT touch the
# keyboard or mouse after it suspends.
#
# License: MIT — https://github.com/JorgeXern/lenovo-loq-hdmi-suspend-wake-fix

set -euo pipefail

TIMEOUT=180
SPURIOUS_THRESHOLD=30      # seconds; a self-wake shorter than this is treated as spurious
PARAM=gpiolib_acpi.ignore_wake
LEGIT_TARGETS='XHC|EHC|OHC|USB|PWRB|SLPB|LID|ADP|AC0|BAT'   # _EVT targets that are real wake sources
GRUB_DEFAULT_FILE=${GRUB_DEFAULT_FILE:-/etc/default/grub}
SCRIPT_NAME=${BASH_SOURCE[0]##*/}

REQUIRE_ACPI=0
DRY_RUN=0
MODE=diagnose              # diagnose | revert

usage() {
    cat <<EOF
Usage: ${SCRIPT_NAME} [--acpi] [--dry-run] [--timeout SECONDS]
       ${SCRIPT_NAME} --revert [--dry-run]

  (no options)       suspend, find what woke the machine, and if it was a
                     spurious GPIO wake, offer to apply ${PARAM}=
  --acpi             fail if acpica-tools are missing instead of skipping the
                     ACPI lookup (the lookup is what tells legitimate pins apart)
  --dry-run          show what would be changed, change nothing
  --timeout SECONDS  how long to wait for the resume (default: ${TIMEOUT})
  --revert           remove ${PARAM}= from the kernel command line
  -h, --help         show this help

Leave the keyboard and mouse alone after the suspend starts. If the machine
does not wake by itself, wake it manually after ~1 minute: a long sleep woken
by your own input is the healthy result.

Supported ways of changing the kernel command line: grubby (Fedora/RHEL),
kernelstub (Pop!_OS) and GRUB via ${GRUB_DEFAULT_FILE} (Ubuntu, Debian, Mint,
Arch, openSUSE...). Anything else gets manual instructions.
EOF
}

say()  { printf '\n== %s\n' "$*"; }
kv()   { printf '  %-18s %s\n' "$1" "$2"; }
warn() { printf '  !! %s\n' "$*"; }

run() {
    # Run a command, or just print it in --dry-run mode.
    if [[ $DRY_RUN -eq 1 ]]; then
        printf '  [dry-run] %s\n' "$*"
    else
        "$@"
    fi
}

# ============================================================== diagnosis helpers

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

gpio_controller() {
    [[ -d /sys/bus/platform/drivers/amd_gpio ]] || return 0
    find /sys/bus/platform/drivers/amd_gpio/ -maxdepth 1 -name 'AMDI00*:*' -printf '%f\n' | head -n1
}

evt_case_label() {
    case $1 in
        0) echo 'Case (Zero)' ;;
        1) echo 'Case (One)' ;;
        *) printf 'Case (0x%02X)\n' "$1" ;;
    esac
}

# _AEI declaration line(s) for a pin, from decompiled tables in $1
aei_for_pin() {
    local dir=$1 pin=$2
    awk -v pin="$(printf '0x%04X' "$pin")" '
        FNR == 1 { gl = 0 }
        /GpioInt/ { g = $0; gl = FNR }
        { t = $1; gsub(/,/, "", t) }
        t == pin && gl && FNR - gl <= 6 { sub(/^ +/, "", g); print g }
    ' "$dir"/*.dsl
}

# Notify/method-call lines of the pin's case inside _EVT, from decompiled tables in $1
evt_for_pin() {
    local dir=$1 pin=$2
    awk -v cs="$(evt_case_label "$pin")" '
        /Method \(_EVT/ { inm = 1; match($0, /^ */); ind = RLENGTH; next }
        inm && $0 ~ ("^ {" ind "}\\}$") { inm = 0 }
        !inm { next }
        index($0, cs) { p = 1; next }
        p && /Case \(/ { p = 0 }
        p && /Notify|\(\)/ && !/M460/ { sub(/^ +/, ""); print }
    ' "$dir"/*.dsl
}

# ============================================================== cmdline helpers

current_ignore_wake() {
    # Value currently in effect ("" if none).
    local v
    v=$(cat /sys/module/gpiolib_acpi/parameters/ignore_wake 2>/dev/null || true)
    [[ $v == "(null)" ]] && v=""
    printf '%s' "$v"
}

merge_entries() {
    # merge_entries "A@1,B@2" "A@4" -> "A@1,A@4,B@2" (deduplicated)
    printf '%s\n' "$1" "$2" | tr ',' '\n' | sed '/^$/d' | sort -u | paste -sd ',' -
}

detect_backend() {
    if command -v kernelstub >/dev/null; then echo kernelstub
    elif command -v grubby >/dev/null; then echo grubby
    elif [[ -f $GRUB_DEFAULT_FILE ]] && { command -v update-grub || command -v grub-mkconfig || command -v grub2-mkconfig; } >/dev/null; then echo grub
    else echo manual
    fi
}

# Print $GRUB_DEFAULT_FILE with GRUB_CMDLINE_LINUX_DEFAULT rewritten so that it
# contains "$1" as the only ${PARAM}= token ("$1" empty = just remove it).
grub_rewrite() {
    local token=$1
    awk -v token="$token" -v key="$PARAM" '
        BEGIN { re = "[ ]*" key "=[^ \"]*" ; gsub(/\./, "\\.", re) }
        /^GRUB_CMDLINE_LINUX_DEFAULT="/ {
            found = 1
            line = $0
            gsub(re, "", line)
            if (token != "") {
                if (line ~ /=""$/) sub(/""$/, "\"" token "\"", line)
                else              sub(/"$/, " " token "\"", line)
            }
            print line
            next
        }
        { print }
        END { if (!found && token != "") print "GRUB_CMDLINE_LINUX_DEFAULT=\"" token "\"" }
    ' "$GRUB_DEFAULT_FILE"
}

grub_regenerate() {
    if command -v update-grub >/dev/null; then
        run sudo update-grub
    elif command -v grub2-mkconfig >/dev/null && [[ -f /boot/grub2/grub.cfg ]]; then
        run sudo grub2-mkconfig -o /boot/grub2/grub.cfg
    elif command -v grub-mkconfig >/dev/null && [[ -f /boot/grub/grub.cfg ]]; then
        run sudo grub-mkconfig -o /boot/grub/grub.cfg
    else
        warn "could not find how to regenerate grub.cfg; run your distro's command (update-grub / grub-mkconfig) yourself"
        return 1
    fi
}

manual_instructions() {
    local token=$1
    cat <<EOF

  Add this to your kernel command line by hand:
      ${token}
  - GRUB:        append it to GRUB_CMDLINE_LINUX_DEFAULT in ${GRUB_DEFAULT_FILE},
                 then run update-grub (Debian/Ubuntu) or grub-mkconfig -o /boot/grub/grub.cfg
  - systemd-boot: append it to /etc/kernel/cmdline (then reinstall the kernel
                 entries, e.g. kernel-install) or to the "options" line in /boot/loader/entries/*.conf
  - Pop!_OS:     sudo kernelstub -a "${token}"
EOF
}

# set_param "<new full value or empty>" "<old full value or empty>"
set_param() {
    local new=$1 old=$2 backend new_tok="" old_tok=""
    [[ -n $new ]] && new_tok="${PARAM}=${new}"
    [[ -n $old ]] && old_tok="${PARAM}=${old}"
    backend=$(detect_backend)
    kv backend "$backend"

    case $backend in
        grubby)
            if [[ -n $old_tok ]]; then run sudo grubby --update-kernel=ALL --remove-args="$old_tok"; fi
            if [[ -n $new_tok ]]; then run sudo grubby --update-kernel=ALL --args="$new_tok"; fi
            ;;
        kernelstub)
            if [[ -n $old_tok ]]; then run sudo kernelstub -d "$old_tok"; fi
            if [[ -n $new_tok ]]; then run sudo kernelstub -a "$new_tok"; fi
            ;;
        grub)
            if grep -qE '^GRUB_CMDLINE_LINUX_DEFAULT=[^"]' "$GRUB_DEFAULT_FILE"; then
                warn "GRUB_CMDLINE_LINUX_DEFAULT in ${GRUB_DEFAULT_FILE} is not double-quoted; not editing it automatically"
                manual_instructions "${new_tok:-<remove ${PARAM}=...>}"
                return 1
            fi
            local tmp
            tmp=$(mktemp)
            grub_rewrite "$new_tok" >"$tmp"
            echo "  Change to ${GRUB_DEFAULT_FILE}:"
            diff -u "$GRUB_DEFAULT_FILE" "$tmp" | sed -n '3,$p' | sed 's/^/    /' || true
            if [[ $DRY_RUN -eq 1 ]]; then
                printf '  [dry-run] would back up %s and write the change above\n' "$GRUB_DEFAULT_FILE"
            else
                sudo cp -a "$GRUB_DEFAULT_FILE" "${GRUB_DEFAULT_FILE}.bak-$(date +%Y%m%d%H%M%S)"
                sudo cp -- "$tmp" "$GRUB_DEFAULT_FILE"   # cp onto an existing file keeps its owner/mode
            fi
            rm -f "$tmp"
            grub_regenerate || return 1
            ;;
        manual)
            manual_instructions "${new_tok:-<remove ${PARAM}=...>}"
            return 1
            ;;
    esac
    return 0
}

confirm() {
    local ans
    if [[ ! -t 0 ]] && [[ ! -r /dev/tty ]]; then
        warn "no terminal to ask on; not applying anything"
        return 1
    fi
    read -r -p "  $1 [y/N] " ans </dev/tty || return 1
    [[ $ans =~ ^[YySs]$ ]]
}

# ============================================================== modes

do_revert() {
    local old
    old=$(current_ignore_wake)
    say "Revert"
    if [[ -z $old ]] && ! grep -q "${PARAM}=" /proc/cmdline; then
        echo "  ${PARAM}= is not set; nothing to revert."
        return 0
    fi
    [[ -z $old ]] && old=$(grep -oP "${PARAM//./\\.}=\K\S+" /proc/cmdline | head -n1)
    kv "current value" "$old"
    if [[ $DRY_RUN -eq 1 ]] || confirm "Remove ${PARAM}=${old} from the kernel command line?"; then
        set_param "" "$old" && echo && echo "  Done. Reboot for it to take effect."
    else
        echo "  Nothing changed."
    fi
}

do_diagnose() {
    # ------------------------------------------------------------ system info
    say "System"
    local f
    for f in sys_vendor product_name product_version board_name bios_version bios_date; do
        kv "$f" "$(cat "/sys/class/dmi/id/$f" 2>/dev/null || echo '?')"
    done
    kv kernel "$(uname -r)"
    kv mem_sleep "$(cat /sys/power/mem_sleep 2>/dev/null || echo '?')"
    local iw
    iw=$(current_ignore_wake)
    kv ignore_wake "${iw:-(none)}"
    kv ec_no_wakeup "$(cat /sys/module/acpi/parameters/ec_no_wakeup 2>/dev/null || echo '(n/a)')"
    if [[ -r /proc/driver/nvidia/params ]]; then
        kv nvidia "$(grep -E 'UseKernelSuspendNotifiers|PreserveVideoMemoryAllocations' /proc/driver/nvidia/params | tr -s ' ' | paste -sd ',' -)"
    fi

    local have_acpi=0
    if command -v acpidump >/dev/null && command -v iasl >/dev/null; then
        have_acpi=1
    elif [[ $REQUIRE_ACPI -eq 1 ]]; then
        echo "acpidump/iasl not found (Fedora: sudo dnf install acpica-tools; Debian/Ubuntu: sudo apt install acpica-tools)" >&2
        exit 1
    fi

    # ------------------------------------------------------------ suspend
    sudo -v
    echo 1 | sudo tee /sys/power/pm_debug_messages >/dev/null

    local before after t0 resumed=0 i klog wake_irq slept
    before=$(gpe_snapshot)

    say "Suspending in 5 seconds — hands off the keyboard and mouse"
    sleep 5
    t0=$(date '+%Y-%m-%d %H:%M:%S')
    systemctl suspend

    # `sleep` runs on the monotonic clock, which stops while suspended, so this
    # loop waits up to TIMEOUT seconds of *awake* time for the resume.
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

    # ------------------------------------------------------------ report
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
    echo "  GPE counters that changed (includes EC traffic while awake: look at the pattern, not the size):"
    join <(echo "$before") <(echo "$after") | awk '$3 != $2 {printf "    %-6s +%d\n", $1, $3 - $2; n++} END {if (!n) print "    (none)"}'

    local -a pins
    mapfile -t pins < <(grep -oP 'GPIO \K[0-9]+(?= is active)' <<<"$klog" | sort -un)

    local short=0
    if [[ -n ${slept:-} ]] && (( slept < SPURIOUS_THRESHOLD )); then
        short=1
    fi

    # ------------------------------------------------------------ ACPI lookup
    local work="" p
    declare -A pin_target=() pin_declared=()
    if [[ ${#pins[@]} -gt 0 && $have_acpi -eq 1 ]]; then
        say "ACPI lookup"
        work=$(mktemp -d -t acpi-wake.XXXXXX)
        (
            cd "$work"
            sudo acpidump -b >/dev/null
            sudo chown "$(id -u):$(id -g)" ./*.dat
            iasl -d ./*.dat >/dev/null 2>&1 || true
        )
        for p in "${pins[@]}"; do
            local aei evt
            aei=$(aei_for_pin "$work" "$p")
            evt=$(evt_for_pin "$work" "$p")
            pin_declared[$p]=$([[ -n $aei ]] && echo yes || echo no)
            pin_target[$p]=$evt
            echo
            echo "  pin $p — _AEI: ${aei:-not declared}"
            echo "  pin $p — _EVT $(evt_case_label "$p"):"
            if [[ -n $evt ]]; then awk '{print "      " $0}' <<<"$evt"; else echo "      (no case found)"; fi
        done
        echo
        echo "  Decompiled tables kept in: $work"
    elif [[ ${#pins[@]} -gt 0 ]]; then
        echo
        echo "  (Install acpica-tools to see what each pin notifies and to tell"
        echo "   legitimate wake pins apart before applying anything.)"
    fi

    # ------------------------------------------------------------ remediation
    local ctrl
    ctrl=$(gpio_controller)
    if [[ ${#pins[@]} -eq 0 || -z $ctrl ]]; then
        say "Verdict"
        if [[ $short -eq 1 ]]; then
            echo "  Slept only ${slept}s, but no pinctrl_amd GPIO wake was reported: this script"
            echo "  cannot propose a fix. Check the wake IRQ and messages above."
        else
            echo "  Slept ${slept:-?}s until woken: healthy. Nothing to fix."
        fi
        echo; echo "(pm_debug_messages stays enabled until the next reboot)"
        return 0
    fi

    local -a candidates=() protected=() unknown=()
    for p in "${pins[@]}"; do
        if [[ $p -eq 0 ]]; then
            protected+=("$p")                       # power button / lid / EC on AMD laptops
        elif [[ -n ${pin_target[$p]:-} ]] && grep -qE "$LEGIT_TARGETS" <<<"${pin_target[$p]}"; then
            protected+=("$p")
        elif [[ ${pin_declared[$p]:-} == no ]]; then
            warn "pin $p is not declared in _AEI: ${PARAM}= cannot act on it (see the LKML thread in the README)"
        elif [[ -n ${pin_target[$p]:-} ]]; then
            candidates+=("$p")
        else
            unknown+=("$p")
        fi
    done

    local -a to_apply=("${candidates[@]}" "${unknown[@]}")

    say "Verdict"
    [[ ${#protected[@]} -gt 0 ]] && kv "legitimate pins" "${protected[*]} (never ignored)"

    if [[ $short -ne 1 ]]; then
        echo "  Slept ${slept:-?}s until woken: healthy. Nothing to fix."
        echo; echo "(pm_debug_messages stays enabled until the next reboot)"
        return 0
    fi
    if [[ ${#to_apply[@]} -eq 0 ]]; then
        cat <<EOF
  Slept only ${slept}s, but the wake came from a legitimate source
  (pin(s) ${protected[*]:-?}: USB, lid, button, AC or battery). Most likely you
  woke it yourself before ${SPURIOUS_THRESHOLD}s. Nothing to fix.
  If you really did not touch anything, a USB device (for example a mouse
  picking up movement) woke it. Run again and wait at least a minute.
EOF
        echo; echo "(pm_debug_messages stays enabled until the next reboot)"
        return 0
    fi

    echo "  Slept only ${slept}s and woke from pin(s) ${to_apply[*]}: spurious wake."
    if [[ ${#unknown[@]} -gt 0 ]]; then
        warn "pin(s) ${unknown[*]} could not be classified (no ACPI info). Only ignore them if you are"
        warn "sure you did not touch any input device during the test."
    fi

    say "Remediation"

    local add="" old new
    for p in "${to_apply[@]}"; do add=$(merge_entries "$add" "${ctrl}@${p}"); done
    old=$(current_ignore_wake)
    new=$(merge_entries "$old" "$add")
    if [[ $new == "$old" ]]; then
        warn "${PARAM}=${old} is already set but the pin still woke the machine."
        warn "Check 'sudo dmesg | grep -i \"ignoring wake\"' and that you rebooted after applying it."
        return 0
    fi

    kv "proposed" "${PARAM}=${new}"
    if [[ $DRY_RUN -eq 1 ]] || confirm "Apply it to the kernel command line now?"; then
        if set_param "$new" "$old"; then
            cat <<EOF

  Done. Reboot, then verify:
      cat /sys/module/gpiolib_acpi/parameters/ignore_wake
      sudo dmesg | grep -i 'ignoring wake'
  and run this script again: it should sleep until you wake it.
  To undo: ${SCRIPT_NAME} --revert
EOF
        fi
    else
        echo "  Nothing changed. You can apply it later by hand:"
        manual_instructions "${PARAM}=${new}"
    fi

    echo; echo "(pm_debug_messages stays enabled until the next reboot)"
}

main() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --acpi) REQUIRE_ACPI=1 ;;
            --dry-run) DRY_RUN=1 ;;
            --revert) MODE=revert ;;
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

    case $MODE in
        revert) do_revert ;;
        *) do_diagnose ;;
    esac
}

# Allow sourcing for tests without running main.
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    main "$@"
fi
