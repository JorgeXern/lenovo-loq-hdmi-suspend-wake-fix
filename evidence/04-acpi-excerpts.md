# ACPI excerpts (SSDT22, BIOS SUCN18WW)

Extracted with `sudo acpidump -b && iasl -d *.dat`. The GPIO controller's event
methods live in `ssdt22.dsl`. Debug-print calls (`M460 (...)`) were stripped
for readability.

## `\_SB.GPIO._AEI` — GPIO pins declared as ACPI events

```asl
GpioInt (Edge, ActiveHigh, ExclusiveAndWake, PullDefault, 0x1388,
    "\\_SB.GPIO", 0x00, ResourceConsumer, ,)
    {   // Pin list
        0x0000
    }
GpioInt (Level, ActiveHigh, ExclusiveAndWake, PullNone, 0x0000,
    "\\_SB.GPIO", 0x00, ResourceConsumer, ,)
    {   // Pin list
        0x003A
    }
GpioInt (Level, ActiveHigh, ExclusiveAndWake, PullNone, 0x0000,
    "\\_SB.GPIO", 0x00, ResourceConsumer, ,)
    {   // Pin list
        0x003B
    }
GpioInt (Edge, ActiveLow, ExclusiveAndWake, PullNone, 0x0000,
    "\\_SB.GPIO", 0x00, ResourceConsumer, ,)
    {   // Pin list
        0x0012
    }
GpioInt (Edge, ActiveLow, ExclusiveAndWake, PullNone, 0x0000,
    "\\_SB.GPIO", 0x00, ResourceConsumer, ,)
    {   // Pin list
        0x0018
    }
GpioInt (Edge, ActiveBoth, ExclusiveAndWake, PullNone, 0x0000,
    "\\_SB.GPIO", 0x00, ResourceConsumer, ,)
    {   // Pin list
        0x0004          // <- the spurious wake source
    }
```

## `\_SB.GPIO._EVT` — what each pin's event does

```asl
Method (_EVT, 1, Serialized)
{
    Name (HPDW, 0x55)
    Switch (ToInteger (Arg0))
    {
        Case (Zero)                       // pin 0: EC wake reasons
        {
            Local0 = \_SB.PCI0.LPC0.EC0.HWAK
            If (((Local0 & 0x14) == 0x14))      { ... Notify (\_SB.LID0, 0x80) }
            ElseIf (((Local0 & 0x30) == 0x30))  { ... Notify (\_SB.LID0, 0x80) }
            ElseIf (((Local0 & 0x50) == 0x50))  { ... Notify (\_SB.ADP0, 0x80) }
            ElseIf (((Local0 & 0x90) == 0x90))  { ... Notify (\_SB.PCI0.LPC0.EC0.BAT0, 0x80) }
            Else                                { ... Notify (\_SB.PWRB, 0x80) }
        }
        Case (0x02) { Notify (\_SB.PCI0.GPP0, 0x02)  Notify (\_SB.PCI0.GPP1, 0x02)  Notify (\_SB.PCI0.GPP2, 0x02) }
        Case (0x03) { Notify (\_SB.PCI0.GPP7, 0x02) }
        Case (0x11) { Notify (\_SB.PCI0.GPP2, 0x02) }
        Case (0x12) { Notify (\_SB.PCI0.GPP6, 0x02) }
        Case (0x18) { Notify (\_SB.PCI0.GPP5, 0x02) }
        Case (0x36) { Notify (\_SB.PCI0.GP17.MP2C, 0x02)  If ((HPDW == One)) { Notify (\_SB.PWRB, 0x80) } }
        Case (0x3A) { Notify (\_SB.PCI0.GP17.XHC0, 0x02) }
        Case (0x3B) { Notify (\_SB.PCI0.GP17.XHC1, 0x02) }   // pin 59: USB, keyboard receiver
        Case (0x2A) { Notify (\_SB.PCI0.GPP7, Zero) }
        Case (0x3D) { Notify (\_SB.PCI0.GP17.AZAL, 0x02) }
        Case (0x3E) { Notify (\_SB.PCI0.GP17.ACP, 0x02) }
        Case (0x04)                       // pin 4: dGPU
        {
            If (((DSMF == 0x03) || (DSMF == 0x04)))
            {
                \_SB.GZFD.HTPE ()
                Sleep (0x05)
            }
            Notify (\_SB.PCI0.GPP0.PEGP, 0x81) // Information Change
        }
    }
}
```

## Mapping to the observed wakes

| Pin | Declared as | `_EVT` target | Seen as |
|---|---|---|---|
| 0 | Edge, ActiveHigh, ExclusiveAndWake | EC → LID0 / ADP0 / BAT0 / PWRB | power button wake (Test B) |
| 4 | Edge, **ActiveBoth**, ExclusiveAndWake | `GPP0.PEGP` (NVIDIA dGPU), 0x81 | spurious wake with HDMI (Tests A, C, D) |
| 59 (0x3B) | Level, ActiveHigh, ExclusiveAndWake | `GP17.XHC1` (USB controller) | keyboard wake via Logi Bolt receiver (Tests E–G) |

DMI of the machine these tables come from:

```
LENOVO / 83S0 / LOQ 15ARP10E / LNVNB161216 / SUCN18WW (04/22/2026)
```
