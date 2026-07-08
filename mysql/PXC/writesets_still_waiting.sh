#!/usr/local/bin/bash
# #########################################################################################
# GENERAL CONSTANTS AND VARIABLES
#
# CONSTANTS
# Color Vars
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

# DB Connection parameters file
#MYCONF="rmateos.my.cnf"
# MySQL Binary Path
MYSQLBIN=`which mysql`
# Wait time
WAITTIME=5

ENV=$1
#MYCONF=$2
MYCONF="${HOME}/mysql/.my.cnf"
DBSERVERNAME=$2

# #########################################################################################

echo " ${yel}===================================================================================${off} "
echo " ${yel}-----------------------------------------------------------------------------------${off} "
echo " ${yel}==  Checking Flow Control and writesets waiting to be applied in ${off}${mag}${DBSERVERNAME}${off} "
#echo -e "\nEnter the ${cyn}MySQL Galera Cluster Server Node Name (or IP)${off} for [ENTER]:"
#read DBSERVERNAME;
#if [[ -z ${DBSERVERNAME} ]] 
#then 
#	echo -e "${red}Checking all servers known!!${off}\n\n"
#fi


# Main Program
# Infinite Loop for checking and show by standar formated output some current wsep status values and Flow Control of the node each 5 seconds
while true; do
	# Current Cluster Size
	#CLUSSIZE=`echo "SHOW STATUS LIKE 'wsrep_cluster_size';" | $MYSQLBIN  -N| awk '{print $2}'`
	#CLUSSIZE=`echo "SHOW STATUS LIKE 'wsrep_cluster_size';" | $MYSQLBIN --defaults-file=${MYCONF} -h ${DBSERVERNAME} -N | awk '{print $2}'`
	CLUSSIZE=`echo "SHOW STATUS LIKE 'wsrep_cluster_size';" | $MYSQLBIN --login-path=${ENV}  --defaults-file=${MYCONF} -h ${DBSERVERNAME} -N | awk '{print $2}'`
	# Current Node Status In Cluster : Joined, Synced
	#NODESTAT=`echo "SHOW STATUS LIKE 'wsrep_local_state_comment';" | $MYSQLBIN -N | awk '{print $2}'`
	#NODESTAT=`echo "SHOW STATUS LIKE 'wsrep_local_state_comment';" | $MYSQLBIN --defaults-file=${MYCONF} -h ${DBSERVERNAME} -N | awk '{print $2}'`
	NODESTAT=`echo "SHOW STATUS LIKE 'wsrep_local_state_comment';" | $MYSQLBIN --login-path=${ENV}  --defaults-file=${MYCONF} -h ${DBSERVERNAME} -N | awk '{print $2}'`
	# Cluster is ready for accepting queries : ON / OFF
	#NODEREAD=`echo "SHOW STATUS LIKE 'wsrep_ready';" | $MYSQLBIN -N| awk '{print $2}'`
	#NODEREAD=`echo "SHOW STATUS LIKE 'wsrep_ready';" | $MYSQLBIN  --defaults-file=${MYCONF} -h ${DBSERVERNAME} -N | awk '{print $2}'`
	NODEREAD=`echo "SHOW STATUS LIKE 'wsrep_ready';" | $MYSQLBIN --login-path=${ENV} --defaults-file=${MYCONF} -h ${DBSERVERNAME} -N | awk '{print $2}'`
	# Flow Control Status
	# Current (instantaneous) length of the recv queue
	#WRECQU=`echo "SHOW STATUS LIKE 'wsrep_local_recv_queue';" | $MYSQLBIN -N| awk '{print $2}'`
	#WRECQU=`echo "SHOW STATUS LIKE 'wsrep_local_recv_queue';" | $MYSQLBIN --defaults-file=${MYCONF} -h ${DBSERVERNAME} -N | awk '{print $2}'`
	WRECQU=`echo "SHOW STATUS LIKE 'wsrep_local_recv_queue';" | $MYSQLBIN --login-path=${ENV} --defaults-file=${MYCONF} -h ${DBSERVERNAME} -N | awk '{print $2}'`
	# Number of FC_PAUSE events the node has sent
	#FCSENT=`echo "SHOW STATUS LIKE 'wsrep_flow_control_sent';" | $MYSQLBIN -N| awk '{print $2}'`
	#FCSENT=`echo "SHOW STATUS LIKE 'wsrep_flow_control_sent';" | $MYSQLBIN --defaults-file=${MYCONF} -h ${DBSERVERNAME} -N | awk '{print $2}'`
	FCSENT=`echo "SHOW STATUS LIKE 'wsrep_flow_control_sent';" | $MYSQLBIN --login-path=${ENV} --defaults-file=${MYCONF} -h ${DBSERVERNAME} -N | awk '{print $2}'`
	# Number of FC_PAUSE events the node has received, including those the node has sent
	#FCREC=`echo "SHOW STATUS LIKE 'wsrep_flow_control_recv';" | $MYSQLBIN -N| awk '{print $2}'`
	#FCREC=`echo "SHOW STATUS LIKE 'wsrep_flow_control_recv';" | $MYSQLBIN --defaults-file=${MYCONF} -h ${DBSERVERNAME} -N | awk '{print $2}'`
	FCREC=`echo "SHOW STATUS LIKE 'wsrep_flow_control_recv';" | $MYSQLBIN --login-path=${ENV} --defaults-file=${MYCONF} -h ${DBSERVERNAME} -N | awk '{print $2}'`
	# Fraction of time since the last FLUSH STATUS command that replication was paused due to flow control.
	# How much the slave lag is slowing down the cluster
	#FCPAU=`echo "SHOW STATUS LIKE 'wsrep_flow_control_paused';" | $MYSQLBIN -N | awk '{print $2}'`
	#FCPAU=`echo "SHOW STATUS LIKE 'wsrep_flow_control_paused';" | $MYSQLBIN --defaults-file=${MYCONF} -h ${DBSERVERNAME} -N | awk '{print $2}'`
	FCPAU=`echo "SHOW STATUS LIKE 'wsrep_flow_control_paused';" | $MYSQLBIN --login-path=${ENV} --defaults-extra-file=${MYCONF} -h ${DBSERVERNAME} -N | awk '{print $2}'`
	# Fraction of time since the last FLUSH STATUS command that replication was paused due to flow control.
	# Node writes received
	#FCPAU=`echo "SHOW STATUS LIKE 'wsrep_received_bytes';" | $MYSQLBIN -N | awk '{print $2}'`
	#WRECVBYTES=`echo "SHOW STATUS LIKE 'wsrep_received_bytes';" | $MYSQLBIN --defaults-file=${MYCONF} -h ${DBSERVERNAME} -N | awk '{print $2}'`
	WRECVBYTES=`echo "SHOW STATUS LIKE 'wsrep_received_bytes';" | $MYSQLBIN --login-path=${ENV} --defaults-file=${MYCONF} -h ${DBSERVERNAME} -N | awk '{print $2}'`
	WRECEIVED=`echo "SHOW STATUS LIKE 'wsrep_received';" | $MYSQLBIN --login-path=${ENV} --defaults-file=${MYCONF} -h ${DBSERVERNAME} -N | awk '{print $2}'`
	# Flow control status Enabled or NOT
	FCSTATUSENABLED=`echo "SHOW STATUS LIKE 'wsrep_flow_control_status';" | $MYSQLBIN --login-path=${ENV} --defaults-file=${MYCONF} -h ${DBSERVERNAME} -N | awk '{print $2}'`
	STATUS=""
	echo -e "${mag}[`date +"%Y-%m-%d %H:%M:%S"`]${off} ${yel}Cluser Size     : ${red}$CLUSSIZE${off}"
	echo -e "${mag}[`date +"%Y-%m-%d %H:%M:%S"`]${off} ${yel}Node Status     : ${red}$NODESTAT${off}"
	echo -e "${mag}[`date +"%Y-%m-%d %H:%M:%S"`]${off} ${yel}Node In Cluster : ${red}$NODEREAD${off}"
	echo -e "${mag}[`date +"%Y-%m-%d %H:%M:%S"`]${off} ${yel}Number of writesets waiting to be applied : ${red}$WRECQU${off}"
	echo -e "${mag}[`date +"%Y-%m-%d %H:%M:%S"`]${off} ${yel}Writeset Received : Total / Bytes : ${red}$WRECEIVED${off} / ${red}$WRECVBYTES${off}"
	echo -e "${mag}[`date +"%Y-%m-%d %H:%M:%S"`]${off} ${yel}Flow Control Enabled : ${red}$FCSTATUSENABLED${off}"
	echo -e "${mag}[`date +"%Y-%m-%d %H:%M:%S"`]${off} ${yel} > FC pause events sent by Node : ${red}$FCSENT${off}"
	echo -e "${mag}[`date +"%Y-%m-%d %H:%M:%S"`]${off} ${yel} > FC pause events on the Cluster : ${red}$FCREC${off}"
	echo -e "${mag}[`date +"%Y-%m-%d %H:%M:%S"`]${off} ${yel}Amount of Time (in secs) Replication Paused : ${red}$FCPAU seconds${off}"

	echo "${cyn}Slepping ${WAITTIME}s...${off}"
	echo " ${yel}-----------------------------------------------------------------------------------${off} "
	sleep ${WAITTIME}
done