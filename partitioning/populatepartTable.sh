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
# New version for executing remotely from own laptop/pc it can be deploy inside server.
# For connection customization, please check parameters $1 and $2 for env and servername. 
# To execute inside server, uncomment the # labeled lines (42 and 43), comment 44 and 45 lines and setup MYCONF variable and edit the file with corresponding parameters

# Connection with --login-path option, previous steps
## Execute mysql_config_editor with related parameters for generating encripted connection credentials, as following example:
## Execute and type the password desired when required : $ mysql_config_editor set --login-path=prod --user=<dbusername> --password
#### >> NOTE: login-path=prod for me is the corresponding identifier for the connection; in the config file generated will add a section labeled like [prod]
## This creates the corresponding .mylogin.cnf in your home dir


# Binary Path
AWKBIN=`which awk`
GREPBIN=`which grep`
MYSQLBIN=`which mysql`
PTARCHIVERBIN=`which pt-archiver`
# DIRECTORIES
#BASEDIR="/root/tools"
BASEDIR="."
CONFDIR="${BASEDIR}/conf"
BASEARCHIVERDIR="${BASEDIR}/archiver"
#BASEARCHIVERLOGDIR="/var/log/archiver"
BASEARCHIVERLOGDIR="log/archiver"
# Connection configuration file
MYCONFILE="${CONFDIR}/cmp-mariadb-dev2.cnf"
#ENV=$1
# Server name/ip to connect
#MYCONFILE=$1

### Connection parameters
MYUSER=`cat $MYCONFILE | grep user | awk -F'=' '{print $2}'`
MYPASS=`cat $MYCONFILE | grep password | awk -F'=' '{print $2}'`
MYHOST=`cat $MYCONFILE | grep host | awk -F'=' '{print $2}'`
MYPORT=`cat $MYCONFILE | grep port | awk -F'=' '{print $2}'`



echo "[`date +"%Y-%m-%d %H:%M:%S"`]${yel}[INFO] Checking Archiver log dir ${BASEARCHIVERLOGDIR} ${off}"
if [[ ! -d  ${BASEARCHIVERLOGDIR} ]]; then
	echo "[`date +"%Y-%m-%d %H:%M:%S"`]${yel}[INFO] Creating Archiver log dir ${BASEARCHIVERLOGDIR} ${off}"
	mkdir -p ${BASEARCHIVERLOGDIR}
	if [[ $? -eq 0 ]]; then echo "[`date +"%Y-%m-%d %H:%M:%S"`]${grn}[INFO] Created Archiver log dir ${BASEARCHIVERLOGDIR} ${off}";fi
else
	echo "[`date +"%Y-%m-%d %H:%M:%S"`]${grn}[INFO] Archiver log dir ${BASEARCHIVERLOGDIR} Already present!${off}"
fi

echo -e "\n${yel}Enter the target SCHEMA name, followed by [ENTER]:${off}"
read SCHEMA_NAME;
if [[ -z ${SCHEMA_NAME} ]]; then 
	echo "[`date +"%Y-%m-%d %H:%M:%S"`]${red}[ERROR] Schema name cannot be empty${off}"
	exit 1
else 
	ARCHIVERDBLOGDIR="${BASEARCHIVERLOGDIR}/${SCHEMA_NAME}"
	echo "[`date +"%Y-%m-%d %H:%M:%S"`]${yel}[INFO] Checking Archiver log dir for ${SCHEMA_NAME} in ${ARCHIVERDBLOGDIR} ${off}"
	if [[ ! -d ${ARCHIVERDBLOGDIR} ]]; then
		echo "[`date +"%Y-%m-%d %H:%M:%S"`]${yel}[INFO] Creating Archiver log dir for schema ${SCHEMA_NAME} : ${ARCHIVERDBLOGDIR} ${off}"
		mkdir -p  ${ARCHIVERDBLOGDIR}
		if [[ $? -eq 0 ]]; then echo "[`date +"%Y-%m-%d %H:%M:%S"`]${grn}[INFO] Created Archiver log dir ${ARCHIVERDBLOGDIR} ${off}";fi
	else
		echo "[`date +"%Y-%m-%d %H:%M:%S"`]${cyn}[INFO] Archiver log dir for schema ${SCHEMA_NAME} already present : ${ARCHIVERDBLOGDIR} ${off}"
	fi
fi

echo -e "\n${yel}Enter the source TABLE name, followed by [ENTER]:${off}"
read TABLE_NAME;
if [[ -z ${TABLE_NAME} ]]; then 
	echo "[`date +"%Y-%m-%d %H:%M:%S"`]${red}[ERROR] Table name cannot be empty${off}" 
	exit 1
fi 
echo -e "\n${yel}Enter the destination partitioned TABLE name, followed by [ENTER]:${off}"
read DEST_TABLE_NAME;
if [[ -z ${DEST_TABLE_NAME} ]]; then 
	echo "[`date +"%Y-%m-%d %H:%M:%S"`]${red}[ERROR] Table name cannot be empty${off}" 
	exit 1	
else 
	ARCHIVERTABLOG="${ARCHIVERDBLOGDIR}/${TABLE_NAME}to${DEST_TABLE_NAME}.log"
	echo "[`date +"%Y-%m-%d %H:%M:%S"`]${cyn}[INFO] Archiver operations for table ${off}${yel}${SCHEMA_NAME}.${TABLE_NAME}${off} are logged in : ${ARCHIVERTABLOG}"
fi


BASESTART_TS='2021-01-01 00:00:00'
DAYS_IN_ADV=30

echo "\n${yel}Enter range of dates for running archiving data from ${TABLE_NAME} to ${DEST_TABLE_NAME}:${off}"
echo -e "\n${mag}Enter start time as yyyy-mm-dd HH:MM:SS format, followed by [ENTER]:${off}"
read START_TS;
if [[ -z ${START_TS} ]]; then 
	echo "[`date +"%Y-%m-%d %H:%M:%S"`]${red}[ERROR] Start Time cannot be empty${off}" 
	exit 1
else	
	echo -e "\n${mag}Enter finish time as yyyy-mm-dd HH:MM:SS format, followed by [ENTER]:${off}"
	read END_TS;
	if [[ -z ${END_TS} ]]; then 
		echo "[`date +"%Y-%m-%d %H:%M:%S"`]${red}[ERROR] Table name cannot be empty${off}" 
		exit 1	
	else 
		echo -e "\n${mag}Enter the offset in days for chunk selection (30 days by default), followed by [ENTER]:${off}"
		read OFFSET_INDAYS;
		if [[ -z ${OFFSET_INDAYS} ]]; then OFFSET_INDAYS=$DAYS_IN_ADV; fi
	fi
fi

echo "${yel}[`date +"%Y-%m-%d %H:%M:%S"`]${cyn}[INFO] Summary of data for tabla data archiving${off}"
echo -e "${yel} + ------------------------------------------------------- +${off} "
echo -e "${blu} | TABLE SCHEMA          : ${off}${SCHEMA_NAME}${cyn}${off}  "
echo -e "${blu} |  >  SOURCE TABLE      < ${off}${TABLE_NAME}${cyn}${off}   "
echo -e "${blu} |  > DESTINATION TABLE  > ${off}${DEST_TABLE_NAME}${cyn}${off}"
echo -e "${blu} | DATE RANGE${off}                                          "
echo -e "${blu} |  > SINCE              : ${off}${START_TS}${cyn}${off}     "
echo -e "${blu} |  > TO                 : ${off}${END_TS}${cyn}${off}       "
echo -e "${blu} |  > Offset in days     : ${off}${OFFSET_INDAYS}${cyn}${off}"
echo -e "${yel} + ------------------------------------------------------- + ${off}"

PTARCHIVERCREDENTIALS="--user=${MYUSER} --password=${MYPASS} "
PTARCHIVERSOURCEOPTS="--source h=${MYHOST},u=${MYUSER},p=${MYPASS},D=${SCHEMA_NAME},t=${TABLE_NAME}"
PTARCHIVERDESTOPTS="--dest h=${MYHOST},u=${MYUSER},p=${MYPASS},D=${SCHEMA_NAME},t=${DEST_TABLE_NAME}"

##  
## Obtaining range of ids(PK) and date for each chunk selected by the OFFSET_INDAYS value and rows accounting
##
#SELECT date_format(start_time,'%Y-%m') as yymonth,min(start_time) as fistday, min(session_log_id) as firstid, max(start_time) as lastday,max(session_log_id) as lastid, count(session_log_id) as totalbymonth 
#FROM dj.session_log 
#WHERE start_time>='2022-03-01 00:00:00' and start_time<'2023-01-01 00:00:00' group by yymonth;

SQL1="SELECT date_format(start_time,'%Y-%m') as yymonth,min(start_time) as fistday, min(session_log_id) as firstid, max(start_time) as lastday,max(session_log_id) as lastid, count(session_log_id) as totalbymonth FROM ${SCHEMA_NAME}.${TABLE_NAME} WHERE start_time>='${START_TS}' AND start_time<'${END_TS}' GROUP BY yymonth;"
echo "QRY : ${SQL1}"
${MYSQLBIN} --defaults-file=${MYCONFILE} -tN ${SCHEMA_NAME} -e"${SQL1}" | ${GREPBIN} '|' > kk.out 
#for row in `${MYSQLBIN} --defaults-file=${MYCONFILE} -tN ${SCHEMA_NAME} -e"${SQL1}" | ${GREPBIN} -v '-'`


while IFS='' read -r row || [[ -n "$row" ]]; 
do

# pt-archiver command line generation for each month 
# --where      : for filtering data by table PK
# --no-delete  : Do not delete archived rows from source table
# --replace    : use replace instead of insert for data insertion in partitioned table
# --progress   : Print progress information every X rows
# --limit      : Number of rows to fetch and archive per statement. Limits the number of rows returned by the SELECT statements that retrieve rows to archive. 
# --txn-size   : Number of rows per transaction. Specifies the size, in number of rows, of each transaction. 
# --statistics : Collect and print timing statistics.
#=30000 --txn-size=30000


	#echo "$linea" | awk -F'|' '{print $4}' ; 
	INITID=`echo ${row} | ${AWKBIN} -F'|' '{print $4}'| tr -d '[[:space:]]'`
	LASTID=`echo ${row} | ${AWKBIN} -F'|' '{print $6}'| tr -d '[[:space:]]'`
	startdate=`echo ${row} | awk -F'|' '{print $3}'`
	enddate=`echo ${row} | awk -F'|' '{print $5}'`

	echo "INITID=${INITID} | LASTID=${LASTID}"
	#exit 0
	echo -e "${yel}[`date +"%Y-%m-%d %H:%M:%S"`]${off}${cyn}[INFO][PT_ARCHIVE] Running pt-archiver from table ${off}${yel}${TABLE_NAME}${off}${cyn} to ${off}${yel}${DEST_TABLE_NAME}${off}${cyn} since ${off}${yel}${startdate}${off}${cyn} to ${off}${yel}${enddate}${off}"

	PTARCHIVEWHEREOPTS="--where 'session_log_id>=${INITID} and session_log_id<=${LASTID}'"
#    PTARCHIVEREXTRAOPTS="--no-delete --replace --no-check-columns --progress=10000 --limit=10000 --txn-size=10000 --statistics --check-interval=15 --no-check-charset --dry-run"
        ##echo "${PTARCHIVERBIN} ${PTARCHIVERCREDENTIALS} ${PTARCHIVERSOURCEOPTS} ${PTARCHIVERDESTOPTS} ${PTARCHIVEWHEREOPTS} ${PTARCHIVEREXTRAOPTS}"
#       echo "${PTARCHIVERBIN} ${PTARCHIVERCREDENTIALS} ${PTARCHIVERTABLEOPTS} ${PTARCHIVEWHEREOPTS} ${PTARCHIVEREXTRAOPTS}"

#       echo "${PTARCHIVERBIN} $PTARCHIVERSOURCEOPTS \
#                        $PTARCHIVERDESTOPTS  \
#                        ${PTARCHIVEWHEREOPTS} \
#                        ${PTARCHIVEREXTRAOPTS}"
        ##${PTARCHIVERBIN} ${PTARCHIVERCREDENTIALS} ${PTARCHIVERSOURCEOPTS} ${PTARCHIVERDESTOPTS} ${PTARCHIVEWHEREOPTS} ${PTARCHIVEREXTRAOPTS}
        ${PTARCHIVERBIN} --source h=${MYHOST},u=${MYUSER},p=${MYPASS},D=${SCHEMA_NAME},t=${TABLE_NAME} \
                         --dest h=${MYHOST},u=${MYUSER},p=${MYPASS},D=${SCHEMA_NAME},t=${DEST_TABLE_NAME} \
                         --no-delete --replace --no-version-check --no-check-columns --progress=30000 --limit=30000 --txn-size=30000 --statistics --check-interval=15 --no-check-charset \
                         --where "session_log_id>=${INITID} and session_log_id<=${LASTID}"
        
        if [[ $? -eq 0 ]]; then
                echo "${grn}[`date +"%Y-%m-%d %H:%M:%S"`][INFO][PT_ARCHIVE][OK] pt-archiver successfuly ran for data ${off}${cyn}since ${off}${yel}${startdate}${off}${cyn} to ${off}${yel}${enddate}${off}"
        else
                echo "${red}[`date +"%Y-%m-%d %H:%M:%S"`][INFO][PT_ARCHIVE][ERROR] pt-archiver reported errors during execution ${off}"
        fi



	# PTARCHIVEWHEREOPTS="--where 'session_log_id>=${INITID} and session_log_id<=${LASTID}'"
	# PTARCHIVEREXTRAOPTS="--no-delete --replace --no-check-columns --progress=10000 --limit=10000 --txn-size=10000 --statistics --check-interval=15 --no-check-charset"
	# ##echo "${PTARCHIVERBIN} ${PTARCHIVERCREDENTIALS} ${PTARCHIVERSOURCEOPTS} ${PTARCHIVERDESTOPTS} ${PTARCHIVEWHEREOPTS} ${PTARCHIVEREXTRAOPTS}"
	# echo "${PTARCHIVERBIN} ${PTARCHIVERCREDENTIALS} ${PTARCHIVERTABLEOPTS} ${PTARCHIVEWHEREOPTS} ${PTARCHIVEREXTRAOPTS}"

	# ##${PTARCHIVERBIN} ${PTARCHIVERCREDENTIALS} ${PTARCHIVERSOURCEOPTS} ${PTARCHIVERDESTOPTS} ${PTARCHIVEWHEREOPTS} ${PTARCHIVEREXTRAOPTS}
	# ${PTARCHIVERBIN} ${PTARCHIVERCREDENTIALS} ${PTARCHIVERTABLEOPTS} ${PTARCHIVEWHEREOPTS} ${PTARCHIVEREXTRAOPTS}
	# if [[ $? -eq 0 ]]; then
	# 	echo "${grn}[`date +"%Y-%m-%d %H:%M:%S"`][INFO][PT_ARCHIVE][OK] pt-archiver successfuly ran for data ${off}${cyn}since ${off}${yel}${startdate}${off}${cyn} to ${off}${yel}${enddate}${off}"
	# else
	# 	echo "${red}[`date +"%Y-%m-%d %H:%M:%S"`][INFO][PT_ARCHIVE][ERROR] pt-archiver reported errors during execution ${off}"
	# fi
done < kk.out


exit 0
















# # Check DBSERVERNAME parameter
# if [[ -z $1 ]] 
# then 
# 	echo -e "${red}[ERROR][NO CONNECTION FILE] MySQL/MariaDB Connection file cannot be empty.${off}${yel}Please, check parameters command line${off}..."
# 	echo -e "${cyn} Usage command line : ./check_opened_sessions.sh [MYCONFILE_PATH] [NO DBSERVERNAME]MySQL DB Server cannot be empty.${off}"
# 	echo -e "${yel} Example            : ./check_opened_sessions.sh /path/myconf.cnf${off}\n"
# 	exit -1
# else
# #	 MYCONF="${HOME}/.myconffiles/${DBSERVERNAME}.cnf"
# 	MYCONF=${MYCONFILE}
# fi

# echo "===================================================================================== "
# echo "${cyn}Open connections : User - DB - Host Connection Source - Total Account in MySQL DB Server ${off} (delay 5s)"
# echo "===================================================================================== "
# echo ""

# while true
# do

# done


