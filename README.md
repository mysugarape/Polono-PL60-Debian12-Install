# Polono PL60 on Linux (CUPS): fix the ~1 minute print delay and share it via AirPrint

The Polono PL60 is detected by CUPS but labels come out late, blank or not at all?
This repo documents what actually went wrong on a headless Debian 12 server and gives
you a one-shot installer that sets up CUPS, a working driver and network sharing
for Mac, Windows, iOS and Android.

## TL;DR

- **Symptom:** the printer is found, but every job takes about 50 seconds before the label prints.
  Writing TSPL directly to `/dev/usb/lp0` prints instantly.
- **Cause:** it is not the printer, not USB and not the driver. CUPS' `gstoraster` filter asks
  `colord` (colour management) over D-Bus for a colour profile. On a server without a desktop
  nobody answers, and the filter waits **2 x 25 s** for the D-Bus timeout.
- **Fix:** `sudo systemctl mask colord` (see below). A text job went from **53 s to 4 s**.

## Tested with

| Item | Version |
| --- | --- |
| OS | Debian 12 (headless server) |
| CUPS / cups-filters / Ghostscript | 2.4.2 / 1.28.17 / 10.0.0 |
| Driver | `tspl-cups-driver` 1.3.6 (free TSPL driver by Run The Wall) |
| Printer | Polono PL60, USB (`2aaf:9006`), 4x6 inch labels, 203 dpi |
| Clients | macOS via AirPrint works. Windows, iOS and Android are not tested yet. |

The one-shot installer (`install-pl60-drucker.sh`) is assembled from the steps that were
verified one by one on that server. It has not been run on a clean machine yet,
so please open an issue if something fails.

## 1. Is this your problem? (diagnosis)

Turn on debug logging, print one job and look at the time stamps of that job:

```bash
sudo cupsctl --debug-logging
echo "test" > /tmp/test.txt && lp -d YOUR_QUEUE /tmp/test.txt
# replace 17 with the job number printed by lp
grep "\[Job 17\]" /var/log/cups/error_log | grep -E "Started filter|exited|FindDeviceById|NoReply"
sudo cupsctl --no-debug-logging
```

You have the colord problem if

- `gstoraster` needs about 50 s between "Started filter" and "exited", and
- the log contains `FindDeviceById(cups-YOUR_QUEUE)` followed by
  `org.freedesktop.DBus.Error.NoReply` (twice, 25 s apart).

You can also reproduce it without a printer job:

```bash
time cupsfilter -p /etc/cups/ppd/YOUR_QUEUE.ppd -m application/vnd.cups-raster /tmp/test.txt > /dev/null
```

If that takes about 50 s, the delay is in the filter chain and not on the USB side.
Test the USB side separately; it should be instant:

```bash
printf 'SIZE 101 mm,152 mm\nGAP 3 mm,0 mm\nCLS\nTEXT 60,40,"0",0,1,1,"DIRECT TEST"\nPRINT 1\n' > /dev/usb/lp0
```

## 2. The fix

```bash
sudo systemctl stop colord
sudo systemctl mask colord
sudo systemctl restart cups
```

Undo with `sudo systemctl unmask colord`.

Masking colord disables colour profile management. That is irrelevant for monochrome label
printing on a server, but do not do this on a desktop where you rely on display colour profiles.
On a desktop session colord normally answers quickly, so you probably do not have this problem there.

## 3. One-shot installer

`install-pl60-drucker.sh` installs and configures everything on Debian 12:

1. CUPS, cups-filters, Ghostscript, Avahi (and removes `cups-browsed`)
2. the free TSPL driver from the project's apt repository
3. masks colord (the fix above)
4. creates the print queue with your label size, resolution, darkness and speed
5. optional sideways offset for the print (see below)
6. shares the printer in your LAN (IPP / AirPrint)
7. restricts CUPS (port 631) and mDNS (5353/udp) in `ufw` to your LAN

Edit the settings block at the top of the script, then run:

```bash
sudo bash install-pl60-drucker.sh
```

| Setting | Default | Meaning |
| --- | --- | --- |
| `QUEUE` | `PL60-tspl` | printer name on the network |
| `DEVICE_URI` | `tspl:///dev/usb/lp0` | USB device (`tspl://auto` if you have several USB printers) |
| `MEDIA` | `na_index-4x6_4x6in` | label size (4x6 inch, about 100x150 mm) |
| `RESOLUTION` | `203dpi` | the PL60 is a 203 dpi printer |
| `DARKNESS` | `8` | 0-15 |
| `PRINT_SPEED` | `30` | 10-60 (inch per second x 10); lower is quieter |
| `SHIFT_MM` | `2` | shifts the print to the right, `0` = off |
| `LAN_CIDR` | `192.168.31.0/24` | **change this to your network**, otherwise the firewall blocks your clients |
| `MASK_COLORD` | `yes` | applies the delay fix |
| `PRINT_TEST` | `no` | `yes` prints one test label at the end |

You can run the script again; it rebuilds the queue each time.

## 4. Which driver?

Both drivers I tried had the same 50 s delay, so the driver was not the cause.
I ended up with the free TSPL driver because it is open source and sends `GAP`, `DENSITY`
and `SPEED` explicitly. The vendor driver from Polono (filter `raster-tspl`) produced
almost identical bitmap data and also worked. The Polono archive is not needed for this setup.

CUPS 2.4 prints `Printer drivers are deprecated` when creating a queue with a PPD.
That is only a warning.

If the vendor driver prints nothing, check its filter with `ldd /usr/lib/cups/filter/<filter>`.
A missing library such as `libcrypt.so.1` has been reported on Fedora.

## 5. Sideways offset

The driver has no option for a horizontal offset, but my labels printed about 2 mm too far left.
The installer adds a tiny wrapper filter (`rastertotspl-shift`) that rewrites the TSPL
`BITMAP 0,0,` command to `BITMAP <dots>,0,` (203 dpi = 8 dots per mm). A copy of the PPD points
to this wrapper, so package updates do not overwrite it.

Change `SHIFT_MM` and run the script again to adjust. Content that touches the right edge is
clipped by the same amount.

To measure your own offset, print a 4x6 inch page with a frame 1 mm from the edge
and a ruler scale and compare the margins left and right.

## 6. Clients

- **macOS (tested):** System Settings > Printers & Scanners > `+`. The printer shows up as
  `YOUR_QUEUE @ hostname`. Under "Use" it must say **AirPrint**, not "Generic PostScript Printer".
  If it does not appear: tab IP, address of the server, protocol IPP, queue `printers/YOUR_QUEUE`.
  In the print dialog set the paper size to 4 x 6 in and scaling to 100 %.
- **Windows (not tested):** Add printer, "The printer that I want isn't listed", select a shared
  printer by name: `http://SERVER_IP:631/printers/YOUR_QUEUE`.
- **iOS (not tested):** AirPrint, no setup needed in the same network.
- **Android (not tested):** enable the default print service (Mopria); the printer should appear.

## 7. Troubleshooting

| Problem | Check |
| --- | --- |
| Labels come out blank | Paper nearly empty or misloaded; guides at the label edge. The filters produce a proper bitmap, so check the media first. |
| Prints but wrong size or cut off | `MEDIA` and `RESOLUTION` (203 dpi) in the script and the paper size in the print dialog |
| Mac does not find the printer | `systemctl status avahi-daemon`, `ufw status` (needs 5353/udp from your LAN), same network |
| Still slow after the fix | Run the diagnosis again and check which filter step takes the time |
| Print too light or too dark | `lpadmin -p YOUR_QUEUE -o Darkness=10` (0-15) |
| Too loud | `lpadmin -p YOUR_QUEUE -o PrintSpeed=30` or lower |

## Security notes

- The installer adds the apt repository of the third-party driver project as root and installs
  its package. Read the script and the project before you run it.
- CUPS sharing and the remote admin interface are enabled for your LAN only (ufw rules).
  The installer removes a blanket `631/tcp` allow rule if there is one.

## Credits

- [tspl-cups-driver](https://github.com/RunTheWall/tspl-cups-driver) by Run The Wall: the free TSPL driver used here.

## License

Add your license here.
