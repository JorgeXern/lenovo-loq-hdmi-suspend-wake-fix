# Lenovo LOQ: despierta de la suspensión a los pocos segundos cuando hay un monitor HDMI conectado

**[Read in English](README.md)**

> **⚠ Problema abierto (2026-10-27): apaga el equipo antes de guardarlo en un bolso.**
> Aparte del problema del HDMI que se corrige aquí, este equipo puede quedar atrapado en un bucle de suspensión/reanudación con la tapa cerrada y con batería: el Embedded Controller lo despierta cada ~30 s y se calienta con los ventiladores encendidos. La causa aún no se conoce y **no hay solución**. El workaround de este repositorio no lo provoca ni lo evita.
> `acpi.ec_no_wakeup=1` tampoco lo resuelve (se probó: el EC pasa a despertar el equipo directamente por el GPIO 0). Detalles en [Problema abierto](#problema-abierto-bucle-de-despertares-del-ec-con-la-tapa-cerrada-y-con-batería).

En el Lenovo LOQ 15ARP10E (AMD Ryzen 7 7735HS + NVIDIA RTX 4050, con el HDMI cableado a la dGPU), al suspender con un monitor HDMI externo conectado el equipo vuelve a despertar a los 5–7 segundos. GNOME lo vuelve a suspender tras el tiempo de inactividad y el ciclo se repite toda la noche. Cada ciclo es una nueva oportunidad de que la transición de suspensión/reanudación se cuelgue, lo que aparece como el clásico *"se fue a suspensión y no volvió"*.

**Solución (workaround):** quitarle al pin GPIO 4 la capacidad de despertar el sistema.

```bash
sudo grubby --update-kernel=ALL --args="gpiolib_acpi.ignore_wake=AMDI0030:00@4"
sudo reboot
```

El pin sigue funcionando como evento ACPI en tiempo de ejecución; solo deja de poder despertar el sistema. El botón de encendido, el teclado/ratón USB y la tapa siguen despertándolo con normalidad.

Ese comando es para Fedora/RHEL (`grubby`). Para Ubuntu, Debian, Mint, Arch, Pop!_OS y otras, revisa [Otras distribuciones](#otras-distribuciones), o deja que [`diagnose-spurious-wake.sh`](#diagnosticar-y-corregir-con-el-script) encuentre la fuente del despertar y aplique la solución, previa confirmación.

---

## Contenido

- [Equipo probado](#equipo-probado)
- [Síntomas](#síntomas)
- [Causa raíz](#causa-raíz)
- [Aplicar y verificar la solución](#aplicar-y-verificar-la-solución)
- [Otras distribuciones](#otras-distribuciones)
- [Qué sigue despertando el equipo](#qué-sigue-despertando-el-equipo)
- [Lo que no lo resolvió](#lo-que-no-lo-resolvió)
- [Diagnosticar y corregir con el script](#diagnosticar-y-corregir-con-el-script)
- [Revertir](#revertir)
- [Problema abierto: bucle de despertares del EC con la tapa cerrada y con batería](#problema-abierto-bucle-de-despertares-del-ec-con-la-tapa-cerrada-y-con-batería)
- [Reportes relacionados y postura upstream](#reportes-relacionados-y-postura-upstream)

## Equipo probado

| | |
|---|---|
| DMI | `LENOVO` / `83S0` / `LOQ 15ARP10E` |
| Placa | `LNVNB161216` |
| BIOS | `SUCN18WW` (2026-04-22) |
| CPU / iGPU | AMD Ryzen 7 7735HS (Rembrandt), Radeon 680M — maneja la pantalla interna |
| dGPU | NVIDIA RTX 4050 Laptop — maneja el puerto **HDMI** |
| Controlador GPIO | `AMDI0030:00` (`pinctrl_amd`, IRQ 7) |
| Estados de suspensión | `mem_sleep` = solo `[s2idle]` (sin S3) |
| Sistema | Fedora 44 Workstation, GNOME (Wayland), LUKS2 + Btrfs, Secure Boot activo |
| Kernels | 7.2.9, 7.2.10, 7.2.11 (`-200.fc44`) — todos afectados |
| NVIDIA | 615.71.09 y 615.78.08 (akmod de RPM Fusion), `UseKernelSuspendNotifiers=1` — ambos afectados |
| Monitor | Samsung Odyssey G7 G70D por HDMI |

El nombre de placa `LNVNB161216` es el mismo que se reportó para la Lenovo Legion Pro 5 16ARX8 con el mismo problema en el mismo pin (ver [reportes relacionados](#reportes-relacionados-y-postura-upstream)). Es probable que otros LOQ/Legion de esta familia de placas también estén afectados.

## Síntomas

- Con el monitor HDMI conectado, `systemctl suspend` (o la suspensión automática por inactividad) despierta el equipo **5–7 segundos después**. El monitor se enciende sin mostrar nada o con el login de GDM, y luego se vuelve a apagar.
- Sin monitor externo la suspensión funciona bien: el LED de encendido parpadea y el equipo se queda dormido.
- En un solo día el journal mostró **99 ciclos de suspensión** en un mismo arranque, cada ~15 minutos desde las 04:39 hasta las 16:08, de 5–7 segundos cada uno:

  ```
  24 04:39:08  dormido       5 s
  24 04:54:14  dormido       5 s
  24 05:09:20  dormido       5 s
  ...
  24 15:53:45  dormido       7 s
  24 16:08:55  dormido       7 s
  ```

- De vez en cuando una de esas transiciones **se cuelga**: LED de encendido fijo (sin parpadear), sin retroiluminación del teclado, pantalla apagada y sin respuesta. Solo se recupera con un apagado forzado. El log del kernel de ese arranque termina en `PM: suspend entry (s2idle)`, sin nada después.
- En 15 días hubo **6 cuelgues en ~330 ciclos de suspensión** (≈ 1 de cada 55), repartidos en tres versiones del kernel y dos del driver NVIDIA. No es una versión defectuosa puntual.

## Causa raíz

Medido con `pm_debug_messages` activo (`echo 1 | sudo tee /sys/power/pm_debug_messages`):

Con el monitor conectado, cada despertar espontáneo reporta **`GPIO 4 is active`**. Sin monitor, el único despertar es el que uno provoca (por ejemplo `GPIO 0`, el botón de encendido).

| Prueba | Despertar reportado | Resultado |
|---|---|---|
| HDMI conectado | EC GPE dispatched → `Wakeup after ACPI Notify` → `GPIO 4 is active` | despierta a los ~5 s |
| HDMI desconectado | `GPIO 0 is active` (botón de encendido, a mano) | se queda dormido |
| HDMI conectado + `acpi.ec_no_wakeup=1` | IRQ 7 (`pinctrl_amd`), `Wakeup unrelated to ACPI SCI`, `GPIO 4 is active` | sigue despertando |
| HDMI conectado + `gpiolib_acpi.ignore_wake=AMDI0030:00@4` | `GPIO 59 is active` (teclado USB, a mano) | se queda dormido ✔ |

El firmware explica el porqué. En la `SSDT22`, el `_AEI` del controlador GPIO declara el pin 4 como interrupción de ambos flancos **capaz de despertar**, y su manejador `_EVT` notifica a la dGPU NVIDIA:

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

Es decir: al suspender mientras la dGPU maneja la salida HDMI, el pin 4 recibe una transición. Como la BIOS lo marcó `ExclusiveAndWake`, esa transición despierta todo el sistema. La función eléctrica exacta del pin 4 no está documentada. Es una señal de la dGPU hacia la plataforma, pero **no** es necesariamente la línea de hot-plug del HDMI.

Como el pin 4 **sí está declarado en ACPI**, `gpiolib_acpi.ignore_wake=` lo puede alcanzar: el kernel omite `enable_irq_wake()` para ese pin, y la notificación del `_EVT` sigue ejecutándose en tiempo de ejecución.

El resto de la tabla `_EVT` coincide con lo observado:

| Pin | Acción en `_EVT` | Observado |
|---|---|---|
| 0 | EC `HWAK` → `LID0` / `ADP0` / `BAT0` / `PWRB` | despertar por botón de encendido |
| 4 | `Notify (GPP0.PEGP, 0x81)` (dGPU) | el despertar espurio |
| 0x3B (59) | `Notify (GP17.XHC1, 0x02)` (controlador USB) | despertar desde el receptor del teclado USB |

`GZFD.HTPE` / `DSMF` parecen ser lógica "Gaming Zone" / modo de GPU de Lenovo. Su función exacta es desconocida y no hace falta para el workaround.

Los logs completos y los extractos de las tablas están en [`evidence/`](evidence/) (en inglés): [historial de cuelgues](evidence/01-hang-history.md), [ciclos de rebote](evidence/02-bounce-cycles.md), [pruebas de fuente de despertar A–H](evidence/03-wake-source-tests.md), [`_AEI`/`_EVT` de ACPI](evidence/04-acpi-excerpts.md) y la [investigación abierta del bucle del EC](evidence/05-ec-wake-loop.md).

## Aplicar y verificar la solución

```bash
# 1) Confirmar el nombre del controlador GPIO (en Rembrandt/Raphael es AMDI0030:00)
ls /sys/bus/platform/drivers/amd_gpio/

# 2) Agregar el parámetro a todos los kernels instalados (Fedora)
sudo grubby --update-kernel=ALL --args="gpiolib_acpi.ignore_wake=AMDI0030:00@4"
sudo reboot

# 3) Después del reinicio
cat /sys/module/gpiolib_acpi/parameters/ignore_wake   # AMDI0030:00@4
sudo dmesg | grep -i 'ignoring wake'                   # amd_gpio AMDI0030:00: Ignoring wakeup on pin 4
```

Luego suspende con el monitor conectado y no toques nada durante un minuto. El LED de encendido debería seguir parpadeando. También puedes ejecutar [`diagnose-spurious-wake.sh`](#diagnosticar-y-corregir-con-el-script).

Validación en el equipo probado: 23,5 minutos de sueño ininterrumpido con el monitor HDMI conectado, **incluido un corte de luz real de 6 minutos** (cargador desconectado y reconectado, y el monitor apagado y vuelto a encender) sin un solo despertar. Solo lo despertó el teclado.

Primera noche completa con la solución: **una** suspensión de **9 h 51 min** (00:10 → 10:02), despertada por el teclado (`GPIO 59`). La noche anterior, sin la solución, hubo unas 60 suspensiones de 5–7 s cada una, que terminaron en un cuelgue.

Después de una actualización de kernel, revisa que `cat /proc/cmdline` siga incluyendo el parámetro. Después de una **actualización de BIOS**, repite el diagnóstico: el número de pin podría cambiar.

## Otras distribuciones

El workaround es un parámetro estándar del kernel, así que funciona en cualquier distribución; solo cambia la forma de agregarlo. Primero revisa el nombre de tu controlador con `ls /sys/bus/platform/drivers/amd_gpio/` y luego:

| Distribución / gestor de arranque | Agregar el parámetro | Después |
|---|---|---|
| Fedora, RHEL, CentOS Stream | `sudo grubby --update-kernel=ALL --args="gpiolib_acpi.ignore_wake=AMDI0030:00@4"` | reiniciar |
| Ubuntu, Debian, Linux Mint, Zorin (GRUB) | agregar `gpiolib_acpi.ignore_wake=AMDI0030:00@4` dentro de las comillas de `GRUB_CMDLINE_LINUX_DEFAULT` en `/etc/default/grub` | `sudo update-grub` y reiniciar |
| Arch, Manjaro, EndeavourOS (GRUB) | la misma edición de `/etc/default/grub` | `sudo grub-mkconfig -o /boot/grub/grub.cfg` y reiniciar |
| openSUSE (GRUB 2) | la misma edición de `/etc/default/grub` (o YaST → Cargador de arranque) | `sudo grub2-mkconfig -o /boot/grub2/grub.cfg` y reiniciar |
| Pop!_OS (kernelstub) | `sudo kernelstub -a "gpiolib_acpi.ignore_wake=AMDI0030:00@4"` | reiniciar |
| systemd-boot | agregarlo a la línea `options` de tus entradas en `/boot/loader/entries/*.conf`, o a `/etc/kernel/cmdline` si tu distro regenera las entradas con `kernel-install` | reiniciar |

La verificación es la misma de arriba (`cat /sys/module/gpiolib_acpi/parameters/ignore_wake` y `dmesg | grep -i 'ignoring wake'`).

Los modelos cuya salida USB-C/DisplayPort también provoca despertares pueden necesitar un segundo pin: la Legion Pro 5 16ARX8 usa `AMDI0030:00@2,AMDI0030:00@4`. El script de abajo encuentra los pines correctos para tu equipo.

## Qué sigue despertando el equipo

| Fuente | Pin | Estado |
|---|---|---|
| Botón de encendido | GPIO 0 | ✔ verificado |
| Teclado/ratón USB (receptor Logi Bolt) | GPIO 59 → `XHC1` | ✔ verificado, funciona con la tapa cerrada |
| Abrir la tapa | GPIO 0 (EC → `LID0`) | ✔ verificado (2026-10-26/27) |
| Conectar/desconectar el cargador | GPIO 0 (EC → `ADP0`) | **no** despierta (observado durante un corte de luz) |

## Lo que no lo resolvió

- **Ajustes del monitor:** desactivar Anynet+ (HDMI-CEC) y cambiar la detección de fuente en el Samsung no ayudó.
- **`acpi.ec_no_wakeup=1`:** sacó al EC del camino, pero el despertar pasó a llegar directo como interrupción GPIO (`Wakeup unrelated to ACPI SCI`, otra vez `GPIO 4`). No hace falta con `ignore_wake`. En este modelo **no** bloquea la tapa (una versión anterior de este README decía que sí), y tampoco corrige el [bucle abierto del EC](#problema-abierto-bucle-de-despertares-del-ec-con-la-tapa-cerrada-y-con-batería).
- **Servicios de suspensión de NVIDIA:** con `UseKernelSuspendNotifiers: 1`, `nvidia-suspend.service` / `nvidia-resume.service` **se omiten por diseño** (su `ExecCondition` solo los ejecuta si ese valor es 0). `PreserveVideoMemoryAllocations: 1` y `TemporaryFilePath` vacío también son lo esperado en ese modo. Ninguno es la causa.
- **Alargar el tiempo de inactividad:** solo reduciría la cantidad de ciclos, sin evitar los despertares espurios.

## Diagnosticar y corregir con el script

[`diagnose-spurious-wake.sh`](diagnose-spurious-wake.sh) hace todo el procedimiento de una vez:

1. Activa los mensajes de depuración de PM, suspende y espera la reanudación.
2. Reporta el tiempo real de sueño, la IRQ de despertar y su dueño, las líneas `GPIO N is active`, la actividad del EC/Notify y los deltas de GPE.
3. Si `acpica-tools` está instalado, busca cada pin en el `_AEI` y el `_EVT`.
4. Si, y solo si, el despertar fue espurio (durmió menos de 30 s) y el pin no es una fuente legítima de despertar, propone el valor de `gpiolib_acpi.ignore_wake=` y pregunta **`[y/N]`** antes de cambiar nada.

```bash
sudo dnf install acpica-tools          # Fedora  (Debian/Ubuntu: sudo apt install acpica-tools)
chmod +x diagnose-spurious-wake.sh
./diagnose-spurious-wake.sh            # diagnostica; ofrece la solución solo si hace falta
./diagnose-spurious-wake.sh --dry-run  # lo mismo, pero solo muestra lo que cambiaría
./diagnose-spurious-wake.sh --revert   # quita el parámetro
```

Ejecútalo con el monitor externo conectado y **no toques el teclado ni el ratón** hasta que termine. Si el equipo no despierta solo en un minuto, despiértalo tú: un sueño largo interrumpido por tu propia acción es el resultado sano, y el script dirá que no hay nada que corregir.

**Salvaguardas**

- El pin 0, y cualquier pin cuyo `_EVT` notifique a un controlador USB, la tapa, el botón de encendido o suspensión, el cargador o la batería, **nunca** se propone: son las formas de despertar el equipo a propósito.
- Los pines que no están declarados en el `_AEI` se reportan pero no se proponen, porque `ignore_wake=` no puede actuar sobre ellos.
- Sin `acpica-tools` los pines no se pueden clasificar: el script lo advierte y pregunta igual, con "No" por defecto.
- Las entradas existentes de `ignore_wake=` se combinan, no se sobrescriben. Antes de editar GRUB se respalda `/etc/default/grub` y se muestra el diff.

**Cómo cambia la línea de comandos del kernel:** detecta `kernelstub` (Pop!_OS), `grubby` (Fedora/RHEL) o `/etc/default/grub` junto con `update-grub` / `grub-mkconfig` / `grub2-mkconfig`. En cualquier otro caso (por ejemplo, entradas de systemd-boot, que varían entre distros) imprime instrucciones manuales en vez de hacer un cambio automático.

**Estado de las pruebas:** el diagnóstico se ejecutó en el equipo probado. Las rutas de aplicar y revertir se probaron contra `grubby`, `kernelstub` y GRUB simulados. Si lo usas en otra distribución, abre un issue con la salida.

Equivalente manual del diagnóstico:

```bash
echo 1 | sudo tee /sys/power/pm_debug_messages        # no persiste tras reiniciar
systemctl suspend
# cuando despierte:
journalctl -k -b --since "-3 min" | grep -E 'Triggering wakeup|GPIO [0-9]+ is active|EC GPE|Notify|SCI'
irq=$(cat /sys/power/pm_wakeup_irq); grep -E "^ *$irq:" /proc/interrupts

# qué hace el pin en ACPI
sudo dnf install acpica-tools
mkdir acpi && cd acpi && sudo acpidump -b && sudo chown $USER: *.dat && iasl -d *.dat
grep -n 'Method (_EVT' *.dsl
```

Antes de publicar tus propios logs, elimina las líneas que identifican tu red (por ejemplo, `wlp…: authenticate with <BSSID>` contiene el BSSID de tu router y la MAC de tu tarjeta).

## Revertir

```bash
./diagnose-spurious-wake.sh --revert          # cualquier distro soportada; pregunta antes
# o a mano en Fedora:
sudo grubby --update-kernel=ALL --remove-args="gpiolib_acpi.ignore_wake=AMDI0030:00@4"
sudo reboot
```

En otras distribuciones, quita el parámetro de donde lo agregaste ([tabla de arriba](#otras-distribuciones)), regenera la configuración de arranque y reinicia.

## Problema abierto: bucle de despertares del EC con la tapa cerrada y con batería

**Estado: en investigación, sin solución.** Observado en el equipo probado el 25, 26 y 27 de octubre de 2026.

**Qué pasa.** Con la tapa cerrada, el cargador desconectado y sin monitor externo, el equipo despierta unos 7 s después de suspender, queda despierto unos 25 s hasta que logind ve la tapa aún cerrada, vuelve a suspender y se repite. Dentro de un bolso nunca se detuvo solo: 119 ciclos en 73 minutos un día, unos 100 en 53 minutos otro, consumiendo entre 17 y 33 W y calentándose.

**Qué se sabe** (detalles en [`evidence/05-ec-wake-loop.md`](evidence/05-ec-wake-loop.md), en inglés):

- Todos los despertares vienen del **GPIO 0**, el pin de despertar del Embedded Controller (el mismo que usan la tapa y el botón de encendido), así que no se puede ignorar como el pin 4.
- Durante el bucle, el EC notifica al dispositivo de la batería (`BAT0`) **cada ~0,5 s**. Con el equipo despierto, frío y con cargador, la misma revisión no muestra notificaciones.
- No pasa siempre: el mismo equipo durmió 2 h 22 min y 7 h 36 min con la tapa cerrada y con batería. Hasta ahora empezó al cerrar la tapa poco después de haber usado el equipo, y una vez, sobre un escritorio, se detuvo solo a los 31 minutos al enfriarse (44 °C → 26 °C). La temperatura es la hipótesis principal, **no confirmada**.
- `acpi.ec_no_wakeup=1` bloquea solo el camino GPE de ACPI del EC; el EC pasa a despertar el equipo directamente por el GPIO 0, así que el bucle continúa.
- `gpiolib_acpi.ignore_wake=AMDI0030:00@4` (la solución del HDMI) actúa solo sobre el pin 4 y no tiene relación con este bucle.
- El cuelgue esporádico al entrar en suspensión descrito en [Síntomas](#síntomas) también se vio una vez **sin** monitor HDMI durante estas pruebas. Cada ciclo de suspensión adicional es otra oportunidad de que ocurra.

**Qué hacer por ahora:** apaga el equipo (no lo suspendas) antes de llevarlo en un bolso. Si ves el mismo bucle en tu LOQ o Legion, abre un issue con `journalctl -b -o short-iso | grep -E "PM: suspend (entry|exit)|Lid (opened|closed)"` y `grep amd_gpio /proc/interrupts`.

## Reportes relacionados y postura upstream

- **Lenovo Legion Pro 5 16ARX8** (Ryzen 7745HX + RTX 4060, misma placa `LNVNB161216`): el mismo despertar espurio con pantalla externa, el mismo GPIO 4 de `pinctrl_amd` y el `Case 4` del `_EVT` notificando a `GPP0.PEGP`. Se resolvió con `gpiolib_acpi.ignore_wake=AMDI0030:00@2,AMDI0030:00@4` (el pin 2 cubre su salida USB-C/DP). Reportado en LKML en junio de 2026:
  - [Reporte original](https://lkml.rescloud.iu.edu/hypermail/linux/kernel/2606.1/07381.html)
  - [Seguimiento con el hallazgo del `_EVT` y la respuesta del mantenedor](https://lkml.rescloud.iu.edu/hypermail/linux/kernel/2606.1/08307.html)
- **Postura upstream:** el mantenedor de AMD opina en ese hilo que esto **no** debería resolverse con un quirk en el kernel. Si el stack de NVIDIA mantiene activo este GPIO durante la suspensión, la corrección corresponde allí, así que el parámetro del kernel sigue siendo un workaround. Se propuso un párrafo con el método de depuración para la [documentación de depuración AMD](https://docs.kernel.org/arch/x86/amd-debugging.html) del kernel.

Este repositorio documenta un **segundo modelo, de otra generación de CPU** (Rembrandt, solo s2idle, frente a Raphael), con el mismo pin, el mismo destino en el `_EVT` y el mismo workaround. Eso apoya la idea de un patrón de plataforma Lenovo + NVIDIA más que un caso aislado.

## Licencia

[MIT](LICENSE). Los extractos ACPI se citan del firmware del equipo con fines de interoperabilidad y diagnóstico.

Se entrega tal cual. Cambiar parámetros del kernel puede afectar el comportamiento de despertar: verifícalo en tu propio hardware antes de depender de ello.
