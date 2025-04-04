#!/bin/bash
set -e

GUAC_VERSION="1.5.3"
TOMCAT_VERSION="9.0.102"
DOMAIN="remodesk.de"
GUAC_USER="xyz"
GUAC_PASS="xyz"

echo "🧰 Installing dependencies..."
apt update
apt install -y build-essential libcairo2-dev libjpeg-turbo8-dev libpng-dev \
 libtool-bin libossp-uuid-dev libavcodec-dev libavformat-dev libavutil-dev \
 libswscale-dev freerdp2-dev libpango1.0-dev libssh2-1-dev libtelnet-dev \
 libvncserver-dev libpulse-dev libssl-dev libvorbis-dev libwebp-dev \
 mysql-server nginx certbot python3-certbot-nginx openjdk-11-jdk unzip curl

echo "📦 Installing Tomcat $TOMCAT_VERSION..."
TOMCAT_DIR="/opt/tomcat9"
if [ ! -d "$TOMCAT_DIR" ]; then
  cd /opt
  curl -O https://dlcdn.apache.org/tomcat/tomcat-9/v${TOMCAT_VERSION}/bin/apache-tomcat-${TOMCAT_VERSION}.tar.gz
  tar -xzf apache-tomcat-${TOMCAT_VERSION}.tar.gz
  mv apache-tomcat-${TOMCAT_VERSION} tomcat9
  rm apache-tomcat-${TOMCAT_VERSION}.tar.gz
  chmod +x /opt/tomcat9/bin/*.sh
fi

echo "⛳ Creating systemd service for Tomcat..."
cat >/etc/systemd/system/tomcat9.service <<EOF
[Unit]
Description=Apache Tomcat 9
After=network.target

[Service]
Type=forking
Environment=JAVA_HOME=/usr/lib/jvm/java-11-openjdk-amd64
Environment=CATALINA_PID=/opt/tomcat9/temp/tomcat.pid
Environment=CATALINA_HOME=/opt/tomcat9
Environment=CATALINA_BASE=/opt/tomcat9
ExecStart=/opt/tomcat9/bin/startup.sh
ExecStop=/opt/tomcat9/bin/shutdown.sh
Restart=always
User=root

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reexec
systemctl daemon-reload
systemctl enable tomcat9

echo "⬇️ Installing Guacamole Server..."
cd /opt
curl -O https://dlcdn.apache.org/guacamole/${GUAC_VERSION}/source/guacamole-server-${GUAC_VERSION}.tar.gz
tar -xzf guacamole-server-${GUAC_VERSION}.tar.gz
cd guacamole-server-${GUAC_VERSION}
# Fix for guacenc
sed -i 's/container_format = container_format_context->oformat;/container_format = (AVOutputFormat *) container_format_context->oformat;/' src/guacenc/video.c
sed -i 's/AVCodec\* codec = avcodec_find_encoder_by_name(codec_name);/AVCodec* codec = (AVCodec *) avcodec_find_encoder_by_name(codec_name);/' src/guacenc/video.c
./configure --with-init-dir=/etc/init.d
make -j$(nproc)
make install
ldconfig

echo "⬇️ Installing Guacamole Webclient..."
curl -o /opt/tomcat9/webapps/guacamole.war https://dlcdn.apache.org/guacamole/${GUAC_VERSION}/binary/guacamole-${GUAC_VERSION}.war

echo "📁 Setting up configuration..."
mkdir -p /etc/guacamole/{extensions,lib}
ln -sf /etc/guacamole /opt/tomcat9/.guacamole

cat >/etc/guacamole/guacamole.properties <<EOF
mysql-hostname: localhost
mysql-port: 3306
mysql-database: guacamole_db
mysql-username: guacamole_user
mysql-password: guacpass
EOF

echo "🔐 Configuring MySQL..."
systemctl enable mysql
systemctl start mysql

mysql -u root <<EOF
CREATE DATABASE IF NOT EXISTS guacamole_db;
CREATE USER IF NOT EXISTS 'guacamole_user'@'localhost' IDENTIFIED BY 'guacpass';
GRANT SELECT,INSERT,UPDATE,DELETE ON guacamole_db.* TO 'guacamole_user'@'localhost';
FLUSH PRIVILEGES;
EOF

echo "🔐 Installing JDBC auth module..."
cd /opt
curl -O https://dlcdn.apache.org/guacamole/${GUAC_VERSION}/binary/guacamole-auth-jdbc-${GUAC_VERSION}.tar.gz
tar -xzf guacamole-auth-jdbc-${GUAC_VERSION}.tar.gz
cp guacamole-auth-jdbc-${GUAC_VERSION}/mysql/guacamole-auth-jdbc-mysql-${GUAC_VERSION}.jar /etc/guacamole/extensions/
cp /usr/share/java/mysql-connector-java-*.jar /etc/guacamole/lib/

mkdir -p /tmp/guac-schema
cp guacamole-auth-jdbc-${GUAC_VERSION}/mysql/schema/*.sql /tmp/guac-schema/

echo "📄 Importing DB schema..."
mysql -u root guacamole_db < /tmp/guac-schema/001-create-schema.sql
mysql -u root guacamole_db < /tmp/guac-schema/002-create-admin-user.sql
mysql -u root guacamole_db < /tmp/guac-schema/003-create-connections.sql

echo "👤 Creating admin user..."
PASS_HASH=$(printf "%s" "$GUAC_PASS" | openssl dgst -sha256 -binary | xxd -p -c 256)
mysql -u root guacamole_db <<EOF
DELETE FROM guacamole_user_permission WHERE entity_id = (SELECT entity_id FROM guacamole_entity WHERE name = '${GUAC_USER}');
DELETE FROM guacamole_user WHERE entity_id = (SELECT entity_id FROM guacamole_entity WHERE name = '${GUAC_USER}');
DELETE FROM guacamole_entity WHERE name = '${GUAC_USER}';

INSERT INTO guacamole_entity (name, type) VALUES ('${GUAC_USER}', 'USER');
SET @id := LAST_INSERT_ID();
INSERT INTO guacamole_user (entity_id, password_hash, password_date) VALUES (@id, UNHEX('${PASS_HASH}'), NOW());
INSERT INTO guacamole_user_permission (entity_id, affected_user_id, permission) VALUES (@id, @id, 'ADMINISTER');
EOF

echo "🛡️ Setting up NGINX + HTTPS..."
cat >/etc/nginx/sites-available/guacamole <<EOF
server {
    listen 80;
    server_name ${DOMAIN};

    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 443 ssl;
    server_name ${DOMAIN};

    ssl_certificate /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;

    location / {
        proxy_pass http://localhost:8080/guacamole/;
        proxy_buffering off;
        proxy_http_version 1.1;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$http_connection;
        proxy_cookie_path /guacamole/ /;
    }
}
EOF

ln -sf /etc/nginx/sites-available/guacamole /etc/nginx/sites-enabled/guacamole
rm -f /etc/nginx/sites-enabled/default
nginx -t
systemctl restart nginx

echo "🔐 Getting Let's Encrypt certificate..."
certbot --nginx -d ${DOMAIN} --non-interactive --agree-tos -m admin@${DOMAIN} || true
nginx -t && systemctl restart nginx

echo "🚀 Starting Tomcat..."
systemctl restart tomcat9

echo ""
echo "✅ Guacamole installation complete!"
echo "🌐 Access it at: https://${DOMAIN}/"
echo "👤 Username: ${GUAC_USER}"
echo "🔑 Password: ${GUAC_PASS}"
