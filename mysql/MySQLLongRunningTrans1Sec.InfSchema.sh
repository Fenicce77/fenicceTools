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

MYSQLBIN=`which mysql`
#/Users/rmateos/git/mygit/myToolsMadCollective
BASEDIR="${HOME}/git/myrepos/myToolsBetika/mysql"
SQLFILES="${BASEDIR}/sql"
#MYCONF="/Users/rmateos/my.conn.cnf"
db="information_schema"
# Connection configuration file
MYEXTRACONF="${HOME}/my.options.cnf"
#MYCONF=$1
ENV=$1
# Server name/ip to connect
#DBSERVERNAME=$2
# Long Running Transactions Longer than 1" Query via information_schema
LongRunningTransQrySQL="${SQLFILES}/LongRunningTrans_InfSchema.sql"
# History List Length Query
HLLQRY="SELECT now() as currdatetime, name,count FROM information_schema.INNODB_METRICS WHERE name = 'trx_rseg_history_len';"
#read DBSERVERNAME;
#if [[ -z ${DBSERVERNAME} ]] 
#then 
#	echo -e "MySQL DB Server cannot be empty\n Starting again...\n\n"
#	continue
#fi
#ReportLastTransQry='SELECT ROUND(trx.timer_wait/1000000000000,3) as trx_runtime, trx.thread_id AS thread_id, trx.event_id AS trx_event_id, trx.isolation_level, trx.autocommit,	stm.current_schema AS db,stm.sql_text AS query, stm.rows_affected AS rows_examined,stm.rows_affected AS rows_affected,	stm.rows_sent AS rows_sent,IF(stm.end_event_id IS NULL, "running", "done") AS exec_state,ROUND(stm.timer_wait/1000000000000,3) as exec_time FROM performance_schema.events_transactions_current trx JOIN performance_schema.events_statements_current stm USING (thread_id) WHERE trx.state = "ACTIVE" AND trx.timer_wait > 1000000000000 * 1 \G'

#echo "Qry:${ReportLastTransQry}"
#exit 0
echo "${cyn}Checking Long Running Transactions via information_schema longer than 1 second ${DBSERVERNAME} (or IP)${off}"

while true
do 
	echo "${cyn}### ${DBSERVERNAME} MySQL Server Long Running Transactions via Information_schema Longer Than 1 Second Report & HLL at [`date +"%Y-%m-%d %H:%M:%S"]` :${off}";
	echo "${cyn}-----------------------------------------------------${off}"
	#${MYSQLBIN} --login-path=${ENV} --defaults-extra-file=${MYCONF} -h ${DBSERVERNAME} -t -A ${db} < ${LongRunningTransQrySQL}
	#${MYSQLBIN} --defaults-file=${MYCONF} -t -A ${db} < ${LongRunningTransQrySQL}
	echo ${HLLQRY} | ${MYSQLBIN} --login-path=${ENV} -t -A ${db}
	#echo "${cyn} * History List Length ${off}"
	#echo ${HLLQRY} | ${MYSQLBIN} --login-path=${ENV} --defaults-extra-file=${MYCONF} -h ${DBSERVERNAME} -t -A ${db}
	#echo ${HLLQRY} | ${MYSQLBIN} --defaults-file=${MYCONF} -t -A ${db}
	#echo ${InnoDBOpenTransQry} | mysql -A ${db}
	echo ""
	echo "${yel}Sleeping 3 seconds...${off}"
	sleep 5;
done
