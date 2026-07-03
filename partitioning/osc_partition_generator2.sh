#!/bin/bash
#
RUN="dry-run"
# Daily partitioning
FIRST_DAY=1
DAYS_IN_ADV=30
# Monthly partitioning
FIRST_MON=1
NUM_MONTHS=12
# Yearly partitioning
FIRST_YEAR=2010
NUM_YEARS=20
EXTRA_TEXT=''
OSC_ALTER_OPTION='--ask-pass --no-check-alter --nocheck-plan --alter-foreign-keys-method=drop_swap'
OSC_LOAD_OPTION='--max-lag 300 --max-load Threads_running=100,Threads_connected=3500 --critical-load Threads_connected=5000'
DB_PORT=3306

# Setting gdate instead of date for MacOS
MAC_OS=$(uname -a | grep Darwin | wc -l)
if [[ MAC_OS -eq 1 ]]; then DATE_CMD='gdate'; else DATE_CMD='date'; fi

if [[ -z $1 ]]; then
	echo "${red}[ERROR] No connection parameters file provided${off}"
	exit -1
else
	# Configuration Parameters
	MYCONFILE=$1
	USER=`grep "user" ${MYCONFILE} |  awk -F'=' '{print $2}'| sed 's/"//g'`
	PZPASS=`grep "password" ${MYCONFILE} |  awk -F'=' '{print $2}'| sed 's/"//g'`
	HOST_NAME=`grep "host" ${MYCONFILE} |  awk -F'=' '{print $2}'| sed 's/"//g'`
	DB_PORT=`grep "port" ${MYCONFILE} |  awk -F'=' '{print $2}'| sed 's/"//g'`

	echo "${blu}Connection parameters${off}"
	echo "${grn}*** User : ${USER}${off}"
#	echo "${grn}*** Pass : ${PZPASS}${off}"
	echo "${grn}*** Hostname : ${HOST_NAME}${off}"
	echo "${grn}*** DB Port  : ${DB_PORT}${off}"
fi

echo -e "\n${yel}Enter the target SCHEMA name, followed by [ENTER]:${off}"
read SCHEMA_NAME;
if [[ -z ${SCHEMA_NAME} ]]; then echo "[`date +"%Y-%m-%d %H:%M:%S"`]${red}[ERROR] Schema name cannot be empty${off}"; exit 1; fi

echo -e "\n${yel}Enter the target TABLE name, followed by [ENTER]:${off}"
read TABLE_NAME;
if [[ -z ${TABLE_NAME} ]]; then echo "[`date +"%Y-%m-%d %H:%M:%S"`]${red}[ERROR] Table name cannot be empty${off}"; exit 1; fi

QUERY="SELECT GROUP_CONCAT(COLUMN_NAME) FROM information_schema.COLUMNS where TABLE_SCHEMA='${SCHEMA_NAME}' and TABLE_NAME='${TABLE_NAME}' and COLUMN_KEY='PRI' ORDER BY ORDINAL_POSITION ASC"

PK_COLUMN=$(mysql -u${USER} -p${PZPASS} -h${HOST_NAME} -A ${SCHEMA_NAME} -Nse "${QUERY}" 2> /dev/null)

echo "[`date +"%Y-%m-%d %H:%M:%S"`]${blu}[INFO]Found Primary Key:${off}${grn}${PK_COLUMN} ${off}"

# Check if table contains auto_increment
QRYAUTOINCRCHECK="SELECT COLUMN_NAME FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='${SCHEMA_NAME}' and TABLE_NAME='${TABLE_NAME}' AND EXTRA='auto_increment'"
AUTOINC_COLUMN=$(mysql -u${USER} -p${PZPASS} -h${HOST_NAME} -A ${SCHEMA_NAME} -Nse "${QRYAUTOINCRCHECK}" 2> /dev/null)
if [[ -z ${AUTOINC_COLUMN} ]]; then
	NOAUTOINC=1
	echo "[`date +"%Y-%m-%d %H:%M:%S"`]${mag}[WARNING] NO auto_increment COLUMNS PRESENT IN ${SCHEMA_NAME}.${TABLE_NAME} table!!${off}"
	# ADD COLUMN autoId bigint(20) unsigned FIRST, ADD primary key (autoId)
	ADD_AUTOINC_COLUMN="ADD COLUMN autoId bigint unsigned auto_increment FIRST "
	echo "[`date +"%Y-%m-%d %H:%M:%S"`]${blu}[INFO] auto_increment column creation clause will be added to pt-online-schema-change command line ${off} : ${grn} ${ADD_AUTOINC_COLUMN} ${off}"
fi

# Check if other unique indexes are present
QRYCHECKUNIQUENONPK="SELECT index_name FROM information_schema.statistics WHERE TABLE_SCHEMA='${SCHEMA_NAME}' AND TABLE_NAME='${TABLE_NAME}' AND INDEX_NAME<>'PRIMARY' AND NON_UNIQUE=0 GROUP BY INDEX_NAME;"
UNIQUE_INDEXES=$(mysql -u${USER} -p${PZPASS} -h${HOST_NAME} -A ${SCHEMA_NAME} -Nse "${QRYCHECKUNIQUENONPK}" 2> /dev/null)
if [[ -z ${UNIQUE_INDEXES} ]]; then
	#statements
	echo -e "${blu}[`date +"%Y-%m-%d %H:%M:%S"`][INFO]  NO UNIQUE KEYs FOUND !!${off}"
fi
#exit 0

# echo -e  -n "\n??? Do you need extra text to put before PARTITION BY RANGE (es. extra indexes, compression) ??? (y/n): "
# read -n 1 </dev/tty
# if [[ $REPLY =~ ^[Yy]$ ]]; then
# 	echo -e "\nSpecify the text followed by [ENTER]:";
# 	read EXTRA_TEXT
# 	if [[ -z ${EXTRA_TEXT} ]]; then echo "Extra text cannot be empty, since you requested it"; exit 1; fi; fi

# echo -e "\n\nSpecify time range for partitioning: DAY or MONTH or YEAR [or D, M, Y] followed by [ENTER]:"
# read TIME_RANGE
# # Check if variable is empty or the dir already exists
# if [[ -z ${TIME_RANGE} ]]; then echo "Time range cannot be empty"; exit 1; fi


echo -e -n "\n${yel}??? Do you need do add the partitioning time-based column to the table ??? (y/n): ${off}"
read -n 1 </dev/tty
if [[ $REPLY =~ ^[Yy]$ ]]; then 
	echo -e "\n${yel}Enter the partitioning datetime/timestamp column name, followed by [ENTER]:${off}"
	read DATE_COLUMN
	if [[ -z ${DATE_COLUMN} ]]; then echo "[`date +"%Y-%m-%d %H:%M:%S"`]${red}[ERROR] Datetime/timestamp column name cannot be empty${off}"; exit 1; fi

	echo -e "\n${yel}Specify partitioning column type: DATETIME or TIMESTAMP (or D, T) followed by [ENTER]:${off}"
	read COLUMN_TYPE
	if [[ -z ${COLUMN_TYPE} ]]; then echo "[`date +"%Y-%m-%d %H:%M:%S"`]${red}[ERROR]Datetime/timestamp column type cannot be empty${off}"; exit 1; fi

	ADD_COLUMN="ADD COLUMN ${DATE_COLUMN} ${COLUMN_TYPE} DEFAULT CURRENT_TIMESTAMP,"
else
	echo -e "\n\n${yel}Enter the partitioning datetime/timestamp column name, followed by [ENTER]:${off}"
	read DATE_COLUMN
	if [[ -z ${DATE_COLUMN} ]]; then echo "[`date +"%Y-%m-%d %H:%M:%S"`]${red}[ERROR]Date column name cannot be empty${off}"; exit 1; fi
	
	QUERY="SELECT DATA_TYPE FROM information_schema.COLUMNS where TABLE_SCHEMA='${SCHEMA_NAME}' and TABLE_NAME='${TABLE_NAME}' and COLUMN_NAME='${DATE_COLUMN}'"
	COLUMN_TYPE=$(mysql -u${USER} -p${PZPASS} -h${HOST_NAME} -A ${DB_NAME} -Nse "${QUERY}" 2> /dev/null)
	case ${COLUMN_TYPE} in
		'datetime') PARTITIONING='COLUMNS'; RANGEPARTOPTION=" ${PARTITIONING}(${DATE_COLUMN})" ;;
		'timestamp') PARTITIONING='UNIX_TIMESTAMP'; RANGEPARTOPTION="(${PARTITIONING}(${DATE_COLUMN}))" ;;
		'*') echo "[`date +"%Y-%m-%d %H:%M:%S"`]${red}[ERROR] DATE column type not supported${off}"; exit 1;;
	esac
	echo "[`date +"%Y-%m-%d %H:%M:%S"`]${blu}[INFO]Found data type:${off}${grn} ${COLUMN_TYPE} ${off}"	
fi

echo -e  -n "\n${yel}??? Do you need extra text to put before PARTITION BY RANGE (es. extra indexes, compression) ??? (y/n):${off} "
read -n 1 </dev/tty
if [[ $REPLY =~ ^[Yy]$ ]]; then
	echo -e "\n${yel}Specify the text followed by [ENTER]:${off}";
	read EXTRA_TEXT
	if [[ -z ${EXTRA_TEXT} ]]; then echo "[`date +"%Y-%m-%d %H:%M:%S"`]${red}[ERROR] Extra text cannot be empty, since you requested it${off}"; exit 1; fi; fi

echo -e "\n\n${yel}Specify time range for partitioning: DAY or MONTH or YEAR [or D, M, Y] followed by [ENTER]:${off}"
read TIME_RANGE
# Check if variable is empty or the dir already exists
if [[ -z ${TIME_RANGE} ]]; then echo "[`date +"%Y-%m-%d %H:%M:%S"`]${red}[ERROR] Time range cannot be empty${off}"; exit 1; fi

INDEXES="DROP PRIMARY KEY, ${ADD_COLUMN} ADD PRIMARY KEY(${PK_COLUMN}, ${DATE_COLUMN}), ADD INDEX(${DATE_COLUMN}) "

if [[ ${NOAUTOINC} -eq 1 ]]; then
	INDEXES="DROP PRIMARY KEY, ${ADD_AUTOINC_COLUMN}, ${ADD_COLUMN} ADD PRIMARY KEY(autoId, ${DATE_COLUMN}), ADD UNIQUE INDEX (${PK_COLUMN}, ${DATE_COLUMN}) ,ADD INDEX(${DATE_COLUMN})"
fi

case $(echo $TIME_RANGE | tr '[:upper:]' '[:lower:]') in
	'd'|'day')
		first=1
		curmonth=$(${DATE_CMD} "+%b")
		echo -e -n "pt-online-schema-change --${RUN} --user=${USER} ${OSC_ALTER_OPTION} --alter\n\"DROP PRIMARY KEY, ${ADD_COLUMN} ADD PRIMARY KEY(${PK_COLUMN}, ${DATE_COLUMN}), ADD INDEX(${DATE_COLUMN}) ${EXTRA_TEXT}\nPARTITION BY RANGE(${PARTITIONING}(${DATE_COLUMN}))\n("
		for s in $(seq $((FIRST_DAY -1 )) 1 $((FIRST_DAY + DAYS_IN_ADV)))
		do
			if [ $first -eq 1 ]; then first=0; else echo -n ","; fi

			curday=$(${DATE_CMD} -d "$curmonth 1 + $s day" "+%Y-%m-%d")
			printf "PARTITION p%d VALUES LESS than (${PARTITIONING}('$curday')) \n" $s
		done
		echo -e ")\" \n${OSC_LOAD_OPTION} D=${SCHEMA_NAME},t=${TABLE_NAME},S=${MYSQl_SOCKET}"
	;;
	'm'|'month')
		first=1
		curyear=$(${DATE_CMD} "+%Y")
		echo -e -n "pt-online-schema-change --${RUN} --user=${USER} ${OSC_ALTER_OPTION} --alter\n\"DROP PRIMARY KEY, ${ADD_COLUMN} ADD PRIMARY KEY(${PK_COLUMN}, ${DATE_COLUMN}), ADD INDEX(${DATE_COLUMN}) ${EXTRA_TEXT}\nPARTITION BY RANGE(${PARTITIONING}(${DATE_COLUMN}))\n("
		for s in $(seq $((FIRST_MON -1 )) 1 $((FIRST_MON + NUM_MONTHS)))
		do
			if [ $first -eq 1 ]; then first=0; else echo -n ","; fi

			curday=$(${DATE_CMD} -d "1 Jan $curyear + $s months" "+%Y-%m-%d")
			printf "PARTITION p%d VALUES LESS than (${PARTITIONING}('$curday')) \n" $s
		done
		echo -e ")\" \n ${OSC_LOAD_OPTION} D=${SCHEMA_NAME},t=${TABLE_NAME},S=${MYSQl_SOCKET}"
	;;
	'y'|'year' )
		first=1
		curyear=$(${DATE_CMD} "+%Y")
		echo -n "pt-online-schema-change --${RUN} --user=${USER} ${OSC_ALTER_OPTION} --alter\n\"DROP PRIMARY KEY, ${ADD_COLUMN} ADD PRIMARY KEY(${PK_COLUMN}, ${DATE_COLUMN}), ADD INDEX(${DATE_COLUMN}) ${EXTRA_TEXT} PARTITION BY RANGE(${PARTITIONING}(${DATE_COLUMN})) ("
		for s in $(seq $FIRST_YEAR 1 $((FIRST_YEAR + NUM_YEARS)))
		do
			if [ $first -eq 1 ]; then first=0; else echo -n ","; fi

			curday=$(${DATE_CMD} -d "1 Jan $s" "+%Y-%m-%d")
			printf "\nPARTITION p%d VALUES LESS than ($s)" $((s-1))
		done
		echo -e ")\" \n ${OSC_LOAD_OPTION} D=${SCHEMA_NAME},t=${TABLE_NAME},S=${MYSQl_SOCKET}"
	;;
	*) echo "Time range not recognized"; exit 1;;
esac

exit 0
