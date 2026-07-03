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
# Connection configuration file
MYCONF=$1
# Server name/ip to connect
#DBSERVERNAME=$2

DELAY=2
LASTSECVAL=0
ITERATION=0
#echo -e "\nEnter the ${cyn}MySQL DB Server Name (or IP)${off} for checking Master and Slave Status followed by [ENTER]:"
#read DBSERVERNAME;
#DBSERVERNAME=`hostname`
#if [[ -z ${DBSERVERNAME} ]]; then echo -e "MySQL DB Server cannot be empty\n Starting again...\n\n"; continue; 
#else
while true;
do
    ISMASTER=`echo "show variables like 'log_bin';"| ${MYSQLBIN} --defaults-file=${MYCONF} -N | awk '{print $2}'`
    #ISMASTER=`echo "show variables like 'log_bin';"| ${MYSQLBIN} --login-path=prod -N | awk '{print $2}'`
    #LOGBINENABLE=`echo "show variables like 'log_bin';"| ${MYSQLBIN} --login-path=prod -N| awk '{print $2}'`
    LOGBINENABLE=`echo "show variables like 'log_bin';"| ${MYSQLBIN} --defaults-file=${MYCONF} -N| awk '{print $2}'`    
    ONLYREAD=`echo "show variables like 'read_only';"| ${MYSQLBIN} --defaults-file=${MYCONF} -N| awk '{print $2}'`
#    # ONLYREAD=`echo "show variables like 'read_only';"| ${MYSQLBIN} --login-path=prod -N| awk '{print $2}'`
    if [ "${ONLYREAD}" == "ON" ];then
        
        if [ "${ONLYREAD}" == "ON" ]; then 
                echo -e "${yel}${DBSERVERNAME}${off} : ${cyn}* BinLog ENABLED${off}[${grn}OK${off}]"
                echo -e "${yel}${DBSERVERNAME}${off} : ${red}* NO WRITES ALLOWED MASTER!!${off}"
        else
                echo -e "${yel}${DBSERVERNAME}${off} : ${cyn}* BinLog ENABLED${off}[${red}OFF${off}]"
                echo -e "${yel}${DBSERVERNAME}${off} : ${red}* NO WRITES ALLOWED ${off}"
                echo -e "${yel}${DBSERVERNAME}${off} : ${cyn}* READ-ONLY SINGLE SLAVE NODE NO LOGING NODE${off}[${red}OFF${off}]"
        fi

    else
        echo -e "${mag}### ${DBSERVERNAME} MySQL Master Status :${off}";
        echo -e "${grn}"
        echo -e "File   Position"
        #MASTERSTATUS=`echo "show master status;"|${MYSQLBIN} --login-path=prod -N`
        MASTERSTATUS=`echo "show master status;"|${MYSQLBIN} --defaults-file=${MYCONF} -N`
        echo -e $MASTERSTATUS
    fi
    #CHECKSLAVESTATUS=`echo "show slave status\G" | ${MYSQLBIN} --login-path=prod | grep Sec | cut -d':' -f2`
    CHECKSLAVESTATUS=`echo "show slave status\G" | ${MYSQLBIN} --defaults-file=${MYCONF} | grep Sec | cut -d':' -f2`
    if [ ! -z "$CHECKSLAVESTATUS" ]; then
            echo -e "${off}";echo " ----------------------------------------------------- "
            echo -e "${yel}## ${DBSERVERNAME} MySQL Slave Status :${off}";
            echo -e "${grn}"
            CURRSECVAL=`echo "show slave status\G" | ${MYSQLBIN} --defaults-file=${MYCONF} | grep Sec | cut -d':' -f2`
            #CURRSECVAL=`echo "show slave status\G" | ${MYSQLBIN} --login-path=prod | grep Sec | cut -d':' -f2`
            DIFF=`echo "${LASTSECVAL}-${CURRSECVAL}"|bc`
            #echo "show slave status\G" | ${MYSQLBIN} --login-path=prod | grep Sec
            echo "show slave status\G" | ${MYSQLBIN} | grep -i "Master_Log"; echo "show slave status\G" | ${MYSQLBIN} --defaults-file=${MYCONF} -h ${DBSERVERNAME} | grep -i "relay_log"
            echo "show slave status\G" | ${MYSQLBIN} | grep -i "Master_Host"; echo "show slave status\G" | ${MYSQLBIN} --defaults-file=${MYCONF} -h ${DBSERVERNAME} | grep -i "relay_log"
            #echo "show slave status\G" | ${MYSQLBIN} --login-path=prod | grep -i "Master_Log"; echo "show slave status\G" | ${MYSQLBIN} --login-path=prod | grep -i "relay_log"
            #echo "show slave status\G" | ${MYSQLBIN} --login-path=prod | grep -i "Master_Host"; echo "show slave status\G" | ${MYSQLBIN} --login-path=prod | grep -i "relay_log"
            
            echo -e "${off}"
            if [ $ITERATION -ne 0 ];then
                if [ ${DIFF} -gt 0 ];then
                        echo -e "${yel}Replication Delay Decreased in :${off}${grn}${DIFF}${off}"
                else
                        if [ ${DIFF} -lt 0 ];then
                                DIF=`echo "${CURRSECVAL}-${LASTSECVAL}"|bc`
                                echo -e "${yel}Replication Delay Increased in :${off}${red}${DIF}${off}"
                        fi
                        if [ ${CHECKSLAVESTATUS} -eq 0 ];then
                                echo -e "${grn}SLAVE SYNCED${off}"
                        else
                                echo -e "${red}SLAVE NOT SYNCED${off}"
                        fi
                fi
            else
                ITERATION=1
            fi
            LASTSECVAL=${CURRSECVAL}
    fi
    echo -e "${blu}>>> Sleeping ${DELAY} seconds for a new check !!${off}"
    sleep ${DELAY}s;
done

#fi