# Remote Power Field Guide

Wake a PC that is fully powered off, put it to sleep, and shut it down — all from a browser tab, over your own network.

Written for someone who has never touched a BIOS power setting before. Works for any desktop with a wired network card, using [Wake-on-LAN](https://en.wikipedia.org/wiki/Wake-on-LAN), [Sleep-On-LAN](https://github.com/SR-G/sleep-on-lan) and [UpSnap](https://github.com/seriousm4x/UpSnap).

📄 **[Read the formatted guide](docs/Remote-Power-Field-Guide.pdf)** (PDF) · [HTML version](docs/remote-power-field-guide.html)

---

## Why this exists

Most Wake-on-LAN guides stop at "tick Wake on Magic Packet in Device Manager." That covers waking from *sleep*. It does not cover waking from a *full shutdown*, which is a separate setting with a different name on every vendor's driver, and it says nothing about how you'd sleep or shut the machine down again remotely.

This guide covers the whole round trip, in the order that makes each stage independently testable.

## Power states, because every setting below depends on them

| State | What it is |
|-------|-----------|
| **S0** | Running. Normal on. |
| **S3** | Sleep. RAM powered, everything else dark. |
| **S4** | Hibernate. RAM written to disk, then off. |
| **S5** | Soft off. What "Shut down" gives you. |
| **G3** | Unplugged. Nothing can wake it. Ever. |

## How the three pieces fit together

**Waking happens in hardware.** A shut-down PC is not really off — the PSU keeps a low-voltage standby rail alive and the network card sips from it, watching every packet on the wire. When it sees a "magic packet" containing its own MAC address, it electrically pokes the motherboard and the machine boots. No software is involved, because none is running.

**Sleeping and shutting down happen in software.** The PC is already on, so something running on it must receive the request. That is **Sleep-On-LAN** (SOL), a small daemon that listens on an HTTP port and exposes URLs like `/sleep` and `/halt`.

**UpSnap** is the dashboard that drives both.

```
UpSnap  ──UDP :9, magic packet (broadcast)──▶  Network card   (PC in S3/S4/S5)
UpSnap  ──HTTP :8009  /sleep or /halt────────▶  SOL daemon     (PC in S0)
```

## Before you start

- A desktop PC with a **wired** ethernet connection (Wi-Fi wake is a different and far less reliable feature, not covered here)
- Administrator access on that PC
- UpSnap running somewhere on the same network
- Physical access to the PC — Stage 1 happens before Windows loads

Throughout, replace `<PC-IP>`, `<PC-MAC>`, `<UPSNAP-IP>` and `<BROADCAST>` (for `192.168.1.0/24` that is `192.168.1.255`) with your own values.

---

## Stage 1 — BIOS / UEFI: keep the card powered

If the firmware cuts power to the network card at shutdown, nothing you do in Windows can help.

1. **Enter firmware setup.** Press <kbd>Del</kbd> or <kbd>F2</kbd> repeatedly while booting. If it's too fast, hold <kbd>Shift</kbd> while clicking Restart in Windows → Troubleshoot → Advanced options → UEFI Firmware Settings.

2. **Find power management.** Usually `Advanced → APM Configuration` (ASUS), `Settings → Advanced → Wake Up Event Setup` (MSI), `Power Management` (Gigabyte, ASRock).

3. **Enable wake-from-network.** The name varies:
   - **Power On By PCI-E / PCI** — ASUS, ASRock
   - **Resume By PCI-E Device** — Gigabyte
   - **Resume By PME** / **PME Event Wake Up** — MSI, older boards
   - **Wake on LAN** / **Wake on Onboard LAN** — Dell, HP, Lenovo prebuilts

4. **Disable the settings that starve the card.**
   - **ErP Ready** (also **EuP**) → Disabled
   - **Deep Sleep / Deep S5** → Disabled

   These meet European standby-power limits by cutting the +5V standby rail when the PC is off. That rail is exactly what your network card runs on.

5. **Save and exit** (usually <kbd>F10</kbd>).

> [!WARNING]
> **ErP Ready left enabled** is the number one reason wake-from-shutdown fails while wake-from-sleep works perfectly. Sleep keeps the rail alive regardless; only a full shutdown exposes it.

> [!CAUTION]
> **Every BIOS update undoes this stage.** Flashing firmware resets CMOS to factory defaults, putting ErP Ready back to Enabled and Power On By PCI-E back to Disabled. The Windows half is untouched and keeps reporting healthy, so the machine looks fine right until the next shutdown — at which point it is unreachable. Re-apply this stage after *any* BIOS update.

**✅ Checkpoint:** shut the PC down completely, then look at the ethernet port. The link light should still be lit or blinking. If it's dark, the card has no standby power — go back. Don't continue until that light is on.

---

## Stage 2 — Windows and the network card

Three settings in three different places, all of which must be right.

1. **Turn off Fast Startup.** Windows' "Shut down" hibernates the kernel by default, tearing down the network card. `Control Panel → Power Options → Choose what the power buttons do → Change settings that are currently unavailable`, untick **Turn on fast startup**.

   Or, as Administrator:
   ```powershell
   powercfg /hibernate off
   ```
   That disables Fast Startup and hibernation together. To keep hibernation, use the checkbox instead.

2. **Allow the card to wake the PC.** <kbd>Win</kbd>+<kbd>X</kbd> → Device Manager → Network adapters → your wired card → **Power Management** tab. Tick all three:
   - Allow the computer to turn off this device to save power
   - **Allow this device to wake the computer**
   - **Only allow a magic packet to wake the computer**

   That third one matters: without it, ordinary broadcast traffic wakes the PC at random hours.

3. **Set the driver properties**, on the **Advanced** tab:

   | Property | Set to | Found on | Covers |
   |---|---|---|---|
   | Wake on Magic Packet | Enabled | Intel, Realtek, Broadcom | Wake from sleep/hibernate (S3/S4) |
   | **Enable PME** | Enabled | Intel | **Wake from full shutdown (S5)** |
   | **Shutdown Wake-On-Lan** | Enabled | Realtek | **Wake from full shutdown (S5)** |
   | Wake on Pattern Match | Disabled | Intel, Realtek | Stops random traffic waking it |
   | Energy Efficient Ethernet | Disabled | Most | Can drop the link before a packet lands |
   | Green Ethernet | Disabled | Realtek | Same problem, different name |

   Or run [`scripts/01-enable-wol-nic.ps1`](scripts/01-enable-wol-nic.ps1), which sets whichever of these your driver exposes.

4. **Verify from PowerShell** rather than trusting the checkboxes:
   ```powershell
   Get-NetAdapterAdvancedProperty -Name 'Ethernet' | Format-Table DisplayName, DisplayValue
   powercfg /devicequery wake_armed
   ```
   Your card must appear in the `wake_armed` list.

> [!WARNING]
> **The separate-settings trap.** "Wake on Magic Packet" and the S5 property (**Enable PME** on Intel, **Shutdown Wake-On-Lan** on Realtek) are two different settings for two different power states. Enabling only the first gives you a PC that wakes reliably from sleep and ignores you completely after a shutdown — the exact symptom most guides never explain.

> [!CAUTION]
> **This will break again later.** Network driver updates reset every Advanced-tab property to its factory default, and the S5 property ships disabled. If Wake-on-LAN mysteriously stops working months from now, check here first.

---

## Stage 3 — Prove the wake works

Test this alone, before adding SOL or UpSnap.

1. **Get the MAC** of the wired card that is `Up`:
   ```powershell
   Get-NetAdapter | Format-Table Name, MacAddress, Status
   ```
   Ignore VMware, VirtualBox, Hyper-V, Tailscale and VPN adapters — they don't exist when the PC is off.

2. **Shut the PC down.** Not sleep — a real shutdown.

3. **Send a magic packet** from another machine on the same subnet:
   ```bash
   wakeonlan <PC-MAC>
   # or
   etherwake -i eth0 <PC-MAC>
   ```

4. **It should power on within a couple of seconds.**

> [!NOTE]
> **The sender must be on the same subnet.** Magic packets are broadcast, and routers don't forward broadcasts between subnets. If UpSnap is on a different VLAN the packet dies at the router. Either run UpSnap on the same subnet, or add a **static ARP entry** on the router mapping the PC's IP to its MAC so a unicast packet can reach a switched-off machine.

---

## Stage 4 — Install Sleep-On-LAN on the PC

This gives you sleep and shutdown.

You *could* let UpSnap shut Windows down with `net rpc shutdown`, but that stores a Windows username and password in plain text in UpSnap's database and loosens Windows' remote-access defaults. SOL avoids both.

1. **Download** the latest release from [SR-G/sleep-on-lan](https://github.com/SR-G/sleep-on-lan/releases). Put the Windows 64-bit binary in `C:\Tools\sleep-on-lan\` as `sol.exe`.

2. **Create `sol.json`** beside it — see [`examples/sol.windows.json`](examples/sol.windows.json). Note the **doubled backslashes**; JSON requires them and a single backslash stops SOL from starting.

   Each entry in `Commands` becomes a URL: `"Operation": "halt"` creates `http://<PC-IP>:8009/halt`.

3. **Choose how forceful the shutdown is:**

   | Command | Behaviour |
   |---|---|
   | `shutdown.exe -s -t 0 -f` | Immediate. Force-closes everything, no prompt, no cancel. Unsaved work is lost. |
   | `shutdown.exe -s -t 30 -f` | 30-second countdown with a warning. Cancel with `shutdown /a`. Safer if you sit at this PC. |

4. **Open the firewall, scoped to UpSnap only:**
   ```powershell
   New-NetFirewallRule -DisplayName 'Sleep-On-LAN HTTP' -Direction Inbound `
       -Protocol TCP -LocalPort 8009 -RemoteAddress <UPSNAP-IP> -Action Allow
   ```
   SOL has **no authentication**. Anyone who can reach port 8009 can shut the PC down with one web request, so restricting the source address is the only thing protecting the endpoint.

5. **Make it start with Windows.** `sol.exe` is a plain console program, so `sc.exe create` fails with error 1053 when it doesn't answer the service manager. A scheduled task running as `SYSTEM` does the same job with nothing extra installed — see [`scripts/02-install-sol.ps1`](scripts/02-install-sol.ps1).

6. **Check it answers:**
   ```powershell
   curl http://127.0.0.1:8009/
   ```

> [!NOTE]
> **If nothing is listening,** check antivirus quarantine first. `sol.exe` is an unsigned binary that opens a network listener and calls shutdown APIs — textbook-suspicious. Add the folder as an exclusion.

> [!NOTE]
> **Sleep may actually hibernate.** With hibernation enabled, `SetSuspendState` hibernates (S4) rather than sleeping (S3) whatever arguments you pass. Usually fine — WoL works from both. For real sleep, `powercfg /hibernate off` first.
>
> Also: verifying the task from a non-administrator prompt reports *Access is denied* or *not found*, because a `SYSTEM` task is hidden from ordinary users. That does not mean it failed — check from an elevated prompt.

---

## Stage 5 — Wire it up in UpSnap

1. **Add the device** (or edit the auto-discovered one): name, `<PC-IP>`, `<PC-MAC>`, netmask usually `255.255.255.0`.

   If the PC runs VMware, VirtualBox or Hyper-V, check the MAC carefully — auto-discovery sometimes picks a virtual adapter that doesn't exist when the machine is off.

2. **Make sure the PC answers ping.** UpSnap decides online/offline by **pinging**, and it hides the sleep and shutdown buttons on any device it believes is off. A perfectly healthy PC that blocks ICMP shows as powered down with no controls — which looks exactly like broken Wake-on-LAN and sends you back to BIOS settings that were never the problem.

   ```powershell
   Get-NetFirewallRule -Direction Inbound |
       Where-Object { $_.DisplayName -like 'File and Printer Sharing (Echo Request*' -and
                      $_.Profile -notmatch '^Public$' } |
       Enable-NetFirewallRule
   ```

   Verify from **another** machine. Local traffic bypasses the firewall, so a PC can always ping its own address and reports success while every other host gets nothing.

3. **Sleep-On-LAN section:** toggle on, **SOL Port** `8009` — must match the `HTTP:` listener in `sol.json`.

4. **Shutdown section:**

   | Field | Value |
   |---|---|
   | Shutdown command | `curl -s -m 5 http://{{ DEVICE_IP }}:8009/halt` |
   | Shutdown Timeout | `30` |
   | Enable shutdown cron | Off |
   | Require Confirmation | On — strongly recommended with an immediate shutdown |

   `{{ DEVICE_IP }}` and `{{ DEVICE_MAC }}` are UpSnap placeholders, substituted when the command runs.

5. **Shutdown Timeout does not delay the shutdown.** It's how long UpSnap waits before re-checking whether the device went offline. The actual delay is the `-t` value in `sol.json`. Set the UpSnap timeout comfortably higher, or UpSnap re-probes mid-countdown and reports the device still online.

6. **Test the path before pressing anything destructive.** The command runs *where UpSnap runs*:
   ```bash
   docker exec upsnap curl -s -m 5 http://<PC-IP>:8009/     # Docker
   curl -s -m 5 http://<PC-IP>:8009/                        # binary / LXC
   ```
   The trailing `/` is the harmless status page. Don't test with `/halt` unless you mean it.

> [!CAUTION]
> **If UpSnap is not the Docker image,** the helper tools are missing. The official image ships `curl`, `sshpass` and Samba; a bare LXC or manual binary install has none of them. UpSnap hands your command to the shell, gets `curl: not found`, and reports a failed shutdown with no useful explanation. Run `command -v curl` on that host first.

---

## Troubleshooting

| Symptom | Most likely cause | Fix |
|---|---|---|
| **UpSnap shows the PC as off while it's clearly running; sleep/shutdown buttons missing** | PC blocks inbound ping, so UpSnap's online check fails | Enable inbound ICMPv4 echo (Stage 5 step 2). Test from another host |
| **Everything broke right after a BIOS update** | CMOS reset re-enabled ErP Ready, disabled Power On By PCI-E | Re-apply Stage 1; Windows settings survived |
| **Wakes from sleep, but not after shutdown** | S5 driver property off, or ErP Ready on | Set Enable PME / Shutdown Wake-On-Lan; disable ErP Ready |
| Nothing wakes it, link light dark when off | No standby power to the card | BIOS: disable ErP / Deep Sleep, enable Power On By PCI-E |
| Worked for months, suddenly stopped | Driver update reset the Advanced tab | Re-apply Stage 2 step 3 |
| Works from a PC on the same switch, not from UpSnap | UpSnap on a different VLAN; broadcasts don't cross routers | Same subnet, or static ARP entry on the router |
| Wakes by itself at random times | Wake on Pattern Match enabled, or a wake timer | Tick "Only allow a magic packet"; run `powercfg /lastwake` |
| Shutdown button does nothing | `curl` missing where UpSnap runs, or firewall blocks 8009 | Run the Stage 5 step 6 test and read the error |
| SOL not listening after reboot | Antivirus quarantined `sol.exe`, or task didn't register | Check quarantine, add exclusion, re-register from elevated prompt |
| Sleep hibernates instead | Hibernation enabled | Accept it, or `powercfg /hibernate off` |
| Wake works only sometimes | Energy Efficient Ethernet dropping the link | Disable EEE / Green Ethernet |

### Useful commands

```powershell
powercfg /devicequery wake_armed   # which devices may wake this PC
powercfg /lastwake                 # what woke it last time
powercfg /a                        # which sleep states the hardware supports

Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' -Name HiberbootEnabled
# 0 means Fast Startup is off
```

Or run [`scripts/check-readiness.ps1`](scripts/check-readiness.ps1), which checks all of the above at once and tells you what's wrong.

---

## Linux targets

Stages 1, 3 and 5 are identical. Stages 2 and 4 differ.

**Enable Wake-on-LAN:**
```bash
sudo ethtool eth0 | grep -i wake     # "Wake-on: d" means disabled
sudo ethtool -s eth0 wol g           # g = wake on magic packet
```

That resets at reboot. To persist with NetworkManager:
```bash
nmcli connection modify "Wired connection 1" 802-3-ethernet.wake-on-lan magic
```

Otherwise use a systemd unit — see [`examples/wol.service`](examples/wol.service).

**Sleep-On-LAN:** same config structure, different commands — see [`examples/sol.linux.json`](examples/sol.linux.json) and [`examples/sleep-on-lan.service`](examples/sleep-on-lan.service).

**Sleeping over UDP:** SOL can also be triggered by a magic packet on UDP 9 using the machine's **MAC address reversed** — a card with `c4:d9:87:7a:78:35` sleeps on a packet for `35:78:7a:87:d9:c4`. The reversal stops an ordinary wake packet from immediately putting a running machine back to sleep. UpSnap uses the HTTP path instead, as it's easier to authorise and returns a real success/failure.

---

## Repository contents

```
docs/        the guide as HTML and PDF
examples/    sol.json for Windows and Linux, systemd units
scripts/     PowerShell helpers, all parameterised — no hardcoded addresses
```

Every script takes parameters and defaults to safe values. Read them before running; they all require an elevated prompt and say so.

## Credits

- [Sleep-On-LAN](https://github.com/SR-G/sleep-on-lan) by SR-G
- [UpSnap](https://github.com/seriousm4x/UpSnap) by seriousm4x

## License

MIT — see [LICENSE](LICENSE).
