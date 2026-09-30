#!/bin/bash

BINLOG_FILE=$1
#START_TIME=$2
#STOP_TIME=$3

#mysqlbinlog --base64-output=decode-rows -vv --start-datetime="${START_TIME}"  --stop-datetime="${STOP_TIME}" ${BINLOG_FILE} | awk \
mysqlbinlog --base64-output=decode-rows -vv ${BINLOG_FILE} | awk 'BEGIN {s_type=""; s_count=0;count=0;insert_count=0;update_count=0;delete_count=0;flag=0;} {if(match($0, /#*Table_map:.*mapped to number/)) {printf "Timestamp : " $1 " " $2 " Table : " $(NF-4); flag=1} else if (match($0, /(### INSERT INTO .*..*)/)) {count=count+1;insert_count=insert_count+1;s_type="INSERT"; s_count=s_count+1;} else if (match($0, /(### UPDATE .*..*)/)) {count=count+1;update_count=update_count+1;s_type="UPDATE"; s_count=s_count+1;} else if (match($0, /(### DELETE FROM .*..*)/)) {count=count+1;delete_count=delete_count+1;s_type="DELETE"; s_count=s_count+1;} else if (match($0, /^(# at) /) && flag==1 && s_count>0) {print " Query Type : "s_type " " s_count " row(s) affected" ;s_type=""; s_count=0; } else if (match($0, /^(COMMIT)/)) {print "[Transaction total : " count " Insert(s) : " insert_count " Update(s) : " update_count " Delete(s) : " delete_count "] \n+----------------------+----------------------+----------------------+----------------------+"; count=0;insert_count=0;update_count=0; delete_count=0;s_type=""; s_count=0; flag=0} } '

# Usefull command execution :
# 1.- Check highest insert/update/delete operation tables
# summarize_binlogs.sh | grep Table |cut -d':' -f5| cut -d' ' -f2 | sort | uniq -c | sort -nr
# 2.- Check highest delete operation tables
# ./summarize_binlogs.sh | grep -E 'DELETE' |cut -d':' -f5| cut -d' ' -f2 | sort | uniq -c | sort -nr
# 3.- Check operations executed on a specific table
# ./summarize_binlogs.sh | grep -i '`<schema>`.`<table>`' | awk '{print $7 " " $11}' | sort -k1,2 | uniq -c
# 4.- Top 7 tables 
# summarize_binlogs.sh | grep Table | sort -nr -k 12 | head -n 7
# /home/rmateos/myTools/mysql/binlogs/summarize_binlogs_notbinary.sh /mysql/mysqllog/bin-log.003634 | grep Table |cut -d':' -f5| cut -d' ' -f2 | sort | uniq -c | sort -nr
# /home/rmateos/myTools/mysql/binlogs/summarize_binlogs_notbinary.sh /mysql/mysqllog/bin-log.003634 | grep -E 'DELETE' |cut -d':' -f5| cut -d' ' -f2 | sort | uniq -c | sort -nr

# $HOME/mygit/myTools2/mysql/binlogs/summarize_binlogs.sh binlog.000421 | grep Table | sort -nr -k 12 | head -n 7


