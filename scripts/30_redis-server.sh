#!/bin/bash
set -x

echo "**************************************************************"
echo "*                    Installing Redis                     *"
echo "**************************************************************"

if [ ! -f /etc/redis_installed ]; then
    if [ ! -f /home/appbox/config/redis/redis.conf ]; then
        mkdir -p /home/appbox/config/redis
        mkdir -p /home/appbox/logs/redis

        touch /home/appbox/logs/redis/redis-server.log
        chown -R appbox:appbox /home/appbox/config/redis
        chown -R appbox:appbox /home/appbox/logs/redis
        chown -R appbox:appbox /etc/redis/

cat << EOF > /home/appbox/config/redis/redis.conf
bind 127.0.0.1
port 6379
daemonize no
loglevel notice
logfile /home/appbox/logs/redis/redis-server.log
save 900 1
save 300 10
save 60 10000
stop-writes-on-bgsave-error yes
rdbcompression yes
rdbchecksum yes
dbfilename dump.rdb
dir /home/appbox/config/redis
EOF

    else
        echo "This is an update, redis updates should be done from within the app."
    fi
    touch /etc/redis_installed  
    echo "Setting up redis daemon"
    mkdir -p /etc/service/redis
cat << EOF > /etc/service/redis/run
#!/bin/bash
exec /bin/su -s /bin/bash appbox -c '/usr/bin/redis-server /home/appbox/config/redis/redis.conf'
EOF
    chmod +x /etc/service/redis/run
else
    echo "Redis is already installed, just start up."
fi