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
MYCONF="${HOME}/mysql/my.options.cnf"
ENV=$1
DELAY=10
#echo -e "Enter the ${cyn}MySQL DB Server Name (or IP)${off} for checking Queries Per Second [ENTER]:"
#read DBSERVERNAME;
#if [[ -z ${DBSERVERNAME} ]]; then echo -e "MySQL DB Server cannot be empty\n Starting again..."; continue; fi
echo " ========================================================================== "
echo " =  MySQL Server QPS in `cat ${MYCONF} | grep host | awk -F'=' '{print $2}' | sort -u`"
echo ""
QRYCNT0=0
loops=0
while true
do 
	QRYCNT=`echo "show status like 'queries';" | $MYSQLBIN --login-path=${ENV} -N | awk '{print $2}'`
	#QRYCNT=`$MYSQLADMINBIN --defaults-extra-file=${MYCNF} -h ${DBSERVERNAME} status | cut -f4 -d ":"  | awk '{print $1}'`
	#QRYCNT=`$MYSQLADMINBIN --defaults-extra-file=${MYCONF} status | cut -f4 -d ":"  | awk '{print $1}'`
	#QRYCNT=`$MYSQLADMINBIN status | cut -f4 -d ":"  | awk '{print $1}'`
	#QRYCNT=`echo ${QRYCNTAUX} | sed 's/\./\,/g'`
	QRYDIFF=`echo "scale=3; ${QRYCNT}-${QRYCNT0}" | bc -l`
	QPS=`echo "scale=3; ${QRYDIFF}/${DELAY}"|bc -l`
	if [[ ${loops} -ne 0 ]]; then
		echo -e "${mag}[`date +"%Y-%m-%d %H:%M:%S"]${off}` ${yel} Total Queries :${off}${cyn}${QRYCNT}${off} -> ${wht}DIF=${QRYDIFF}${off} <> ${grn}QPS${off}=${red}${QPS}${off}"
	else 
		echo -e "${mag}[`date +"%Y-%m-%d %H:%M:%S"]${off}` ${yel} Total Queries :${off}${cyn}${QRYCNT}${off}"
		loops=1
	fi
	
	QRYCNT0=`echo "scale=3; ${QRYCNT}" | bc`
	#QRYCNT0=${QRYCNT}
	sleep ${DELAY}s
done