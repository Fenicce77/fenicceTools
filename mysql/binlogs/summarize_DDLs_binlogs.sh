#!/opt/homebrew/bin/bash
LOGINPATH=$1
BINLOG_FILE=$2
#BINLOG_FILE="mysqld-bin.000035"
START_TIME=$3
STOP_TIME=$4

mysqlbinlog --login-path=${LOGINPATH} --read-from-remote-server --base64-output=decode-rows -vv ${BINLOG_FILE} | awk \
'BEGIN {s_type=""; s_count=0;count=0;alter_count=0;create_count=0;delete_count=0;flag=0;} \
{if(match($0, /#*Table_map:.*mapped to number/)) {printf "Timestamp : " ${START_TIME} " " ${STOP_TIME} " Table : " $(NF-4); flag=1} \
else if (match($0, /(### ALTER TABLE .*..*)/)) {count=count+1;alter_count=alter_count+1;s_type="ALTER"; s_count=s_count+1;}  \
else if (match($0, /(### CREATE TABLE .*..*)/)) {count=count+1;create_count=create_count+1;s_type="CREATE"; s_count=s_count+1;} \
else if (match($0, /(### DROP TABLE .*..*)/)) {count=count+1;delete_count=delete_count+1;s_type="DROP"; s_count=s_count+1;}  \
else if (match($0, /^(# at) /) && flag==1 && s_count>0) {print " Query Type : "s_type " " s_count " row(s) affected" ;s_type=""; s_count=0; }  \
else if (match($0, /^(COMMIT)/)) {print "[Transaction total : " count " Alter(s) : " alter_count " Create(s) : " create_count " Drop(s) : " \
delete_count "] \n+----------------------+----------------------+----------------------+----------------------+"; \
count=0;alter_count=0;create_count=0; delete_count=0;s_type=""; s_count=0; flag=0} } '

#mysqlbinlog --base64-output=decode-rows -vv bin-log.009457 | awk 'BEGIN {s_type=""; s_count=0;count=0;alter_count=0;create_count=0;delete_count=0;flag=0;} {if(match($0, /#15.*Table_map:.*mapped to number/)) {printf "Timestamp : " $1 " " $2 " Table : " $(NF-4); flag=1}'

#{if(match($0, /#15.*Table_map:.*mapped to number/)) {printf "Timestamp : " $1 " " $2 " Table : " $(NF-4); flag=1} \


# mysql-bin.532959 - OK
# mysql-bin.533181 - OK