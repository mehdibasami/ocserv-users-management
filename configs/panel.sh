#!/bin/bash

SITE_DIR="/var/www/site"
CURRENT_DIR=$(pwd)

# Fallback values
HTTP_PORT=${HTTP_PORT:-8080}
HTTPS_PORT=${HTTPS_PORT:-2053}
BACKEND_PORT=${BACKEND_PORT:-8000}

if [[ $(id -u) != "0" ]]; then
    echo -e "\e[0;31mError: You must be root to run this install script.\e[0m"
    exit 1
fi

apt install -y python3 python3-pip python3-venv python3-dev build-essential \
    nginx cron curl gcc g++ make openssl nodejs ca-certificates gnupg

if [ "$?" = "0" ]; then
    echo -e "\e[0;32mPanel dependencies installation was successful.\e[0m"
else
    echo -e "\e[0;31mPanel dependencies installation failed.\e[0m"
    exit 1
fi

# ========================
# Back-end Setup
# ========================

echo -e "\e[0;32mBack-end Installing ...\e[0m"
rm -rf /var/www/html
rm -rf ${SITE_DIR}
mkdir -p ${SITE_DIR}
cp -r ${CURRENT_DIR}/back-end ${SITE_DIR}/back-end

rm -rf /lib/systemd/system/backend.service
rm -rf /lib/systemd/system/user_stats.service
cp ./configs/backend.service /lib/systemd/system
cp ./configs/user_stats.service /lib/systemd/system
cp ./configs/uwsgi.ini ${SITE_DIR}/back-end

python3 -m venv ${SITE_DIR}/back-end/venv
source ${SITE_DIR}/back-end/venv/bin/activate
pip install -U wheel setuptools
pip install -r ${SITE_DIR}/back-end/requirements.txt
pip install uwsgi==2.0.24
deactivate

mkdir -p ${SITE_DIR}/back-end/db
chmod -R www-data:www-data ${SITE_DIR}/back-end

# Schedule user management cron job
crontab -l | echo "59 23 * * * ${SITE_DIR}/back-end/venv/bin/python3 ${SITE_DIR}/back-end/manage.py user_management" | crontab -

# sudo access for www-data
echo 'www-data ALL=(ALL) NOPASSWD: \
    /usr/bin/rm /etc/ocserv/*, \
    /usr/bin/mkdir /etc/ocserv/*, \
    /usr/bin/touch /etc/ocserv/*, \
    /usr/bin/cat /etc/ocserv/*, \
    /usr/bin/sed /etc/ocserv/*, \
    /usr/bin/tee /etc/ocserv/*, \
    /usr/bin/ocpasswd, \
    /usr/bin/occtl, \
    /usr/bin/systemctl restart ocserv.service, \
    /usr/bin/systemctl status ocserv.service' | sudo tee -a /etc/sudoers >/dev/null

# ========================
# Front-end Setup
# ========================

echo -e "\e[0;32mFront-End Installing ...\e[0m"
sudo mkdir -p /etc/apt/keyrings
curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | sudo gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg
NODE_MAJOR=18
echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_$NODE_MAJOR.x nodistro main" | sudo tee /etc/apt/sources.list.d/nodesource.list

cd ${CURRENT_DIR}/front-end/
npm install
NODE_ENV=production npm run build
mkdir -p ${SITE_DIR}/front-end
cp -r ${CURRENT_DIR}/front-end/dist/* ${SITE_DIR}/front-end

# ========================
# Nginx Configuration
# ========================

echo -e "\e[0;32mNginx Configurations ...\e[0m"
rm -rf /etc/nginx/sites-enabled/default

if [[ -n "${DOMAIN}" ]]; then
cat <<EOT >/etc/nginx/conf.d/site.conf
server {
    listen ${HTTP_PORT};
    server_name ${DOMAIN};
    return 302 https://\$server_name\$request_uri;
}
server {
    listen ${HTTPS_PORT} ssl http2;
    server_name ${DOMAIN};

    ssl_certificate     /etc/nginx/certs/cert.pem;
    ssl_certificate_key /etc/nginx/certs/cert.key;

    location / {
        root /var/www/site/front-end;
        index index.html;
        try_files \$uri \$uri/ /index.html;
    }

    location ~ ^/(api) {
        proxy_pass http://127.0.0.1:${BACKEND_PORT};
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Host \$host;
    }
}
EOT
else
cat <<EOT >/etc/nginx/conf.d/site.conf
server {
    listen ${HTTP_PORT};
    location / {
        root /var/www/site/front-end;
        index index.html;
        try_files \$uri \$uri/ /index.html;
    }

    location ~ ^/(api) {
        proxy_pass http://127.0.0.1:${BACKEND_PORT};
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Host \$host;
    }
}
EOT
fi

chown -R www-data:www-data /etc/nginx/conf.d/site.conf
chown -R www-data:www-data ${SITE_DIR}

# ========================
# Systemd Service Restarts
# ========================

systemctl disable backend.service
systemctl disable user_stats.service
systemctl daemon-reload
systemctl restart nginx.service
systemctl enable nginx.service
systemctl restart backend.service
systemctl enable backend.service
systemctl restart user_stats.service
systemctl enable user_stats.service

# ========================
# Health Checks
# ========================

NGINX_STATE=$(systemctl is-active nginx)
[ "$NGINX_STATE" = "active" ] && echo -e "\e[0;32mNginx is running.\e[0m" || { echo -e "\e[0;31mNginx failed.\e[0m"; exit 1; }

BACKEND_STATE=$(systemctl is-active backend.service)
[ "$BACKEND_STATE" = "active" ] && echo -e "\e[0;32mbackend.service is running.\e[0m" || { echo -e "\e[0;31mbackend.service failed.\e[0m"; exit 1; }

USER_STATS_STATE=$(systemctl is-active user_stats.service)
[ "$USER_STATS_STATE" = "active" ] && echo -e "\e[0;32muser_stats.service is running.\e[0m" || { echo -e "\e[0;31muser_stats.service failed.\e[0m"; exit 1; }