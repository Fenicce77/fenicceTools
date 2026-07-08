#!/bin/bash
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
# #########################################################################################

echo " ${yel}===================================================================================${off} "
echo " ${yel}-----------------------------------------------------------------------------------${off} "
echo " ${yel}==  Gcache calc estimation                    ==${off} "
#echo -e "\nEnter the ${cyn}MySQL Galera Cluster Server Node Name (or IP)${off} for [ENTER]:"
#read DBSERVERNAME;
#if [[ -z ${DBSERVERNAME} ]] 
#then 
#	echo -e "${red}Checking all servers known!!${off}\n\n"
#fi
MYCONF=$1
DBSERVERNAME=$2
# Main Program

DATE1=`date +"%Y-%m-%d %H:%M:%S"`
WRECBYTES1=`echo "SHOW STATUS LIKE 'wsrep_received_bytes';" | $MYSQLBIN --defaults-file=${MYCONF} -h ${DBSERVERNAME} -N | awk '{print $2}'`
sleep 1
DATE2=`date +"%Y-%m-%d %H:%M:%S"`
WRECBYTES2=`echo "SHOW STATUS LIKE 'wsrep_received_bytes';" | $MYSQLBIN --defaults-file=${MYCONF} -h ${DBSERVERNAME} -N | awk '{print $2}'`
echo "${DATE1} : ${WRECBYTES1}"
echo "${DATE2} : ${WRECBYTES2}"
while [ ${WRECBYTES2} -eq ${WRECBYTES1} ]; do
	DATE1=`date +"%Y-%m-%d %H:%M:%S"`
	WRECBYTES1=`echo "SHOW STATUS LIKE 'wsrep_received_bytes';" | $MYSQLBIN --defaults-file=${MYCONF} -h ${DBSERVERNAME} -N | awk '{print $2}'`
	sleep 1
	DATE2=`date +"%Y-%m-%d %H:%M:%S"`
	WRECBYTES2=`echo "SHOW STATUS LIKE 'wsrep_received_bytes';" | $MYSQLBIN --defaults-file=${MYCONF} -h ${DBSERVERNAME} -N | awk '{print $2}'`
	
	echo -e "${mag}[`date +"%Y-%m-%d %H:%M:%S"`][INFO]${off} ${yel} wsrep_received_bytes Not Changed in last ${WAITTIME} seconds...Rechecking${off}"

	echo " ${yel}-----------------------------------------------------------------------------------${off} "
done

echo -e "${mag}[`date +"%Y-%m-%d %H:%M:%S"`][INFO]${off}${cyn}${DATE1} : ${WRECBYTES1}${off}"
echo -e "${mag}[`date +"%Y-%m-%d %H:%M:%S"`][INFO]${off}${cyn}${DATE2} : ${WRECBYTES2}${off}"

exit 0
