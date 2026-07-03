#!/opt/homebrew/bin/bash
#
blk=$(tput blink)
bld=$(tput bold)           	 # Bold
red=${bld}$(tput setaf 1)    # Red
grn=${bld}$(tput setaf 2)    # Green
yel=${bld}$(tput setaf 3)    # Yellow
blu=${bld}$(tput setaf 4)    # Blue
mag=${bld}$(tput setaf 5)    # Purple
cyn=${bld}$(tput setaf 6)    # Cyan
wht=${bld}$(tput setaf 7)    # White
off=$(tput sgr0)             # Text reset

# MySQL Binary Path
MYSQLBIN=`which mysql`

#MYCONF="/Users/rmateos/my.conn.cnf"
db="information_schema"
# Connection configuration file
#MYCONF="${HOME}/mysql/.my.cnf"
#MYCONF=$1
ENV=$1
MYEXTRACNF="${HOME}/my.options.cnf"
# Server name/ip to connect
DBSERVERNAME=$2
#read DBSERVERNAME;
#if [[ -z ${DBSERVERNAME} ]] 
#then 
#	echo -e "MySQL DB Server cannot be empty\n Starting again...\n\n"
#	continue
#fi
InnoDBLocksQry="SELECT r.trx_wait_started AS wait_started, TIMEDIFF(NOW(), r.trx_wait_started) AS wait_age,
       TIMESTAMPDIFF(SECOND, r.trx_wait_started, NOW()) AS wait_age_secs,rl.lock_table AS locked_table,
       rl.lock_index AS locked_index,rl.lock_type AS locked_type,r.trx_id AS waiting_trx_id,r.trx_started as waiting_trx_started,
       TIMEDIFF(NOW(), r.trx_started) AS waiting_trx_age, r.trx_rows_locked AS waiting_trx_rows_locked,r.trx_rows_modified AS waiting_trx_rows_modified,
       r.trx_mysql_thread_id AS waiting_pid,r.trx_query AS waiting_query,rl.lock_id AS waiting_lock_id,rl.lock_mode AS waiting_lock_mode,
       b.trx_id AS blocking_trx_id,b.trx_mysql_thread_id AS blocking_pid,b.trx_query AS blocking_query, bl.lock_id AS blocking_lock_id,
       bl.lock_mode AS blocking_lock_mode, b.trx_started AS blocking_trx_started, TIMEDIFF(NOW(), b.trx_started) AS blocking_trx_age,b.trx_rows_locked AS blocking_trx_rows_locked,
       b.trx_rows_modified AS blocking_trx_rows_modified,CONCAT('KILL QUERY ', b.trx_mysql_thread_id) AS sql_kill_blocking_query,
       CONCAT('KILL ', b.trx_mysql_thread_id) AS sql_kill_blocking_connection
  FROM sys.innodb_lock_waits w 
  		INNER JOIN information_schema.innodb_trx b ON b.trx_id = w.blocking_trx_id
  		INNER JOIN information_schema.innodb_trx r    ON r.trx_id = w.requesting_trx_id
  		INNER JOIN information_schema.innodb_locks bl ON bl.lock_id = w.blocking_lock_id 
  		INNER JOIN information_schema.innodb_locks rl ON rl.lock_id = w.requested_lock_id
 ORDER BY r.trx_wait_started\G"
 # InnoDBLocksQry="SELECT r.trx_wait_started AS wait_started, TIMEDIFF(NOW(), r.trx_wait_started) AS wait_age,
 #       TIMESTAMPDIFF(SECOND, r.trx_wait_started, NOW()) AS wait_age_secs,rl.lock_table AS locked_table,
 #       rl.lock_index AS locked_index,rl.lock_type AS locked_type,r.trx_id AS waiting_trx_id,r.trx_started as waiting_trx_started,
 #       TIMEDIFF(NOW(), r.trx_started) AS waiting_trx_age, r.trx_rows_locked AS waiting_trx_rows_locked,r.trx_rows_modified AS waiting_trx_rows_modified,
 #       r.trx_mysql_thread_id AS waiting_pid,r.trx_query AS waiting_query,rl.lock_id AS waiting_lock_id,rl.lock_mode AS waiting_lock_mode,
 #       b.trx_id AS blocking_trx_id,b.trx_mysql_thread_id AS blocking_pid,b.trx_query AS blocking_query, bl.lock_id AS blocking_lock_id,
 #       bl.lock_mode AS blocking_lock_mode, b.trx_started AS blocking_trx_started, TIMEDIFF(NOW(), b.trx_started) AS blocking_trx_age,b.trx_rows_locked AS blocking_trx_rows_locked,
 #       b.trx_rows_modified AS blocking_trx_rows_modified,CONCAT('KILL QUERY ', b.trx_mysql_thread_id) AS sql_kill_blocking_query,
 #       CONCAT('KILL ', b.trx_mysql_thread_id) AS sql_kill_blocking_connection
 #  FROM information_schema.innodb_lock_waits w 
 #              INNER JOIN information_schema.innodb_trx b ON b.trx_id = w.blocking_trx_id
 #              INNER JOIN information_schema.innodb_trx r    ON r.trx_id = w.requesting_trx_id
 #              INNER JOIN information_schema.innodb_locks bl ON bl.lock_id = w.blocking_lock_id 
 #              INNER JOIN information_schema.innodb_locks rl ON rl.lock_id = w.requested_lock_id
 # ORDER BY r.trx_wait_started\G"
#InnoDBOpenTransQry="select p.id,p.USER,SUBSTRING_INDEX(p.HOST,':',1) AS HOST,p.DB,t.trx_state,TIME_TO_SEC(timediff(now(),t.trx_started)) AS RUNNING_FROM t.trx_query from INNODB_TRX t join processlist p on p.ID=t.trx_mysql_thread_id having RUNNING_FROM > 0;"
#echo -e "\nEnter the ${cyn}MySQL DB Server Name (or IP)${off} for checking Master and Slave Status followed by [ENTER]:"
echo "${cyn}Checking Current Locks in Current Server ${DBSERVERNAME} (or IP)${off}"

while true
do 
	echo "${cyn}### ${DBSERVERNAME} MySQL Server InnoDB Locked Transactions at [`date +"%Y-%m-%d %H:%M:%S"]` :${off}";
	echo "${cyn}-----------------------------------------------------${off}"
	#echo ${InnoDBLocksQry} | mysql --login-path=${ENV} --defaults-extra-file=${MYCONF} -h ${DBSERVERNAME} -t -A ${db}
       echo ${InnoDBLocksQry} | $MYSQLBIN --login-path=${ENV} --defaults-extra-file=${MYEXTRACONF} -t -A ${db}
       #echo ${InnoDBLocksQry} | $MYSQLBIN --defaults-file=${MYCONF} -t -A ${db}
	#echo ${InnoDBOpenTransQry} | mysql -A ${db}
	echo ""
	echo "${yel}Sleeping 3 seconds...${off}"
	sleep 5;
done
