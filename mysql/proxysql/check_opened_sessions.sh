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
#echo -e "Enter the ${cyn}MySQL DB Server Name (or IP)${off} for checking Master and Slave Status followed by [ENTER]:"
#read DBSERVERNAME;
#if [[ -z ${DBSERVERNAME} ]] 
#then 
#	echo -e "MySQL DB Server cannot be empty Starting again..."
#	continue
#fi
echo "===================================================================================== "
echo "Enter the ${cyn}Open connections : User - Host - Account in MySQL DB Server ${off} (delay 5s)"
echo "===================================================================================== "
echo ""
while true
do
	echo "-----------"
	echo "${mag}[`date +"%Y-%m-%d %H:%M:%S"`]${off}"
	echo "select * from stats_mysql_processlist;" | mysql 
	echo "Slepping 5s..."
	echo ""
	sleep 5s
done
