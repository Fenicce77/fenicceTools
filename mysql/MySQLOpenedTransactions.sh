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
MYEXTRACONF="${HOME}/my.options.cnf"
ENV=$1
# Server name/ip to connect
#DBSERVERNAME=$2
#read DBSERVERNAME;
#if [[ -z ${DBSERVERNAME} ]] 
#then 
#	echo -e "MySQL DB Server cannot be empty\n Starting again...\n\n"
#	continue
#fi

InnoDBOpenTransQry="SELECT ps.id 'PROCESS ID', ps.user 'USERNAME' ,esh.event_name 'EVENT NAME',TIME_TO_SEC(timediff(now(),trx.trx_started)) AS RUNNING_FROM, esh.sql_text 'SQL' 
FROM information_schema.innodb_trx trx 
JOIN information_schema.processlist ps ON trx.trx_mysql_thread_id = ps.id
JOIN performance_schema.threads th ON th.processlist_id = trx.trx_mysql_thread_id
JOIN performance_schema.events_statements_history esh ON esh.thread_id = th.thread_id
WHERE trx.trx_started < CURRENT_TIME - INTERVAL 10 SECOND
  AND ps.USER != 'SYSTEM_USER'
ORDER BY esh.EVENT_ID"
#InnoDBOpenTransQry="select p.id,p.USER,SUBSTRING_INDEX(p.HOST,':',1) AS HOST,p.DB,t.trx_state,TIME_TO_SEC(timediff(now(),t.trx_started)) AS RUNNING_FROM t.trx_query from INNODB_TRX t join processlist p on p.ID=t.trx_mysql_thread_id having RUNNING_FROM > 0;"
#echo -e "\nEnter the ${cyn}MySQL DB Server Name (or IP)${off} for checking Master and Slave Status followed by [ENTER]:"
#echo "${cyn}Checking Open Transactions in Current Server ${DBSERVERNAME} (or IP)${off}"
echo "${cyn}Checking Open Transactions in Current Server `hostname` (or IP)${off}"
while true
do 
	#echo "${cyn}### ${DBSERVERNAME} MySQL Server InnoDB Current Open Transactions at [`date +"%Y-%m-%d %H:%M:%S"]` :${off}";
	echo "${cyn}### `hostname` MySQL Server InnoDB Current Open Transactions at [`date +"%Y-%m-%d %H:%M:%S"]` :${off}";
	echo "${cyn}-----------------------------------------------------${off}"
	echo ${InnoDBOpenTransQry} | ${MYSQLBIN} --login-path=${ENV} --defaults-extra-file=${MYEXTRACONF} -t -A ${db}
	#echo ${InnoDBOpenTransQry} | ${MYSQLBIN} --defaults-extra-file=${MYCONF} -t -A ${db}
	#echo ${InnoDBOpenTransQry} | mysql --login-path=${ENV} --defaults-extra-file=${MYCONF} -h ${DBSERVERNAME} -t -A ${db}
	echo ""
	echo "${yel}Sleeping 3 seconds...${off}"
	sleep 5;
done
