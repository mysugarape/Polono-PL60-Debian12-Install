#!/bin/bash
# =====================================================================
#  Polono PL60 Etikettendrucker - CUPS-Komplettinstallation (Debian 12)
#
#  Ergebnis: PL60 per USB am Server, im LAN freigegeben fuer Mac, PC
#  und Handy (IPP / AirPrint).
#  Aufruf:   sudo ./install-pl60-drucker.sh
#  Das Skript darf mehrfach laufen (es baut die Queue jeweils neu auf).
# =====================================================================

# ---- Einstellungen ----
QUEUE=PL60-tspl                    # Name des Druckers im Netz
DEVICE_URI=tspl:///dev/usb/lp0     # USB-Drucker (bei mehreren USB-Druckern: tspl://auto)
MEDIA=na_index-4x6_4x6in           # Etikett 4x6 Zoll (ca. 100x150 mm)
RESOLUTION=203dpi                  # PL60 = 203 dpi
DARKNESS=8                         # Druckdichte 0-15
PRINT_SPEED=30                     # 10-60 (Zoll/s x10), 30 = leise
SHIFT_MM=2                         # Versatz nach rechts in mm, 0 = aus
LAN_CIDR=192.168.31.0/24           # Heimnetz, das drucken darf (Firewall)
ADMIN_USER=${SUDO_USER:-root}      # darf CUPS verwalten (Gruppe lpadmin)
MASK_COLORD=yes                    # yes = colord abschalten (behebt ~50 s Verzoegerung)
PRINT_TEST=no                      # yes = am Ende 1 Testetikett drucken
# -- selten aendern --
KEY_URL=https://runthewall.github.io/tspl-cups-driver/apt/KEY.gpg
REPO_URL=https://runthewall.github.io/tspl-cups-driver/apt
SRC_PPD=/usr/share/ppd/tspl/tspl-label.ppd
NEW_PPD=/usr/share/cups/model/tspl-shift.ppd
WRAPPER=/usr/lib/cups/filter/rastertotspl-shift
LOGFILE=/var/log/install-pl60-drucker.log
# -----------------------

fail() { echo "FEHLER: $*"; exit 1; }

[ "$(id -u)" -eq 0 ] || fail "Bitte mit sudo starten"
[[ "$SHIFT_MM" =~ ^[0-9]+$ ]] || fail "SHIFT_MM muss eine ganze Zahl sein"
exec > >(tee -a "$LOGFILE") 2>&1
echo "=== Start $(date) ==="

echo "=== 1. Pakete installieren ==="
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y cups cups-filters ghostscript avahi-daemon avahi-utils curl ca-certificates \
  || fail "Paketinstallation fehlgeschlagen"
# cups-browsed wird nicht gebraucht und kann Queues ungefragt anlegen
apt-get purge -y cups-browsed >/dev/null 2>&1

echo "=== 2. Treiber (tspl-cups-driver, freier TSPL-Treiber) ==="
curl -fsSL "$KEY_URL" -o /usr/share/keyrings/tspl.gpg || fail "Schluessel-Download fehlgeschlagen"
echo "deb [signed-by=/usr/share/keyrings/tspl.gpg] $REPO_URL ./" > /etc/apt/sources.list.d/tspl.list
apt-get update
apt-get install -y tspl-cups-driver || fail "Treiber-Installation fehlgeschlagen"
[ -f "$SRC_PPD" ] || fail "PPD nicht gefunden: $SRC_PPD"

echo "=== 3. USB-Drucker pruefen ==="
modprobe usblp 2>/dev/null
if [ -e /dev/usb/lp0 ]; then
  echo "Drucker gefunden: /dev/usb/lp0"
else
  echo "WARNUNG: /dev/usb/lp0 fehlt (Drucker aus oder nicht angesteckt?) - Queue wird trotzdem angelegt"
fi

echo "=== 4. colord abschalten (sonst wartet der Filter ~50 s auf D-Bus) ==="
if [ "$MASK_COLORD" = yes ]; then
  systemctl stop colord 2>/dev/null
  systemctl mask colord
else
  echo "uebersprungen"
fi

echo "=== 5. Dienste und Benutzer ==="
systemctl enable --now cups avahi-daemon
usermod -aG lpadmin "$ADMIN_USER"

echo "=== 6. Seitlicher Versatz ($SHIFT_MM mm) ==="
PPD="$SRC_PPD"
if [ "$SHIFT_MM" -gt 0 ]; then
  [ -x /usr/lib/cups/filter/rastertotspl ] || fail "Filter rastertotspl fehlt"
  DOTS=$((SHIFT_MM * 8))        # 203 dpi = 8 Punkte pro mm
  cat > "$WRAPPER" <<EOF
#!/bin/bash
# schiebt die TSPL-Ausgabe von rastertotspl um $SHIFT_MM mm nach rechts
set -o pipefail
/usr/lib/cups/filter/rastertotspl "\$@" | LC_ALL=C sed 's/^BITMAP 0,0,/BITMAP $DOTS,0,/'
EOF
  chown root:root "$WRAPPER"; chmod 755 "$WRAPPER"
  sed 's#rastertotspl#rastertotspl-shift#' "$SRC_PPD" > "$NEW_PPD"
  PPD="$NEW_PPD"
  echo "Wrapper aktiv: $DOTS Punkte"
else
  rm -f "$WRAPPER" "$NEW_PPD"
  echo "aus"
fi

echo "=== 7. Queue anlegen ==="
lpadmin -x "$QUEUE" 2>/dev/null
lpadmin -p "$QUEUE" -E -v "$DEVICE_URI" -P "$PPD" \
  -o printer-is-shared=true -o media="$MEDIA" -o Resolution="$RESOLUTION" \
  -o Darkness="$DARKNESS" -o PrintSpeed="$PRINT_SPEED" || fail "Queue konnte nicht angelegt werden"
lpadmin -d "$QUEUE"

echo "=== 8. Freigabe im LAN (IPP / AirPrint) ==="
cupsctl --share-printers --remote-admin --no-debug-logging BrowseDNSSDSubTypes=_print,_universal
systemctl restart cups
sleep 2

echo "=== 9. Firewall ==="
if command -v ufw >/dev/null && ufw status | grep -q "Status: active"; then
  ufw delete allow 631/tcp >/dev/null 2>&1       # offene Freigabe fuer alle entfernen
  ufw allow from "$LAN_CIDR" to any port 631 proto tcp
  ufw allow from "$LAN_CIDR" to any port 5353 proto udp
else
  echo "ufw nicht aktiv - Firewall unveraendert"
fi

if [ "$PRINT_TEST" = yes ]; then
  echo "=== 10. Testetikett ==="
  cat > /tmp/pl60-test.ps <<'EOF'
%!PS
/mm {2.8346 mul} def
0.6 setlinewidth
1 mm 1 mm 99.6 mm 150.4 mm rectstroke
/Helvetica-Bold findfont 20 scalefont setfont
12 mm 76 mm moveto (PL60 OK) show
/Helvetica findfont 9 scalefont setfont
12 mm 68 mm moveto (Testetikett 4x6) show
showpage
EOF
  gs -q -dNOPAUSE -dBATCH -sDEVICE=pdfwrite -dDEVICEWIDTHPOINTS=288 -dDEVICEHEIGHTPOINTS=432 \
     -sOutputFile=/tmp/pl60-test.pdf /tmp/pl60-test.ps
  START=$(date +%s)
  JOB=$(lp -d "$QUEUE" -o print-scaling=none /tmp/pl60-test.pdf | awk '{print $4}')
  while lpstat -o 2>/dev/null | grep -q "$JOB"; do sleep 1; [ $(( $(date +%s) - START )) -gt 60 ] && break; done
  echo "Testdruck fertig nach $(( $(date +%s) - START )) s"
fi

echo "=== Ergebnis ==="
lpstat -d; lpstat -p; lpstat -v
echo "Filter: $(grep -m1 '^\*cupsFilter' /etc/cups/ppd/$QUEUE.ppd)"
timeout 8 avahi-browse -rt _ipp._tcp 2>/dev/null | grep -A7 "$QUEUE" | head -10
IP=$(hostname -I | awk '{print $1}')
echo
echo "Fertig. Drucker-Adresse fuer Clients: http://$IP:631/printers/$QUEUE"
echo "Mac:     Drucker & Scanner > + > '$QUEUE' (AirPrint) oder IP > IPP > printers/$QUEUE"
echo "Windows: Drucker hinzufuegen > per Namen > http://$IP:631/printers/$QUEUE"
echo "Log:     $LOGFILE"
