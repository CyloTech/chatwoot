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

until [[ $(curl -i -H "Accept: application/json" -H "Content-Type:application/json" -X POST "https://api.cylo.net/v1/apps/installed/${INSTANCE_ID}" | grep '200') ]]
    do
    sleep 5
done
