# The bounce: real sleep duration per cycle (before the fix)

Boot -1 of Oct 24, HDMI monitor connected, nobody using the machine.
Duration = wall-clock time between systemd-sleep's
`Performing sleep operation 'suspend'` and `System returned from sleep operation`.

```bash
journalctl -b -1 -o short-unix -q -u systemd-suspend.service \
  --grep 'Performing sleep|returned from sleep' |
awk '/Performing/{t=$1} /returned/{printf "%s  slept %7.0f s\n", strftime("%d %H:%M:%S",t), $1-t}'
```

```
24 04:39:08  slept       5 s
24 04:54:14  slept       5 s
24 05:09:20  slept       5 s
24 05:24:26  slept       7 s
24 05:39:34  slept       7 s
24 05:54:42  slept       7 s
24 06:09:50  slept       7 s
24 06:24:58  slept       7 s
24 06:40:06  slept       5 s
24 06:55:12  slept       5 s
24 07:10:18  slept       5 s
24 07:25:24  slept       7 s
24 07:40:32  slept       7 s
24 07:55:40  slept       7 s
24 08:10:48  slept       7 s
24 08:25:56  slept       7 s
24 08:41:04  slept       5 s
24 08:56:10  slept       5 s
24 09:11:16  slept       5 s
24 09:26:22  slept       7 s
24 09:41:30  slept       7 s
24 10:30:29  slept       5 s
24 10:45:34  slept       7 s
24 11:00:42  slept       7 s
24 11:15:50  slept       5 s
24 11:30:56  slept       7 s
24 11:46:04  slept       5 s
24 12:01:10  slept       5 s
24 12:16:16  slept       5 s
24 12:31:22  slept       8 s
24 12:46:31  slept       7 s
24 13:36:14  slept       5 s
24 13:36:50  slept     744 s
24 13:49:41  slept      16 s
24 14:20:15  slept       5 s
24 15:08:18  slept       3 s
24 15:23:24  slept       7 s
24 15:38:34  slept       7 s
24 15:53:45  slept       7 s
24 16:08:55  slept       7 s
```

Pattern: suspend → self-wake after 5–7 s → ~15 min idle → GNOME auto-suspend →
self-wake again. The next suspend after this list (17:23:06) is the one that hung.
