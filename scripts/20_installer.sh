#!/bin/bash
set -eo pipefail

echo "**************************************************************"
echo "*                                                            *"
echo "*                 Cylo Base Installer 1.0                    *"
echo "*                     Installing Apps:                       *"
echo "*                                                            *"
echo "**************************************************************"
echo "Postgresql"
echo "redis-server"
echo "Chatwood"
echo "**************************************************************"
echo " "

# Create Directories
echo "Creating default directories"
mkdir -p /home/appbox/chatwoot

echo "Installing Postgresql"
/scripts/30_postgresql.sh

echo "Installing redis-server"
/scripts/30_redis-server.sh

echo "Installing Chatwood"
/scripts/40_chatwoot.sh

# Clean Up
echo "Cleaning up"
chown -R appbox:appbox /home/appbox

rm -fr /sources

apt autoremove -y
apt-get clean
rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# --- Appbox installed callback -------------------------------------------------
# my_init runs this script to completion before it starts any service, and it
# runs on every boot. The callback is therefore marked pending only on the
# first boot of this container and sent in the background. The API accepts one
# installed callback per install or update and rejects the rest (401 once the
# token has been used or cleared); the old blocking retry loop here kept
# Chatwoot, PostgreSQL and Redis down after every restart. The helper retries
# network errors, 408, 429 and 5xx and stops on any other status.
if [[ ! -f /etc/app_configured ]]; then
    touch /etc/appbox_callback_pending
    touch /etc/app_configured
fi

if [[ -f /etc/appbox_callback_pending ]]; then
    (
        /scripts/appbox-installed-callback || true
        rm -f /etc/appbox_callback_pending
    ) </dev/null &
fi
