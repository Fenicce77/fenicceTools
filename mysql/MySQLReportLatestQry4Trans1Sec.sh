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
BASEDIR="${HOME}/git/myrepos/myToolsBetika/mysql"
SQLFILES="${BASEDIR}/sql"
#MYCONF="/Users/rmateos/my.conn.cnf"
db="information_schema"
# Connection configuration file
MYEXTRACONF="${HOME}/my.options.cnf"
ENV=$1
# Server name/ip to connect
#DBSERVERNAME=$2
ReportLastTransQrySQL="${SQLFILES}/ReportLastTransQry.sql"
#read DBSERVERNAME;
#if [[ -z ${DBSERVERNAME} ]] 
#then 
#	echo -e "MySQL DB Server cannot be empty\n Starting again...\n\n"
#	continue
#fi
#ReportLastTransQry='SELECT ROUND(trx.timer_wait/1000000000000,3) as trx_runtime, trx.thread_id AS thread_id, trx.event_id AS trx_event_id, trx.isolation_level, trx.autocommit,	stm.current_schema AS db,stm.sql_text AS query, stm.rows_affected AS rows_examined,stm.rows_affected AS rows_affected,	stm.rows_sent AS rows_sent,IF(stm.end_event_id IS NULL, "running", "done") AS exec_state,ROUND(stm.timer_wait/1000000000000,3) as exec_time FROM performance_schema.events_transactions_current trx JOIN performance_schema.events_statements_current stm USING (thread_id) WHERE trx.state = "ACTIVE" AND trx.timer_wait > 1000000000000 * 1 \G'

#echo "Qry:${ReportLastTransQry}"
#exit 0
#echo "${cyn}Checking Latest Query for Transactions longer than 1 second ${DBSERVERNAME} (or IP)${off}"
echo "${cyn}Checking Latest Query for Transactions longer than 1 second `hostname` (or IP)${off}"
while true
do 
	echo "${cyn}### `hostname` MySQL Server Latest Query For Transactions Active Longer Than 1 Second Repor at [`date +"%Y-%m-%d %H:%M:%S"]` :${off}";
	echo "${cyn}-----------------------------------------------------${off}"
	mysql --login-path=${ENV} --defaults-extra-file=${MYEXTRACONF} -t -A ${db} < ${ReportLastTransQrySQL}
	#mysql --defaults-file=${MYCONF} -t -A ${db} < ${ReportLastTransQrySQL}
	#${MYSQLBIN} --login-path=prod -t -A ${db} < ${ReportLastTransQrySQL}
	#echo ${InnoDBOpenTransQry} | mysql -A ${db}
	echo ""
	echo "${yel}Sleeping 3 seconds...${off}"
	sleep 5;
done
