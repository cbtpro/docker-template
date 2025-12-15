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
echo "=== 🛠 MySQL 主从同步修复日志 $(date '+%F %T') ===" > "$LOG_FILE_PATH" # 使用 > 清空文件

# --- 函数：获取主库 Binlog 信息 ---
echo "🔍 获取主库 binlog 信息..."
MASTER_STATUS=$(docker exec -i "$MASTER" mysql -u"$MYSQL_USER" -p"$MYSQL_PASS" -e "SHOW MASTER STATUS\G")

# 检查命令是否成功
if [ $? -ne 0 ]; then
  echo "❌ 无法连接到主库 ($MASTER) 或获取状态。请检查凭证/容器状态。" | tee -a "$LOG_FILE_PATH"
  exit 1
fi

LOG_FILE=$(echo "$MASTER_STATUS" | awk '/File:/ {print $2}')
LOG_POS=$(echo "$MASTER_STATUS" | awk '/Position:/ {print $2}')

echo "📂 binlog 文件: $LOG_FILE" | tee -a "$LOG_FILE_PATH"
echo "📍 binlog 位置: $LOG_POS" | tee -a "$LOG_FILE_PATH"

# --- 循环检查并修复从库 ---
for SLAVE in "${SLAVES[@]}"; do
  echo "" | tee -a "$LOG_FILE_PATH"
  echo "--- 🔧 正在处理 $SLAVE ---" | tee -a "$LOG_FILE_PATH"
  
  # 1. 获取从库状态
  SLAVE_STATUS=$(docker exec -i "$SLAVE" mysql -u"$MYSQL_USER" -p"$MYSQL_PASS" -e "SHOW REPLICA STATUS\G")
  
  # 检查命令是否成功
  if [ $? -ne 0 ]; then
    echo "❌ 无法连接到从库 ($SLAVE) 或获取状态。跳过此从库。" | tee -a "$LOG_FILE_PATH"
    continue
  fi
  
  IO_RUNNING=$(echo "$SLAVE_STATUS" | awk '/Replica_IO_Running:/ {print $2}')
  SQL_RUNNING=$(echo "$SLAVE_STATUS" | awk '/Replica_SQL_Running:/ {print $2}')

  # 2. 判断是否需要修复
  if [[ "$IO_RUNNING" != "Yes" || "$SQL_RUNNING" != "Yes" ]]; then
    echo "❌ 检测到复制未运行 (IO:$IO_RUNNING, SQL:$SQL_RUNNING)，正在执行修复..." | tee -a "$LOG_FILE_PATH"
    
    # 修复核心逻辑：停止，彻底清除，设置新的起始点，然后启动
    docker exec -i "$SLAVE" mysql -u"$MYSQL_USER" -p"$MYSQL_PASS" <<EOF >> "$LOG_FILE_PATH" 2>&1
STOP REPLICA;
RESET REPLICA ALL;
CHANGE MASTER TO
  MASTER_HOST='$MASTER',
  MASTER_USER='$REPL_USER',
  MASTER_PASSWORD='$REPL_PASS',
  MASTER_LOG_FILE='$LOG_FILE',
  MASTER_LOG_POS=$LOG_POS;
START REPLICA;
EOF
    
    # 验证修复结果
    echo "✅ 修复完成，正在验证 $SLAVE 状态..." | tee -a "$LOG_FILE_PATH"
    
    docker exec -i "$SLAVE" mysql -u"$MYSQL_USER" -p"$MYSQL_PASS" -e "SHOW REPLICA STATUS\G" \
      | tee -a "$LOG_FILE_PATH" \
      | grep -E "Source_Host|Source_User|Source_Port|Source_Log_File|Read_Source_Log_Pos|Replica_IO_Running|Replica_SQL_Running|Seconds_Behind_Source|Last_Error|Last_IO_Error|Last_SQL_Error"
  
  else
    # 状态正常时输出 Seconds_Behind_Source
    SECONDS_BEHIND=$(echo "$SLAVE_STATUS" | awk '/Seconds_Behind_Source:/ {print $2}')
    echo "✅ $SLAVE 的主从复制正常运行。延迟: $SECONDS_BEHIND 秒。" | tee -a "$LOG_FILE_PATH"
  fi
done

echo "" | tee -a "$LOG_FILE_PATH"
echo "🎉 所有从库已检查并处理完成。" | tee -a "$LOG_FILE_PATH"