# pi-health-check

One bash script that runs hourly on each Raspberry Pi. It stays **silent when
healthy** and sends a phone alert (via [ntfy](https://ntfy.sh)) only when
something is wrong. It also pings [healthchecks.io](https://healthchecks.io)
every run, so you get alerted if a Pi dies completely.

## What it checks

| Check | Alerts when | Repeat limit |
|---|---|---|
| Disk (`/`) | more than 85% full | once per 24 h |
| CPU temp | above 75 C | once per 24 h |
| Power/throttling | `vcgencmd get_throttled` is not `0x0` | once per 24 h |
| Memory | under 100 MB available | once per 24 h |
| SD card / kernel errors | I/O, ext4, under-voltage, or mmc error/timeout/crc lines in the kernel log | once per 24 h |
| Security updates | 1 or more pending | once per 7 days |
| Fallout log (Pi 1 only) | `cron.out` older than 26 h, during migration season only (Mar 1-Jun 15, Aug 1-Nov 15) | once per 24 h |

Notes:
- It never runs `apt update` or installs anything. It only reads the list.
- The kernel log and the "since boot" power flags persist until reboot, so
  after one real event you'll be reminded every 24 h until you reboot.
- If sending an alert fails, the problem is written to
  `~/.pi-health-state/errors.log` and the script retries next hour.

## Install (repeat on each Pi)

1. Get the code:
   ```bash
   git clone https://github.com/millen85/pi-health-check.git ~/pi-health-check
   ```
2. Make the script runnable:
   ```bash
   chmod +x ~/pi-health-check/pi-health-check.sh
   ```
3. Create your private config from the example:
   ```bash
   cp ~/pi-health-check/pi-health.conf.example ~/.pi-health.conf
   ```
4. Edit it (set `NTFY_TOPIC`, optionally `HC_PING_URL`):
   ```bash
   nano ~/.pi-health.conf
   ```
   - **Pi 1 only:** set `FALLOUT_LOG="yes"`. Leave `"no"` on Pi 2.
5. Test that alerts reach your phone (subscribe to your topic in the ntfy app first):
   ```bash
   ~/pi-health-check/pi-health-check.sh --test
   ```
6. See every check's result:
   ```bash
   ~/pi-health-check/pi-health-check.sh --verbose
   ```
7. Add the hourly cron job. Open the editor:
   ```bash
   crontab -e
   ```
   and add this line at the bottom:
   ```
   7 * * * * /home/matt/pi-health-check/pi-health-check.sh
   ```
8. (Optional, recommended) Let the script read the kernel log. First check whether it already can:
   ```bash
   ~/pi-health-check/pi-health-check.sh --verbose | grep dmesg
   ```
   If it says `via dmesg`, `via sudo dmesg`, or `via journalctl -k`, you're done.
   If you see an error about not reading the kernel log, run:
   ```bash
   echo 'matt ALL=(root) NOPASSWD: /usr/bin/dmesg' | sudo tee /etc/sudoers.d/pi-health
   sudo chmod 440 /etc/sudoers.d/pi-health
   sudo visudo -c
   ```
   (`visudo -c` should print "parsed OK".)

To update later: `cd ~/pi-health-check && git pull`. Your config and state are
outside the repo, so they are untouched.

## How to test a threshold

Temporarily set a limit the Pi will fail, run `--verbose`, then put it back.
Example for the disk check (the Pi is at about 23%):

1. `nano ~/pi-health-check/pi-health-check.sh`
2. Change `DISK_MAX_PCT=85` to `DISK_MAX_PCT=10`
3. Run `~/pi-health-check/pi-health-check.sh --verbose`. You should see `ALERT SENT (disk)`.
4. Change it back to `85`.
5. Clear the 24 h memory so you can re-test: `rm ~/.pi-health-state/*.last`

Be sure to restore the value, or `git checkout pi-health-check.sh` undoes your edit.

## How to change a threshold

All settings are variables at the top of `pi-health-check.sh`, under
"SETTINGS YOU MIGHT WANT TO CHANGE": `DISK_MAX_PCT`, `TEMP_MAX_C`,
`MEM_MIN_MB`, `FALLOUT_MAX_HOURS`, `DEDUPE_HOURS`, `UPDATES_DEDUPE_HOURS`, and
the migration season dates. Edit, save. No restart needed; cron picks it up on
the next run. If you change a threshold in the repo, commit it so both Pis
stay identical.

## Files

| File | What it is |
|---|---|
| `pi-health-check.sh` | The script (identical on both Pis) |
| `pi-health.conf.example` | Template for the per-Pi config |
| `~/.pi-health.conf` | Your real config (not in git) |
| `~/.pi-health-state/` | Dedupe timestamps and `errors.log` (not in git) |

## Troubleshooting

- No alerts arriving: `cat ~/.pi-health-state/errors.log`
- Cron not running it: check `grep CRON /var/log/syslog | tail` or `journalctl -u cron | tail`
- Config missing: the script logs it to `errors.log` and exits.
