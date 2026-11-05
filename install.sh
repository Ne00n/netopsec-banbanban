#!/bin/bash
set -e
if [[ $(id -u) -ne 0 ]] ; then echo "Please run as root" ; exit 1 ; fi
apt-get install curl jq ipset iptables wget cron -y
wget -O /usr/local/bin/update-banlist.sh https://raw.githubusercontent.com/Ne00n/netopsec-banbanban/refs/heads/master/update.sh
echo "b3061de120dbd5b7005bb81d5203ffea576aa8090e3508b2757d72e49219b59b /usr/local/bin/update-banlist.sh" | sha256sum -c --status - || { echo "Checksum mismatch, aborting." >&2; exit 1; }
chmod +x /usr/local/bin/update-banlist.sh

cat > "/etc/cron.d/update-banlist" <<EOF
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin 
*/5 * * * * root /usr/local/bin/update-banlist.sh 2>&1
@reboot root sleep 30 && /usr/local/bin/update-banlist.sh 2>&1
EOF
chown root:root "/etc/cron.d/update-banlist"
chmod 644 "/etc/cron.d/update-banlist"
echo "Installation done, cronjob will execute every 5 minutes to update the banlist."