#!/bin/bash

set -e

echo "📦 Starting full Guacamole installation with MySQL and Tomcat9..."

# ----------------------------
# Configuration
# ----------------------------
GUAC_VERSION="1.5.3"
GUAC_USER="(yourname)"
GUAC_PASS="(yourpass)"
GUAC_DB_NAME="guacamole_db"
TOMCAT_DIR="/opt/tomcat9"

# ----------------------------
# Install required packages
# ----------------------------
echo "🔧 Installing dependencies..."
apt update
apt install -y build-essential libcairo2-dev libjpeg-turbo8-dev libpng-dev \
  libtool-bin libossp-uuid-dev libavcodec-dev libavformat-dev libavutil-dev \
  freerdp2-dev libpango1.0-dev libssh2-1-dev libtelnet-dev libvncserver-dev \
  libpulse-dev libssl-dev libvorbis-dev libwebp-dev gcc mysql-server mysql-client \
  wget curl unzip libjpeg-dev libpng-dev libtool autoconf automake \
  maven default-jdk tomcat-native

# ----------------------------
# Install Tomcat 9
# ----------------------------
echo "📦 Downloading Tomcat 9..."
cd /opt
wget https://dlcdn.apache.org/tomcat/tomcat-9/v9.0.102/bin/apache-tomcat-9.0.102.tar.gz
tar xzf apache-tomcat-9.0.102.tar.gz
mv apache-tomcat-9.0.102 $TOMCAT_DIR
chmod +x $TOMCAT_DIR/bin/*.sh

# ----------------------------
# Build Guacamole Server
# ----------------------------
echo "⚙️ Building Guacamole server..."
cd /opt
wget https://apache.org/dyn/closer.cgi?action=download&filename=guacamole/${GUAC_VERSION}/source/guacamole-server-${GUAC_VERSION}.tar.gz -O guacamole-server-${GUAC_VERSION}.tar.gz
tar -xzf guacamole-server-${GUAC_VERSION}.tar.gz
cd guacamole-server-${GUAC_VERSION}
./configure --with-init-dir=/etc/init.d
make
make install
ldconfig

# ----------------------------
# Deploy Guacamole Web App & Extensions
# ----------------------------
echo "🌍 Installing Guacamole web interface and extensions..."
mkdir -p /etc/guacamole/extensions /etc/guacamole/lib

cd /opt
wget https://apache.org/dyn/closer.cgi?action=download&filename=guacamole/${GUAC_VERSION}/binary/guacamole-${GUAC_VERSION}.war -O guacamole.war
cp guacamole.war $TOMCAT_DIR/webapps/guacamole.war

cd /etc/guacamole/extensions
wget https://downloads.apache.org/guacamole/${GUAC_VERSION}/binary/guacamole-auth-jdbc-${GUAC_VERSION}.tar.gz
tar -xzf guacamole-auth-jdbc-${GUAC_VERSION}.tar.gz
cp guacamole-auth-jdbc-${GUAC_VERSION}/mysql/guacamole-auth-jdbc-mysql-${GUAC_VERSION}.jar .

cd /etc/guacamole/lib
wget https://repo1.maven.org/maven2/mysql/mysql-connector-java/8.0.30/mysql-connector-java-8.0.30.jar

# ----------------------------
# Create guacamole.properties
# ----------------------------
echo "⚙️ Writing guacamole.properties..."
cat <<EOF > /etc/guacamole/guacamole.properties
mysql-hostname: localhost
mysql-port: 3306
mysql-database: ${GUAC_DB_NAME}
mysql-username: guacuser
mysql-password: guacdbpass
EOF

# ----------------------------
# Link GUACAMOLE_HOME
# ----------------------------
ln -sf /etc/guacamole $TOMCAT_DIR/.guacamole

# ----------------------------
# Create setenv.sh for Tomcat
# ----------------------------
cat <<EOF > $TOMCAT_DIR/bin/setenv.sh
export GUACAMOLE_HOME=/etc/guacamole
export CLASSPATH=/etc/guacamole:/etc/guacamole/extensions/*:/etc/guacamole/lib/*
EOF
chmod +x $TOMCAT_DIR/bin/setenv.sh

# ----------------------------
# Create MySQL database
# ----------------------------
echo "🗃️ Creating MySQL database and user..."
mysql -u root <<EOF
CREATE DATABASE IF NOT EXISTS ${GUAC_DB_NAME};
CREATE USER IF NOT EXISTS 'guacuser'@'localhost' IDENTIFIED BY 'guacdbpass';
GRANT SELECT,INSERT,UPDATE,DELETE ON ${GUAC_DB_NAME}.* TO 'guacuser'@'localhost';
FLUSH PRIVILEGES;
EOF

cat /etc/guacamole/extensions/guacamole-auth-jdbc-${GUAC_VERSION}/mysql/schema/*.sql | mysql -u root ${GUAC_DB_NAME}

# ----------------------------
# Ensure correct hash column type
# ----------------------------
echo "🔧 Ensuring correct password_hash column type..."
mysql -u root ${GUAC_DB_NAME} -e "ALTER TABLE guacamole_user MODIFY password_hash BINARY(32) NOT NULL;"

# ----------------------------
# Create initial admin user
# ----------------------------
echo "👤 Creating initial admin user..."
GUAC_HASH=$(echo -n "$GUAC_PASS" | openssl dgst -sha256 -binary | xxd -p -c 256)

mysql -u root ${GUAC_DB_NAME} <<EOF
DELETE FROM guacamole_user_permission WHERE entity_id IN (SELECT entity_id FROM guacamole_entity WHERE name = '${GUAC_USER}');
DELETE FROM guacamole_user WHERE entity_id IN (SELECT entity_id FROM guacamole_entity WHERE name = '${GUAC_USER}');
DELETE FROM guacamole_entity WHERE name = '${GUAC_USER}';

INSERT INTO guacamole_entity (name, type) VALUES ('${GUAC_USER}', 'USER');
SET @entity_id = LAST_INSERT_ID();
INSERT INTO guacamole_user (entity_id, password_hash, password_salt, password_date)
VALUES (@entity_id, UNHEX('${GUAC_HASH}'), NULL, NOW());
SET @user_id = LAST_INSERT_ID();
INSERT INTO guacamole_user_permission (entity_id, affected_user_id, permission)
VALUES (@entity_id, @user_id, 'ADMINISTER');
EOF

# ----------------------------
# Start Tomcat
# ----------------------------
echo "🚀 Starting Tomcat..."
$TOMCAT_DIR/bin/shutdown.sh || true
sleep 3
$TOMCAT_DIR/bin/startup.sh

echo ""
echo "✅ Guacamole installation complete!"
echo "🌐 Access: http://<YOUR_SERVER_IP>:8080/guacamole/"
echo "👤 User:    $GUAC_USER"
echo "🔑 Pass:    $GUAC_PASS"
