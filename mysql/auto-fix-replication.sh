#!/bin/bash

# 配置
MASTER="mysql-master"
SLAVES=("mysql-slave1" "mysql-slave2")
MYSQL_USER="root"
MYSQL_PASS="rootpass"
REPL_USER="replica"
REPL_PASS="replica_pass"
LOG_FILE_PATH="./replica_repair.log"

# 初始化日志文件
echo "=== 🛠 主从同步修复日志 $(date '+%F %T') ===" >> "$LOG_FILE_PATH"

echo "🔍 获取主库 binlog 信息..."
read -r LOG_FILE LOG_POS <<<$(docker exec -i $MASTER mysql -u$MYSQL_USER -p$MYSQL_PASS -e "SHOW MASTER STATUS\G" \
  | awk '/File:/ {file=$2} /Position:/ {pos=$2} END {print file, pos}')

echo "📂 binlog 文件: $LOG_FILE" | tee -a "$LOG_FILE_PATH"
echo "📍 binlog 位置: $LOG_POS" | tee -a "$LOG_FILE_PATH"

for SLAVE in "${SLAVES[@]}"; do
  echo ""
  echo "🔧 检查 $SLAVE 状态..." | tee -a "$LOG_FILE_PATH"

  STATUS=$(docker exec -i $SLAVE mysql -u$MYSQL_USER -p$MYSQL_PASS -e "SHOW REPLICA STATUS\G")
  echo "$STATUS" >> "$LOG_FILE_PATH"

  IO_RUNNING=$(echo "$STATUS" | awk '/Slave_IO_Running:/ {print $2}')
  SQL_RUNNING=$(echo "$STATUS" | awk '/Slave_SQL_Running:/ {print $2}')

  if [[ "$IO_RUNNING" != "Yes" || "$SQL_RUNNING" != "Yes" ]]; then
    echo "❌ 检测到复制未运行或未配置，正在修复..." | tee -a "$LOG_FILE_PATH"

    docker exec -i $SLAVE mysql -u$MYSQL_USER -p$MYSQL_PASS <<EOF >> "$LOG_FILE_PATH" 2>&1
STOP REPLICA;
RESET REPLICA;
CHANGE MASTER TO
  MASTER_HOST='$MASTER',
  MASTER_USER='$REPL_USER',
  MASTER_PASSWORD='$REPL_PASS',
  MASTER_LOG_FILE='$LOG_FILE',
  MASTER_LOG_POS=$LOG_POS,
  GET_MASTER_PUBLIC_KEY = 1;
START REPLICA;
SHOW REPLICA STATUS\G
EOF

    echo "✅ 修复完成，正在验证..." | tee -a "$LOG_FILE_PATH"

    docker exec -i $SLAVE mysql -u$MYSQL_USER -p$MYSQL_PASS -e "SHOW REPLICA STATUS\G" \
      | tee -a "$LOG_FILE_PATH" \
      | grep -E "Slave_IO_Running|Slave_SQL_Running|Last_IO_Error|Last_SQL_Error"
  else
    echo "✅ $SLAVE 的主从复制正常运行" | tee -a "$LOG_FILE_PATH"
  fi
done

echo ""
echo "🎉 所有从库已检查并处理完成。" | tee -a "$LOG_FILE_PATH"
