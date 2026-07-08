#!/bin/bash
# ###############################################################################################################
# # Script Name : innodb_engine_photographer.sh 
# # Autor : Ricardo Mateos Calcines
# # Creation Date : 2021-06-03
# # Description : Generates the output execution of SHOW ENGINE INNODB STATUS in current MySQL Server
###               during pt-online-schema-change for monitoring purposes if DEADLOCKS are running
# # Notes : 
# #        1.- /tmp/pt-osc-RUNNING.txt file must be created with 0 or 1 for running succesfully  
# #             - 0 : pt-osc not running
# #             - 1 : pt-osc not running
# ###############################################################################################################
blk=$(tput blink)
bld=$(tput bold)                 # Bold
red=${bld}$(tput setaf 1)    # Red
grn=${bld}$(tput setaf 2)    # Green
yel=${bld}$(tput setaf 3)    # Yellow
blu=${bld}$(tput setaf 4)    # Blue
mag=${bld}$(tput setaf 5)    # Purple
cyn=${bld}$(tput setaf 6)    # Cyan
wht=${bld}$(tput setaf 7)    # White
off=$(tput sgr0)             # Text reset
# INNODB STATUS output file
OUTPUTFILE=$1
# INNODB STATUS default output file if not provided by parameter
DEFSHOWINNODBOUTPUT="./innodb_status_out.out"
# script log file
LOGFILE="innodb_engine_photographer.log"
# pt-osc token file
PTOSCFILE="/tmp/pt-osc.RUNNING.txt"
PTOSCRUNNING=0
echo "[`date +"%Y-%m-%d %H:%M:%S"`] >>>>>>> InnoDB Engine Status Runnning every 5s"
echo "[`date +"%Y-%m-%d %H:%M:%S"`] >>>>>>> InnoDB Engine Status Runnning every 5s" >> $LOGFILE
echo "${yel}[`date +"%Y-%m-%d %H:%M:%S"`]>> InnoDB Engine Status Output : ${OUTPUTFILE} <<${off}"
echo "${yel}>> InnoDB Engine Status Output : ${OUTPUTFILE} <<${off}"
echo "[`date +"%Y-%m-%d %H:%M:%S"`]>> InnoDB Engine Status Output : ${OUTPUTFILE} <<" >> $LOGFILE
echo "${yel}[`date +"%Y-%m-%d %H:%M:%S"`]Checking pt-osc is running...${off}"
echo "[`date +"%Y-%m-%d %H:%M:%S"`]Checking pt-osc is running..." >> $LOGFILE
# Entry parameter check
if [ $# -eq 0 ];then
	OUTPUTFILE=${DEFSHOWINNODBOUTPUT}
	echo "[`date +"%Y-%m-%d %H:%M:%S"`][WARNING] No file parameter provided for SHOW ENGINE INNODB STATUS output!! It will be prompted in : ${OUTPUTFILE} " >> $LOGFILE
	echo "[`date +"%Y-%m-%d %H:%M:%S"`]${red}[WARNING]${off}${yel}No file parameter provided for SHOW ENGINE INNODB STATUS output!! It will be prompted in : ${OUTPUTFILE} ${off}"
fi
# Check pt-osc token file is created and with  correct value for keep running or stop
for i in {1..10}
do
	# check if file present
	if [ ! -f "$PTOSCFILE" ]; then
		echo "[`date +"%Y-%m-%d %H:%M:%S"`] pt-osc check attempt ${i} : NOT RUNNING...waiting 5s for next check" >> $LOGFILE
		echo "${yel}[`date +"%Y-%m-%d %H:%M:%S"`] pt-osc check attempt ${i} :${off}${red} NOT RUNNING...waiting 5s for next check${off}"
                echo "[`date +"%Y-%m-%d %H:%M:%S"`]Sleeping 5s" >> $LOGFILE
                echo "[`date +"%Y-%m-%d %H:%M:%S"`]Sleeping 5s"
		Sleep 5s
	else
	# check file value stored
		PTOSCRUNNING=`cat ${PTOSCFILE}`
		if [ ${PTOSCRUNNING} -eq 1 ];then
			echo "[`date +"%Y-%m-%d %H:%M:%S"`] pt-osc check attempt ${i} : RUNNING!!!" >> $LOGFILE
			echo "${yel}[`date +"%Y-%m-%d %H:%M:%S"`] pt-osc check attempt ${i} :${off}${grn} NOT RUNNING...waiting 5s for next check${off}"
			echo "[`date +"%Y-%m-%d %H:%M:%S"`] STARTING SHOW ENGINE INNODB STATUS OUTPUT CAPTURING!!!" >> $LOGFILE
			echo "${yel}[`date +"%Y-%m-%d %H:%M:%S"`]${off} ${grn}STARTING SHOW ENGINE INNODB STATUS OUTPUT CAPTURING!!! ${off}"
		else
			echo "[`date +"%Y-%m-%d %H:%M:%S"`] pt-osc check attempt ${i} : NOT RUNNING...waiting 5s for next check" >> $LOGFILE
			echo "${yel}[`date +"%Y-%m-%d %H:%M:%S"`] pt-osc check attempt ${i} :${off}${red} NOT RUNNING...waiting 5s for next check${off}"
                	echo "[`date +"%Y-%m-%d %H:%M:%S"`]Sleeping 5s" >> $LOGFILE
                	echo "[`date +"%Y-%m-%d %H:%M:%S"`]Sleeping 5s"
                	Sleep 5s
		fi
	fi
done
# If file not present or value not expected for running after 10 attempts, will exit
if [ ${PTOSCRUNNING} -eq 0 ]; then 
	echo "[`date +"%Y-%m-%d %H:%M:%S"`] pt-osc NOT RUNNING. Exiting..." >> $LOGFILE
	echo "${yel}[`date +"%Y-%m-%d %H:%M:%S"`] ${off}${red} pt-osc NOT RUNNING. Exiting...${off}"a
        exit 1
fi
# show engine innnodb status execution tailing output
while [ ${PTOSCRUNNING} -eq 1 ]
do 
        echo "${grn}[`date +"%Y-%m-%d %H:%M:%S"`] Executing SHOW ENGINE INNODB STATUS into outputfile :${off}${yel}$OUTPUTFILE${off}"
        echo "[`date +"%Y-%m-%d %H:%M:%S"`] Executing SHOW ENGINE INNODB STATUS into outputfile :$OUTPUTFILE" >> $LOGFILE
        echo "[`date +"%Y-%m-%d %H:%M:%S"`] Executing SHOW ENGINE INNODB STATUS..." >> $LOGFILE
	echo "show engine innodb status\G" | sudo mysql >> ${OUTPUTFILE}
	echo "${yel}[`date +"%Y-%m-%d %H:%M:%S"`] >>>> Sleeping 5s${off}"
	echo "[`date +"%Y-%m-%d %H:%M:%S"`] >>>> Sleeping 5s " >> $LOGFILE
	sleep 5s
done
echo "${yel}[`date +"%Y-%m-%d %H:%M:%S"`]${off}${grn} pt-online-schema change successfully finished!! INNODB ENGINE STATUS monitor finished!!${off}"
echo "[`date +"%Y-%m-%d %H:%M:%S"`]pt-online-schema change successfully finished!! INNODB ENGINE STATUS monitor finished!!" >> $LOGFILE
exit

