#!/bin/bash
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
# MySQL Admin Binary Path
MYSQLADMINBIN=`which mysqladmin`
# Connection configuration file
MYCONF=$1
# Server name/ip to connect
#DBSERVERNAME=$2
DELAY=5
#echo -e "Enter the ${cyn}MySQL DB Server Name (or IP)${off} for checking Queries Per Second [ENTER]:"
#read DBSERVERNAME;
#if [[ -z ${DBSERVERNAME} ]]; then echo -e "MySQL DB Server cannot be empty\n Starting again..."; continue; fi
echo " ${yel}========================================================================== ${off}"
echo " ${yel}=  MySQL Server QPS in${off} ${red}`cat ${MYCONF} | grep host | awk -F'=' '{print $2}' | sort -u`${off}"
QRYCNT0=0
loops=0
while true
do 
	QRYCNT=`echo "show status like 'queries';" | ${MYSQLBIN} --defaults-extra-file=${MYCONF} -N | awk '{print $2}'`
	#QRYCNT=`$MYSQLADMINBIN --defaults-extra-file=${MYCNF} -h ${DBSERVERNAME} status | cut -f4 -d ":"  | awk '{print $1}'`
	#QRYCNT=`$MYSQLADMINBIN --defaults-extra-file=${MYCONF} status | cut -f4 -d ":"  | awk '{print $1}'`
	#QRYCNT=`$MYSQLADMINBIN status | cut -f4 -d ":"  | awk '{print $1}'`
	#QRYCNT=`echo ${QRYCNTAUX} | sed 's/\./\,/g'`
	QRYDIFF=`echo "scale=3; ${QRYCNT}-${QRYCNT0}" | bc -l`
	QPS=`echo "scale=3; ${QRYDIFF}/${DELAY}"|bc -l`
	
	QRYCNT0=`echo "scale=3; ${QRYCNT}" | bc`
	#QRYCNT0=${QRYCNT}
	sleep ${DELAY}s
	if [[ ${loops} -ne 0 ]]; then
		echo -e "${mag}[`date +"%Y-%m-%d %H:%M:%S"]${off}`${yel} Total Queries :${off}${cyn}${QRYCNT}${off} -> ${wht}DIF=${QRYDIFF}${off} <> ${grn}QPS${off}=${red}${QPS}${off}"
		#"${var%.*}"
		#if [[ "${QPS}" -gt "350" ]]; then
		if [[ "${QPS%.*}" -gt "350" ]]; then
		#statements
			for (( i = 0; i < 10; i++ )); do
				#statements
#				echo "SELECT ID, CONCAT(USER,'@',substring_index(substring_index(HOST,':',1),'.',4)) as fullusername,DB,COMMAND,QUERY_ID,SUBSTR(INFO,1,50) AS QRY_50,TIME,STATE,STAGE,MAX_STAGE,PROGRESS,MEMORY_USED,MAX_MEMORY_USED,EXAMINED_ROWS,SUBSTR(INFO_BINARY,1,50) AS QRY_BINARY_50,TID FROM INFORMATION_SCHEMA.processlist where user like 'jucy%';" | ${MYSQLBIN} --defaults-file=${MYCONF} -t
				echo "SELECT ID, CONCAT(USER,'@',substring_index(substring_index(HOST,':',1),'.',4)) as fullusername,DB,COMMAND,TIME,STATE,STAGE,MAX_STAGE,PROGRESS,MEMORY_USED,MAX_MEMORY_USED,EXAMINED_ROWS,INFO_BINARY,TID FROM INFORMATION_SCHEMA.processlist where user like 'jucy%'\G" | ${MYSQLBIN} --defaults-file=${MYCONF} -t
				#sleep 3s
			done
		fi
	else 
		echo -e "${mag}[`date +"%Y-%m-%d %H:%M:%S"]${off}`${yel} Total Queries :${off}${cyn}${QRYCNT}${off} "
	fi
	
	loops=1
done