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
# New version for executing locally 
# execute it as root with no user
#MYCONF="rmateos.my.cnf"
#echo -e "\nEnter the ${cyn}MySQL DB Server Name (or IP)${off} for checking Master and Slave Status followed by [ENTER]:"
#read DBSERVERNAME;
#if [[ -z ${DBSERVERNAME} ]] 
#then 
#	echo -e "MySQL DB Server cannot be empty\n Starting again...\n\n"
#	continue
#fi

# MySQL Binary Path
MYSQLBIN=`which mysql`

#SQLDIRPATH="/home/rmateos/myTools/mysql/sql/"
SQLDIRPATH="./sql/"
FILENAME="temporary_files_queries.sql"
SQLFNAME=${SQLDIRPATH}${FILENAME}
while true
do
	echo "-----------"
	echo "${mag}[`date +"%Y-%m-%d %H:%M:%S"`]${off}"
	#echo "SELECT USER,DB,substring_index(substring_index(HOST,':',1),'.',3) as HH,count(*) as total FROM information_schema.PROCESSLIST WHERE DB NOT IN ('','mysql') and user not in ('rmateos','gsiclari','percona') group by USER,DB,HH ORDER BY user,total;" | mysql --defaults-extra-file=${MYCONF} -h $DBSERVERNAME -A -N information_schema
	cat $SQLFNAME | ${MYSQLBIN} --login-path=prod -t 

	echo "Slepping 15s..."
	echo ""
	sleep 15s
done
