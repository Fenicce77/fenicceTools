# ###############################################################
# general_log
# parsing and load general log in table for analysing
# ###############################################################
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

# BINPATHS
MYSQLBINPATH=`which mysql`
MYSQLDUMPBINPATH=`which mysqldump`
#PORKOBINPATH="/Users/rmateos/Documents/DBTeam/Tools/porko2"
PORKOBINPATH="/home/rmateos/myTools/porko2000"
#MYCNF="config/general_log.cnf"
OUTFILE="/mysql/mysqlbackup/general_log.load.sql"
PORKOOUTFILE="/mysql/mysqlbackup/porko.general_log.load.sql"
# insertion query file 
TIMEMARKSFILE="/tmp/capture.times.sql"
# MySQL credentials
# MYUSR=`grep "user" ${MYCNF} |  awk -F'=' '{print $2}'`
# MYPWD=`grep "password" ${MYCNF} |  awk -F'=' '{print $2}'`
# MYSRV=`grep "host" ${MYCNF} |  awk -F'=' '{print $2}'`

# Variables 
# CAPTURETIME :  General_log capture or enabling time
# * Default -  5 minutes 
DEFCAPTURETIME="300"
# CHUNKSIZE : Time in seconds for each chunk of queries dump to general_log customized table
CHUNKSIZE="30"
# Capture initial time
INITTIME=`date +"%Y-%m-%d %H:%M:%S"`
#MYSQLDUMPOPTIONS=" --no-create-info --single-transaction --skip-extended-insert --set-gtid-purged=OFF -u${MYUSR} -h ${MYSRV} -p${MYPWD} --databases mysql --tables general_log"
MYSQLDUMPOPTIONS=" --no-create-info --single-transaction --skip-extended-insert --set-gtid-purged=OFF --databases mysql --tables general_log"
echo "[`date +"%Y-%m-%d %H:%M:%S"`] General_log enabling and data dumping for ${MYSRV}"
MYGENERALDB="feniccedb"
# Enable general_log in TABLE (mysql.general_log)
# general_log enabling query
echo -e "\n${blu}Enter the Time IN SECONDS for capturing general_log followed by [ENTER]:${off}"
read CAPTURETIME;
if [[ -z ${CAPTURETIME} ]] 
then 
	echo -e "${yel}[WARNING]NO CAPTURING TIME detailed. Default value, 300 seconds (5 minutes) will be used${off}\n\n"
	CAPTURETIME=DEFCAPTURETIME
	continue
fi
echo "[`date +"%Y-%m-%d %H:%M:%S"`][INFO] Enabling general_log for capturing in table next ${CAPTURETIME} seconds..."
GENERAL_LOG_ENABLING_QRY="SET GLOBAL log_output = 'TABLE';SET GLOBAL general_log = 'ON';"
GENERAL_LOG_DISABLING_QRY="SET GLOBAL general_log = 'OFF';SET GLOBAL log_output = 'FILE';"
CHECK_GENERAL_LOG="show variables like 'general_log';"
#echo ${GENERAL_LOG_ENABLING_QRY} | $MYSQLBINPATH -u ${MYUSR} -h ${MYSRV} -p${MYPWD}
echo ${GENERAL_LOG_ENABLING_QRY} | $MYSQLBINPATH 
if [ -f ${TIMEMARKSFILE} ]; then 
	echo "${INITTIME}"> ${TIMEMARKSFILE}
fi
# Check general_log enabled and capturing during $DELAY seconds
if [ $? -eq 0 ];then

	CAPTUREINITTIME=`date +"%Y-%m-%d %H:%M:%S"`
	echo "CAPTUREINITTIME=${CAPTUREINITTIME}"
	#GENERAL_LOG_ENABLED=`echo ${CHECK_GENERAL_LOG} | $MYSQLBINPATH -u ${MYUSR} -h ${MYSRV} -p${MYPWD} -N| awk '{print $2}'`
	GENERAL_LOG_ENABLED=`echo ${CHECK_GENERAL_LOG} | $MYSQLBINPATH | awk '{print $2}'`
	# Check general_log is enabled as expected
	if [ "$GENERAL_LOG_ENABLED"=="ON" ];then
		
		TOTALCHUNKS=`echo "${CAPTURETIME}/${CHUNKSIZE}" | bc`
		CHUNKINITIME=${CAPTUREINITTIME}
 		for i in `seq 1 ${TOTALCHUNKS}`
 		do
 			sleep ${CHUNKSIZE}s
 			ELEPSED=`echo "${i}*${CHUNKSIZE}"|bc`
 			echo "[`date +"%Y-%m-%d %H:%M:%S"`][INFO]Captured ${ELEPSED} seconds..."

 		done
#		# Disabling general_log 
		echo "[`date +"%Y-%m-%d %H:%M:%S"`][INFO]Stopping general_log capturing..."
		#echo ${GENERAL_LOG_DISABLING_QRY} | $MYSQLBINPATH -u ${MYUSR} -h ${MYSRV} -p${MYPWD}
		echo ${GENERAL_LOG_DISABLING_QRY} | $MYSQLBINPATH
		sleep 2s
 		# Dump mysql.general_log table and 
 		echo "[`date +"%Y-%m-%d %H:%M:%S"`][INFO]Dumping general_log table to ${OUTFILE}"
 		${MYSQLDUMPBINPATH} ${MYSQLDUMPOPTIONS} | grep -i insert | sed 's/general_log/GENERAL_LOG/g' | sed 's/VALUES/(event_time,user_host,thread_id,server_id,command_type,argument) VALUES/g' > ${OUTFILE}
 		if [ $? -eq 0 ]; then
 			echo "[`date +"%Y-%m-%d %H:%M:%S"`][INFO]${grn}[OK] mysql.general_log CSV content table successfully dumped to ${OUTFILE} !!${off}"
 		else
 			echo "[`date +"%Y-%m-%d %H:%M:%S"`][INFO]${red}[ERROR] mysql.general_log CSV NOT DUMPED SUCCESSFULLY!! Exiting...${off}"
 			exit -1
 		fi
 		echo "[`date +"%Y-%m-%d %H:%M:%S"`][INFO] Generating transaction inserting file into ${OUTFILE}"
 		cat ${OUTFILE} | ${PORKOBINPATH} > ${PORKOOUTFILE}
 		if [ $? -eq 0 ]; then
 			echo "[`date +"%Y-%m-%d %H:%M:%S"`][INFO]${grn}[OK] Transactions insertion file SUCCESFULLY generated in ${PORKOOUTFILE} !!${off}"
 			# general_log.GENERAL_LOG table population
 			echo "[`date +"%Y-%m-%d %H:%M:%S"`][INFO] Populating data from ${PORKOOUTFILE} in ${MYGENERALDB} database"
			#cat ${PORKOOUTFILE} | $MYSQLBINPATH -u ${MYUSR} -h ${MYSRV} -p${MYPWD} -N -A ${MYGENERALDB}
			cat ${PORKOOUTFILE} | $MYSQLBINPATH -N -A ${MYGENERALDB}
			if [ $? -eq 0 ]; then
				echo "[`date +"%Y-%m-%d %H:%M:%S"`][INFO]${grn}[OK] Transactions insertion file SUCCESFULLY generated in ${PORKOOUTFILE} !!${off}"
				echo "[`date +"%Y-%m-%d %H:%M:%S"`][INFO]${grn}[OK] mysql.general_log DATA SUCCESFULLY EXPORTED INTO INNODB ${MYGENERALDB}.GENERAL_LOG TABLE !!${off}"
			else 
				echo "[`date +"%Y-%m-%d %H:%M:%S"`][INFO]${red}[ERROR] mysql.general_log DATA NOT LOADED INTO INNODB ${MYGENERALDB}.GENERAL_LOG TABLE !! Exiting...${off}"
				exit -3
			fi
		else 
			echo "[`date +"%Y-%m-%d %H:%M:%S"`][INFO]${red}[ERROR] Transaction insertion file NOT GENERATED!! Exiting...${off}"
			exit -2
		fi
	fi
fi 


