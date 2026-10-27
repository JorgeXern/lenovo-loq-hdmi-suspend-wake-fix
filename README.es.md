# Lenovo LOQ: despierta de la suspensión a los pocos segundos cuando hay un monitor HDMI conectado

**[Read in English](README.md)**

> **Actualización 2026-10-26: segundo modo de falla y recomendación corregida.**
> Con la tapa cerrada **y con batería** (por ejemplo, dentro de un bolso), el Embedded Controller también puede despertar el equipo en bucle: unos 9 s dormido y 24 s despierto, repetido durante más de una hora, lo suficiente para que se caliente con los ventiladores encendidos dentro del bolso. `gpiolib_acpi.ignore_wake` no cubre este caso; `acpi.ec_no_wakeup=1` sí.
> Versiones anteriores de este README decían que `ec_no_wakeup` no hacía falta y que bloquearía la tapa. **Ambas afirmaciones eran incorrectas.** La configuración recomendada ahora son **los dos parámetros**. Detalles en [Segundo modo de falla](#segundo-modo-de-falla-bucle-de-despertares-del-ec-tapa-cerrada-con-batería).

En el Lenovo LOQ 15ARP10E (AMD Ryzen 7 7735HS + NVIDIA RTX 4050, con el HDMI cableado a la dGPU), al suspender con un monitor HDMI externo conectado el equipo vuelve a despertar a los 5–7 segundos. GNOME lo vuelve a suspender tras el tiempo de inactividad y el ciclo se repite toda la noche. Cada ciclo es una nueva oportunidad de que la transición de suspensión/reanudación se cuelgue, lo que aparece como el clásico *"se fue a suspensión y no volvió"*.

**Solución (workaround):** dos parámetros del kernel, uno por cada modo de falla.

```bash
sudo grubby --update-kernel=ALL --args="gpiolib_acpi.ignore_wake=AMDI0030:00@4 acpi.ec_no_wakeup=1"
sudo reboot
```

| Parámetro | Qué evita |
|---|---|
| `gpiolib_acpi.ignore_wake=AMDI0030:00@4` | que el pin GPIO 4 (dGPU) despierte el sistema a los pocos segundos de suspender cuando hay un monitor HDMI conectado |
| `acpi.ec_no_wakeup=1` | que los eventos del Embedded Controller despierten el sistema desde s2idle, lo que entra en bucle con la tapa cerrada y con batería |

El pin 4 sigue funcionando como evento ACPI en tiempo de ejecución y el EC sigue funcionando con el equipo despierto; solo dejan de poder despertar el sistema. El botón de encendido, el teclado/ratón USB y la tapa siguen despertándolo (todos verificados con los dos parámetros); revisa [Qué sigue despertando el equipo](#qué-sigue-despertando-el-equipo).

Ese comando es para Fedora/RHEL (`grubby`). Para Ubuntu, Debian, Mint, Arch, Pop!_OS y otras, revisa [Otras distribuciones](#otras-distribuciones), o deja que [`diagnose-spurious-wake.sh`](#diagnosticar-y-corregir-con-el-script) encuentre la fuente del despertar y aplique la solución, previa confirmación. Por ahora el script cubre solo la parte del HDMI; agrega `acpi.ec_no_wakeup=1` a mano.

---

## Contenido

- [Equipo probado](#equipo-probado)
- [Síntomas](#síntomas)
- [Causa raíz](#causa-raíz)
- [Segundo modo de falla: bucle de despertares del EC (tapa cerrada, con batería)](#segundo-modo-de-falla-bucle-de-despertares-del-ec-tapa-cerrada-con-batería)
- [Aplicar y verificar la solución](#aplicar-y-verificar-la-solución)
- [Otras distribuciones](#otras-distribuciones)
- [Qué sigue despertando el equipo](#qué-sigue-despertando-el-equipo)
- [Lo que no lo resolvió](#lo-que-no-lo-resolvió)
- [Diagnosticar y corregir con el script](#diagnosticar-y-corregir-con-el-script)
- [Revertir](#revertir)
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

Los logs completos y los extractos de las tablas están en [`evidence/`](evidence/) (en inglés): [historial de cuelgues](evidence/01-hang-history.md), [ciclos de rebote](evidence/02-bounce-cycles.md), [pruebas de fuente de despertar A–H](evidence/03-wake-source-tests.md), [`_AEI`/`_EVT` de ACPI](evidence/04-acpi-excerpts.md) y [bucle de despertares del EC](evidence/05-ec-wake-loop.md).

## Segundo modo de falla: bucle de despertares del EC (tapa cerrada, con batería)

Apareció dos días después de aplicar la solución del HDMI: el equipo se guardó en un bolso con la tapa cerrada, **con batería** y sin monitor externo. Al abrirlo 73 minutos después estaba caliente y con los ventiladores encendidos.

**Síntomas** (según el journal de ese arranque):

- **119 ciclos de suspensión/reanudación** entre las 18:10 y las 19:22. En cada uno durmió unos 9 s (del `suspend entry` al `suspend exit` del kernel) y luego quedó despierto unos 24 s, hasta que logind vio la tapa aún cerrada y lo volvió a suspender. El equipo estuvo despierto cerca de dos tercios del tiempo.
- Batería: **75 % → 63 % en 23 minutos**, unos **17 W** en promedio, frente a unos 0,5 W en una suspensión sana. Dentro de un bolso, esa energía se convierte en calor.
- El mismo bucle ya había ocurrido la noche anterior (33 ciclos en 21 minutos, con la tapa cerrada) y en ráfagas más cortas.
- Ningún evento `Lid opened` durante el bucle, `HandleLidSwitch=suspend` y 0 suspensiones fallidas: logind y la suspensión funcionaban según lo diseñado.

**Cadena de despertar** (`pm_debug_messages` seguía activo en ese arranque):

```
PM: suspend entry (s2idle)
PM: Triggering wakeup from IRQ 9               <- SCI de ACPI
ACPI: EC: ACPI EC GPE status set
ACPI: EC: ACPI EC GPE dispatched               <- evento del EC atendido, vuelve a dormir
ACPI: PM: Rearming ACPI SCI for wakeup
...                                            (se repite varias veces)
PM: Triggering wakeup from IRQ 7               <- pinctrl_amd
ACPI: EC: ACPI EC GPE dispatched
ACPI: PM: Wakeup after ACPI Notify sync        <- un Notify llegó a un dispositivo armado para despertar
GPIO 0 is active: 0x3805f800                   <- pin de despertar del EC (pin 0 de _EVT)
PM: suspend exit
```

| Evidencia | Valor | Significado |
|---|---|---|
| `/sys/power/pm_wakeup_irq` | `9` | el SCI de ACPI, no la interrupción de un dispositivo |
| GPE del EC (log de arranque) | `ACPI: EC: GPE=0x3` | el EC usa el GPE 0x03 |
| `/sys/firmware/acpi/interrupts/gpe03` | 573.700 de 573.705 eventos GPE | prácticamente todo el tráfico del SCI viene del EC |
| Contadores de despertar del xHCI | 5 y 39 eventos | USB no explica más de 100 despertares |
| Cada reanudación del bucle | `EC GPE dispatched` → `Wakeup after ACPI Notify` → `GPIO 0` | un evento del EC ejecuta un manejador que notifica a un dispositivo, y el kernel reanuda |

El bucle empezó tras 53 minutos de sueño limpio, con un despertar USB incidental a las 18:09:53 (`GPIO 59`, el receptor Bolt, reportado como `ACPI non-EC GPE wakeup`). Desde la suspensión siguiente, todos los despertares vinieron del EC.

**Sin determinar:** si los eventos del EC empezaron con esa reanudación o con un cambio de fuente de alimentación, y qué método `_Qxx` y qué dispositivo recibieron el Notify. El manejador del pin 0 en `_EVT` atiende a `LID0`, `ADP0`, `BAT0` y `PWRB`. Con la tapa cerrada, sin cambios en el cargador y la batería descargándose, `BAT0` es el destino más plausible, pero no se confirmó.

**Por qué lo corrige `acpi.ec_no_wakeup=1`:** desactiva el GPE del EC como fuente de despertar durante s2idle, así que estos eventos del EC dejan de procesarse mientras el equipo está suspendido y nunca llegan al Notify que lo reanuda. La tapa sigue despertando este equipo con el parámetro activo, lo que sugiere que el EC activa su pin de despertar directamente para la tapa, pero solo a través de una consulta para estos otros eventos. Esto último es una inferencia, no una medición. Coincide con la prueba del botón de encendido: con los dos parámetros, el botón despierta el equipo como una interrupción GPIO directa (`Wakeup unrelated to ACPI SCI`, `GPIO 0 is active`), así que el pin 0 sigue siendo una fuente de despertar y solo desaparece el camino del GPE del EC.

**Validación** con los dos parámetros, con batería, tapa cerrada y sin monitor: **una sola suspensión de 2 h 22 min** (19:42 → 22:04), despertada al abrir la tapa. Batería 81 % → 79 %, unos 0,85 %/h o 0,5 W. Antes: 119 ciclos en 73 minutos. Con el monitor HDMI conectado y los dos parámetros: 66 s dormido sin tocarlo, despertado con el botón de encendido.

Las líneas `ACPI EC GPE …` solo se imprimen con `pm_debug_messages` activo, y ese ajuste no sobrevive a un reinicio. Que no aparezcan después de reiniciar no prueba nada; lo que cuenta es cuánto tiempo durmió realmente el equipo.

**Por qué las pruebas originales no lo detectaron:** las pruebas A–H se hicieron con cargador, sobre el escritorio y casi siempre con el monitor conectado. Este modo de falla necesita la tapa cerrada y con batería durante varios minutos.

Logs y contadores: [`evidence/05-ec-wake-loop.md`](evidence/05-ec-wake-loop.md) (en inglés).

## Aplicar y verificar la solución

```bash
# 1) Confirmar el nombre del controlador GPIO (en Rembrandt/Raphael es AMDI0030:00)
ls /sys/bus/platform/drivers/amd_gpio/

# 2) Agregar los dos parámetros a todos los kernels instalados (Fedora)
sudo grubby --update-kernel=ALL --args="gpiolib_acpi.ignore_wake=AMDI0030:00@4 acpi.ec_no_wakeup=1"
sudo reboot

# 3) Después del reinicio
cat /sys/module/gpiolib_acpi/parameters/ignore_wake   # AMDI0030:00@4
sudo dmesg | grep -i 'ignoring wake'                   # amd_gpio AMDI0030:00: Ignoring wakeup on pin 4
cat /sys/module/acpi/parameters/ec_no_wakeup           # Y
```

Luego prueba los dos escenarios:

1. **HDMI:** suspende con el monitor conectado y no toques nada durante un minuto. El LED de encendido debería seguir parpadeando. También puedes ejecutar [`diagnose-spurious-wake.sh`](#diagnosticar-y-corregir-con-el-script).
2. **Tapa cerrada con batería:** desconecta el cargador, cierra la tapa y déjalo así entre 15 y 20 minutos; luego ábrela. Debería despertar al abrir la tapa, y el journal debería mostrar una sola suspensión:

   ```bash
   journalctl -b --since "-25 min" -o short-iso | grep -E "PM: suspend (entry|exit)|Lid (opened|closed)"
   ```

   Comprueba que abrir la tapa lo despierta. Si en tu modelo no lo hace, el botón de encendido y un teclado USB siguen sirviendo; por favor abre un issue.

Validación en el equipo probado: 23,5 minutos de sueño ininterrumpido con el monitor HDMI conectado, **incluido un corte de luz real de 6 minutos** (cargador desconectado y reconectado, y el monitor apagado y vuelto a encender) sin un solo despertar. Solo lo despertó el teclado.

Primera noche completa con la solución: **una** suspensión de **9 h 51 min** (00:10 → 10:02), despertada por el teclado (`GPIO 59`). La noche anterior, sin la solución, hubo unas 60 suspensiones de 5–7 s cada una, que terminaron en un cuelgue.

Con los dos parámetros, con batería y la tapa cerrada: una suspensión de 2 h 22 min, despertada al abrir la tapa ([segundo modo de falla](#segundo-modo-de-falla-bucle-de-despertares-del-ec-tapa-cerrada-con-batería)).

Después de una actualización de kernel, revisa que `cat /proc/cmdline` siga incluyendo los dos parámetros. Después de una **actualización de BIOS**, repite el diagnóstico: el número de pin podría cambiar.

## Otras distribuciones

El workaround son dos parámetros estándar del kernel, así que funciona en cualquier distribución; solo cambia la forma de agregarlo. Primero revisa el nombre de tu controlador con `ls /sys/bus/platform/drivers/amd_gpio/` y luego:

| Distribución / gestor de arranque | Agregar el parámetro | Después |
|---|---|---|
| Fedora, RHEL, CentOS Stream | `sudo grubby --update-kernel=ALL --args="gpiolib_acpi.ignore_wake=AMDI0030:00@4 acpi.ec_no_wakeup=1"` | reiniciar |
| Ubuntu, Debian, Linux Mint, Zorin (GRUB) | agregar `gpiolib_acpi.ignore_wake=AMDI0030:00@4 acpi.ec_no_wakeup=1` dentro de las comillas de `GRUB_CMDLINE_LINUX_DEFAULT` en `/etc/default/grub` | `sudo update-grub` y reiniciar |
| Arch, Manjaro, EndeavourOS (GRUB) | la misma edición de `/etc/default/grub` | `sudo grub-mkconfig -o /boot/grub/grub.cfg` y reiniciar |
| openSUSE (GRUB 2) | la misma edición de `/etc/default/grub` (o YaST → Cargador de arranque) | `sudo grub2-mkconfig -o /boot/grub2/grub.cfg` y reiniciar |
| Pop!_OS (kernelstub) | `sudo kernelstub -a "gpiolib_acpi.ignore_wake=AMDI0030:00@4 acpi.ec_no_wakeup=1"` | reiniciar |
| systemd-boot | agregar ambos a la línea `options` de tus entradas en `/boot/loader/entries/*.conf`, o a `/etc/kernel/cmdline` si tu distro regenera las entradas con `kernel-install` | reiniciar |

La verificación es la misma de arriba (`cat /sys/module/gpiolib_acpi/parameters/ignore_wake`, `dmesg | grep -i 'ignoring wake'` y `cat /sys/module/acpi/parameters/ec_no_wakeup`).

Los modelos cuya salida USB-C/DisplayPort también provoca despertares pueden necesitar un segundo pin: la Legion Pro 5 16ARX8 usa `AMDI0030:00@2,AMDI0030:00@4`. El script de abajo encuentra los pines correctos para tu equipo.

## Qué sigue despertando el equipo

Estado con los dos parámetros (`ignore_wake` + `ec_no_wakeup`):

| Fuente | Pin | Estado |
|---|---|---|
| Teclado/ratón USB (receptor Logi Bolt) | GPIO 59 → `XHC1` | ✔ verificado, funciona con la tapa cerrada ([prueba E](evidence/03-wake-source-tests.md)) |
| Abrir la tapa | GPIO 0 (EC → `LID0`) | ✔ verificado el 2026-10-26 (suspensión de 2 h 22 min, con batería) |
| Botón de encendido | GPIO 0 | ✔ verificado el 2026-10-26 (despertar directo por GPIO: `Wakeup unrelated to ACPI SCI`, `GPIO 0 is active`) |
| Conectar/desconectar el cargador | GPIO 0 (EC → `ADP0`) | **no** despierta (observado durante un corte de luz, solo con `ignore_wake`) |

El despertar por tapa con `ec_no_wakeup` está verificado solo en este modelo. Otros modelos podrían enrutar la tapa a través del EC de otra forma: compruébalo después de aplicarlo.

## Lo que no lo resolvió

- **Ajustes del monitor:** desactivar Anynet+ (HDMI-CEC) y cambiar la detección de fuente en el Samsung no ayudó.
- **`acpi.ec_no_wakeup=1` por sí solo, para el despertar por HDMI:** sacó al EC del camino, pero el despertar pasó a llegar directo como interrupción GPIO (`Wakeup unrelated to ACPI SCI`, otra vez `GPIO 4`), así que no resuelve por sí solo el caso HDMI. **Sí** hace falta para el [segundo modo de falla](#segundo-modo-de-falla-bucle-de-despertares-del-ec-tapa-cerrada-con-batería), y en este modelo no bloquea la tapa. *Una versión anterior de este README decía que no hacía falta y que bloquearía la tapa; ambas afirmaciones eran incorrectas.*
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

**Alcance:** por ahora el script detecta solo despertares por GPIO (el caso HDMI). Todavía no detecta el bucle de despertares del EC, que rara vez se reproduce en una prueba de un minuto porque necesita la tapa cerrada y con batería. Para buscarlo en tu journal, lista el tiempo real de sueño de cada ciclo:

```bash
journalctl -b -o short-unix -q -u systemd-suspend.service \
  --grep 'Performing sleep|returned from sleep' |
awk '/Performing/{t=$1} /returned/{printf "%s  slept %7.0f s\n", strftime("%d %H:%M:%S",t), $1-t}'
```

Decenas de sueños de 10 s o menos, separados por unos 30 s, con la tapa cerrada y `cat /sys/power/pm_wakeup_irq` mostrando `9` (el SCI de ACPI), apuntan al bucle del EC.

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
./diagnose-spurious-wake.sh --revert          # quita solo ignore_wake; cualquier distro soportada; pregunta antes
# o a mano en Fedora (los dos parámetros):
sudo grubby --update-kernel=ALL --remove-args="gpiolib_acpi.ignore_wake=AMDI0030:00@4 acpi.ec_no_wakeup=1"
sudo reboot
```

En otras distribuciones, quita los parámetros de donde los agregaste ([tabla de arriba](#otras-distribuciones)), regenera la configuración de arranque y reinicia.

## Reportes relacionados y postura upstream

- **Lenovo Legion Pro 5 16ARX8** (Ryzen 7745HX + RTX 4060, misma placa `LNVNB161216`): el mismo despertar espurio con pantalla externa, el mismo GPIO 4 de `pinctrl_amd` y el `Case 4` del `_EVT` notificando a `GPP0.PEGP`. Se resolvió con `gpiolib_acpi.ignore_wake=AMDI0030:00@2,AMDI0030:00@4` (el pin 2 cubre su salida USB-C/DP). Reportado en LKML en junio de 2026:
  - [Reporte original](https://lkml.rescloud.iu.edu/hypermail/linux/kernel/2606.1/07381.html)
  - [Seguimiento con el hallazgo del `_EVT` y la respuesta del mantenedor](https://lkml.rescloud.iu.edu/hypermail/linux/kernel/2606.1/08307.html)
- **Postura upstream:** el mantenedor de AMD opina en ese hilo que esto **no** debería resolverse con un quirk en el kernel. Si el stack de NVIDIA mantiene activo este GPIO durante la suspensión, la corrección corresponde allí, así que el parámetro del kernel sigue siendo un workaround. Se propuso un párrafo con el método de depuración para la [documentación de depuración AMD](https://docs.kernel.org/arch/x86/amd-debugging.html) del kernel.

Este repositorio documenta un **segundo modelo, de otra generación de CPU** (Rembrandt, solo s2idle, frente a Raphael), con el mismo pin, el mismo destino en el `_EVT` y el mismo workaround. Eso apoya la idea de un patrón de plataforma Lenovo + NVIDIA más que un caso aislado.

## Licencia

[MIT](LICENSE). Los extractos ACPI se citan del firmware del equipo con fines de interoperabilidad y diagnóstico.

Se entrega tal cual. Cambiar parámetros del kernel puede afectar el comportamiento de despertar: verifícalo en tu propio hardware antes de depender de ello.
