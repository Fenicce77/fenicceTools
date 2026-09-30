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
OUTFILE="/tmp/binlog_operations_acc.out"
for f in `cat /tmp/binary_file_list.txt`; do 
	echo "${yel}[`date +"%Y-%m-%d %H:%M:%S"]`[INFO]Accounting operations from binary log : ${f}${off}"
	echo "Accounting operations in binary log : ${f}" >> ${OUTFILE}
	/home/rmateos/myTools/mysql/binlogs/summarize_binlogs.sh ${f} | grep Table |cut -d':' -f5| cut -d' ' -f2 | sort | uniq -c | sort -nr >> ${OUTFILE}
	echo " "
	echo "${yel}[`date +"%Y-%m-%d %H:%M:%S"]`${off}${grn}[INFO]${f} Succesfully processed and dumped in ${OUTFILE} ${off}"
	sleep 5s;
done 