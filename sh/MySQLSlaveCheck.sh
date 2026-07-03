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

#MYCONF="/Users/rmateos/my.conn.cnf"
DELAY=15
LASTSECVAL=0
ITERATION=0
#echo -e "\nEnter the ${cyn}MySQL DB Server Name (or IP)${off} for checking Master and Slave Status followed by [ENTER]:"
#read DBSERVERNAME;
DBSERVERNAME=`hostname`
#if [[ -z ${DBSERVERNAME} ]]; then echo -e "MySQL DB Server cannot be empty\n Starting again...\n\n"; continue; 
#else
while true;
do
    #ISMASTER=`echo "show variables like 'log_bin';"| mysql --defaults-extra-file=${MYCONF} -h ${DBSERVERNAME} -N | awk '{print $2}'`
    LOGBINENABLE=`echo "show variables like 'log_bin';"| mysql | awk '{print $2}'`
    ISMASTER=`echo "show variables like 'read_only';"| mysql | awk '{print $2}'`
    if [ ${ISMASTER} -eq 1 ];then
    	echo -e "${yel}${DBSERVERNAME}${off} : ${red}NOT MASTER...No Master Status Checks to do!!${off}"
    else
		echo -e "${mag}### ${DBSERVERNAME} MySQL Master Status :${off}";
		echo -e "${grn}"
		echo -e "File	Position"
		MASTERSTATUS=`echo "show master status;"|mysql -N`
		echo -e $MASTERSTATUS
	fi
	echo -e "${off}";echo " ----------------------------------------------------- "
	echo -e "${yel}## ${DBSERVERNAME} MySQL Slave Status :${off}";
	echo -e "${grn}"
	CURRSECVAL=`echo "show slave status\G" | mysql --defaults-extra-file=${MYCONF} -h ${DBSERVERNAME} | grep Sec | cut -d':' -f2`
	DIFF=`echo "${LASTSECVAL}-${CURRSECVAL}"|bc`
	echo "show slave status\G" | mysql | grep Sec
	echo "show slave status\G" | mysql | grep -i Master_Log;echo "show slave status\G" | mysql --defaults-extra-file=${MYCONF} -h ${DBSERVERNAME} | grep -i relay_log
	echo -e "${off}"
	if [ $ITERATION -ne 0 ];then 
		if [ ${DIFF} -gt 0 ];then
			echo -e "${yel}Replication Delay Decreased in :${off}${grn}${DIFF}${off}"
		else
			if [ ${DIFF} -lt 0 ];then
				echo -e "${yel}Replication Delay Increased in :${off}${red}${DIFF}${off}"
			else
				echo -e "${grn}SLAVE SYNCED${off}"
			fi
		fi
	else
		ITERATION=1
		fi
	LASTSECVAL=${CURRSECVAL}
	echo -e "${blu}>>> Sleeping ${DELAY} seconds for a new check !!${off}"
	sleep ${DELAY}s;
done
#fi