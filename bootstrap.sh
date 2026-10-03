#!/usr/bin/env bash
set -e

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_DIR"

echo "=== 1. Образ и контейнер ==="
docker build -t my-script .
docker rm -f my-app 2>/dev/null || true
docker create -p 8080:8080 --name my-app -v /var/log:/var/log:ro my-script

echo "=== 2. RAID/LVM на loop-устройствах ==="
if grep -q "^md0" /proc/mdstat; then
  echo "   RAID-массив уже собран — шаг пропущен (скрипт рассчитан на чистую машину)."
else
  sudo apt-get update -qq
  sudo apt-get install -y -qq mdadm lvm2 > /dev/null
  sudo mkdir -p /mnt/raid-lab
  cd /mnt/raid-lab
  sudo dd if=/dev/zero of=disk1.img bs=1M count=512 status=none
  sudo dd if=/dev/zero of=disk2.img bs=1M count=512 status=none
  sudo dd if=/dev/zero of=disk3.img bs=1M count=512 status=none
  LOOP1=$(sudo losetup -fP --show disk1.img)
  LOOP2=$(sudo losetup -fP --show disk2.img)
  LOOP3=$(sudo losetup -fP --show disk3.img)
  yes | sudo mdadm --create /dev/md0 --level=1 --raid-devices=2 "$LOOP1" "$LOOP2"
  sudo mkfs.ext4 -F /dev/md0
  sudo mkdir -p /mnt/raid && sudo mount /dev/md0 /mnt/raid
  yes | sudo pvcreate "$LOOP3"
  sudo vgcreate vg_data "$LOOP3"
  yes | sudo lvcreate -L 200M -n lv_logs vg_data
  sudo mkfs.ext4 -F /dev/vg_data/lv_logs
  sudo mkdir -p /mnt/logs && sudo mount /dev/vg_data/lv_logs /mnt/logs
  cd "$REPO_DIR"
fi

echo "=== 3. Nginx и TLS ==="
sudo apt-get install -y -qq nginx openssl > /dev/null
sudo openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout /etc/ssl/private/my-app.key \
  -out /etc/ssl/certs/my-app.crt \
  -subj "/CN=my-app.local"

sudo tee /etc/nginx/sites-available/my-app > /dev/null <<'NGINXEOF'
server {
    listen 80;
    server_name _;
    return 301 https://$host$request_uri;
}
server {
    listen 443 ssl;
    server_name _;
    ssl_certificate     /etc/ssl/certs/my-app.crt;
    ssl_certificate_key /etc/ssl/private/my-app.key;
    location / {
        proxy_pass http://127.0.0.1:8080;
    }
}
NGINXEOF

sudo ln -sf /etc/nginx/sites-available/my-app /etc/nginx/sites-enabled/
sudo rm -f /etc/nginx/sites-enabled/default
sudo nginx -t
sudo systemctl reload nginx

echo "=== 4. systemd-служба ==="
sudo tee /etc/systemd/system/my-app.service > /dev/null <<'UNITEOF'
[Unit]
Description=my-app service
After=docker.service
Requires=docker.service

[Service]
ExecStart=docker start -a my-app
Restart=on-failure

[Install]
WantedBy=multi-user.target
UNITEOF

sudo systemctl daemon-reload
sudo systemctl enable my-app
sudo systemctl start my-app
sleep 3

echo "=== 5. Самопроверка ==="
printf "Ожидание готовности сервиса"
READY=no
for i in $(seq 1 15); do
    if curl -ksf -o /dev/null https://127.0.0.1/; then READY=yes; break; fi
    printf "."
    sleep 2
done
echo
if [ "$READY" = yes ]; then
    curl -ksI https://127.0.0.1/ | head -1
else
    echo "ВНИМАНИЕ: сервис не ответил за 30 секунд."
    echo "Смотрите: sudo systemctl status my-app  и  docker logs my-app"
fi
cat /proc/mdstat
df -h | grep -E "raid|logs" || echo "ВНИМАНИЕ: тома RAID/LVM не смонтированы"
sudo systemctl status my-app --no-pager
echo "bootstrap.sh: готово"
