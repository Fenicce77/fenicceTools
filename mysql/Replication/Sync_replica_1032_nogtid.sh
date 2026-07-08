#!/bin/bash
# Author : Ricardo Mateos Calcines
# Desc : Script for syncying MySQL slave after 1032 error in a non multisource replica
# output colours
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
# command bin paths
CATBIN=`which cat`
GREPBIN=`which grep`
AWKBIN=`which awk`

CHECKVERSIONQRY="select version();"
CHECKLASTERRNO="Last_SQL_Errno:"
# MySQL Show slave command related to server version
SHOWSLAVEQRYOLD="show slave status\G"
SHOWLAVEQRRV8022="show replica status\G"
# MySQL Stop/Start slave command related to server version
#SKIPCOUNTQRYOLD="stop slave;set global gtid_mode=ON_PERMISSIVE; SET GLOBAL SQL_SLAVE_SKIP_COUNTER = 1;START SLAVE;set global gtid_mode=ON;"
SKIPCOUNTQRYOLD="stop slave;SET GLOBAL SQL_SLAVE_SKIP_COUNTER = 1;START SLAVE;"
#SKIPCOUNTQRYV8022="stop replica;set global gtid_mode=ON_PERMISSIVE; SET GLOBAL SQL_SLAVE_SKIP_COUNTER = 1;START replica;set global gtid_mode=ON;"
NEWVER="8.0.22"
MYSQLVER=`echo $CHECKVERSIONQRY | mysql -N`
# MySQL version check
echo "[`date +"%Y-%m-%d %H:%M:%S"`]${cyn}Checking MySQL Version${off}"
if [[ "$MYSQLVER" != "$NEWVER" ]]; then
        SHOWSLAVEQRY=$SHOWSLAVEQRYOLD
        SKIPCOUNTQRY=$SKIPCOUNTQRYOLD
        echo "[`date +"%Y-%m-%d %H:%M:%S"`][INFO]MySQL Version : ${grn}$MYSQLVER${off}"
else
        SHOWSLAVEQRY=$SHOWLAVEQRRV8022
        SKIPCOUNTQRY=$SKIPCOUNTQRYV8022
        echo "[`date +"%Y-%m-%d %H:%M:%S"`][INFO]MySQL ${red}${NEWVER}${off} detected!!"
fi
# Check seconds behind master
SECSBEHIND=$(echo "SHOW SLAVE STATUS\G" | mysql | grep Seconds_Behind_Master | tr -d '[[:space:]]' | awk -F':' '{print $2}')
while [ $SECSBEHIND == 'NULL' ]; do
        #statements
        LASTSQLERRNO=$(echo "SHOW SLAVE STATUS\G" | mysql | grep "Last_SQL_Errno:" | awk -F':' '{print $2}' | tr -d '[[:space:]]')
        LASTSQLERR=$(echo "SHOW SLAVE STATUS\G" | mysql | grep "Last_SQL_Error:" | sed 's/Last_SQL_Error://g' | sed 's/^[[:space:]]*//' )
        case "$LASTSQLERRNO" in
                1032|1062|1396)
                                echo "[`date +"%Y-%m-%d %H:%M:%S"`]${mag}[INFO]$LASTSQLERRNO detected!!${off}"
                                echo "[`date +"%Y-%m-%d %H:%M:%S"`]${mag}[INFO]$LASTSQLERR${off}"
                                echo "[`date +"%Y-%m-%d %H:%M:%S"`]${yel}[INFO]Skipping duplicated transaction!!${off}"
                                echo "$SKIPCOUNTQRY" | mysql
                                echo "[`date +"%Y-%m-%d %H:%M:%S"`]${cyn}[SLEEPING]Sleeping 5s before new check${off}"
                                sleep 5s
                                SECSBEHIND=$(echo "SHOW SLAVE STATUS\G" | mysql | grep Seconds_Behind_Master | tr -d '[[:space:]]' | awk -F':' '{print $2}')
                            #echo "SKIPCOUNTQRY" | mysql
                        ;;
                0)
                 echo "[`date +"%Y-%m-%d %H:%M:%S"`]${grn}[INFO]No SQL_Thread Errors found!!${off}.${yel}Sleeping 10s before new check..."
                 sleep 10s
                 SECSBEHIND=$(echo "SHOW SLAVE STATUS\G" | mysql | grep Seconds_Behind_Master | tr -d '[[:space:]]' | awk -F':' '{print $2}')
                ;;
                *)
                 echo "[`date +"%Y-%m-%d %H:%M:%S"`]${red}[WARN]Replication stopped by other issue no related to Errors 1032 or 1062. Please check replication errors related...${off}"
                 SECSBEHIND=$(echo "SHOW SLAVE STATUS\G" | mysql | grep Seconds_Behind_Master | tr -d '[[:space:]]' | awk -F':' '{print $2}')
                 echo "SHOW SLAVE STATUS\G" | mysql | grep Err | sed 's/^[[:space:]]*//'
                 echo "[`date +"%Y-%m-%d %H:%M:%S"`]${yel}[INFO]Exiting${off}"
                 exit 1
                 ;;
        esac
done
exit 0