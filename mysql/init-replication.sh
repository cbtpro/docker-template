#!/bin/bash

MASTER_CONTAINER="mysql-master"
SLAVE_CONTAINERS=("mysql-slave1" "mysql-slave2")
REPL_USER="replica"
REPL_PASSWORD="replica_pass"

echo "🔁 Creating replication user on master..."
docker exec -i $MASTER_CONTAINER mysql -uroot -prootpass <<EOF
CREATE USER IF NOT EXISTS '$REPL_USER'@'%' IDENTIFIED WITH mysql_native_password BY '$REPL_PASSWORD';
GRANT REPLICATION SLAVE ON *.* TO '$REPL_USER'@'%';
FLUSH PRIVILEGES;
FLUSH TABLES WITH READ LOCK;
SHOW MASTER STATUS;
EOF

# Get MASTER_LOG_FILE and MASTER_LOG_POS
read -r FILE POSITION <<<$(docker exec $MASTER_CONTAINER mysql -uroot -prootpass -e "SHOW MASTER STATUS\G" \
  | awk '/File:/ {file=$2} /Position:/ {pos=$2} END {print file, pos}')

echo "📋 Master log file: $FILE"
echo "📋 Master log position: $POSITION"

# Loop through slaves and configure them
for SLAVE in "${SLAVE_CONTAINERS[@]}"; do
  echo "🔧 Configuring replication on $SLAVE..."
  docker exec -i $SLAVE mysql -uroot -prootpass <<EOF
STOP REPLICA;
CHANGE MASTER TO
  MASTER_HOST='mysql-master',
  MASTER_USER='$REPL_USER',
  MASTER_PASSWORD='$REPL_PASSWORD',
  MASTER_LOG_FILE='$FILE',
  MASTER_LOG_POS=$POSITION;
RESET REPLICA;
START REPLICA;
SHOW REPLICA STATUS\G
EOF
done

echo "✅ Replication setup complete."
