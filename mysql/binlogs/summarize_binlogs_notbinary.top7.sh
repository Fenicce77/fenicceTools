#!/bin/bash
LONGESTRANSOUTFILE="summarize_binlogs_out/longest_trans.out"
for f in `ls binlogs/`; do 
	echo "Analizing top 7 of longest transactions in $f..."
	echo " ==================================================================================================================================================== " >> ${LONGESTRANSOUTFILE}
	echo " >>>> TOP7 TRANSACTIONS FOR ${f} : " >> ${LONGESTRANSOUTFILE}
	/home/rmateos/myTools/sh/summarize_binlogs_notbinary.sh binlogs/${f} | grep Table | sort -nr -k 12 | head -n 7 >> ${LONGESTRANSOUTFILE}
	echo " <<<< " >> ${LONGESTRANSOUTFILE}
done

# $HOME/mygit/myTools2/mysql/binlogs/summarize_binlogs_notbinary.sh 