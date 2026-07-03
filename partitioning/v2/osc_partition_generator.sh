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
FIRST_YEAR=2020
NUM_YEARS=20
EXTRA_TEXT=''
OSC_ALTER_OPTION='--ask-pass --no-check-alter --nocheck-plan --alter-foreign-keys-method=drop_swap'
OSC_LOAD_OPTION='--max-lag 300 --max-load Threads_running=100,Threads_connected=3500 --critical-load Threads_connected=5000'
DB_PORT=3306

# Setting gdate instead of date for MacOS
MAC_OS=$(uname -a | grep Darwin | wc -l)
if [[ MAC_OS -eq 1 ]]; then DATE_CMD='gdate'; else DATE_CMD='date'; fi
show_help() {
    cat << EOF
================================================================================
KYC WORKBENCH SIMULATOR (HIGH PERFORMANCE BATCH EDITION)
================================================================================
USAGE: 
  $0 -l <mysql_login_path> -c <mysql_connection_file> [OPTIONS]

REQUIRED PARAMETERS:
  -l <string>    MySQL login path
  -c <file>    MySQL connection file name path for pt-online-schema-change
  -d <string>    Target database name
  -t <string>    Target table name

OPTIONAL PARAMETERS:
  -h             Show this help menu and exit
================================================================================
EOF
    exit 0
}

if [[ $# -eq 0 ]]; then show_help; fi

#while getopts "hl:d:t:I:U:R:i:u:p:c:m:" opt; do
while getopts "hl:c:d:t:" opt; do
    case "$opt" in
        h) show_help ;;
        l) LOGINPATH="$OPTARG" ;;
		c) PTOSC_CONN_FILE="$OPTARG" ;;
        d) DB_NAME="$OPTARG" ;;
        t) TABLE_NAME="$OPTARG" ;;
        # I) INSERT_FILE="$OPTARG" ;;
        # U) UPDATE_FILE="$OPTARG" ;;
        # R) READ_FILE="$OPTARG" ;;
        # i) INSERTS_PER_CYCLE="$OPTARG" ;;
        # u) UPDATES_PER_CYCLE="$OPTARG" ;;
        # p) READ_THREADS="$OPTARG" ;;
        # c) CYCLES="$OPTARG" ;;
        # m) MIX_RATIO="$OPTARG" ;;
        *) show_help ;;
    esac
done

# if [[ -z "$LOGINPATH" || -z "$DB_NAME" || -z "$TABLE_NAME" || -z "$INSERT_FILE" || -z "$UPDATE_FILE" || -z "$READ_FILE" ]]; then
#     log_message "ERROR" "Missing mandatory parameters."
#     exit 1
# fi
if [[ -z "$LOGINPATH" ]]; then
    log_message "ERROR" "Missing mandatory parameters."
    exit 1
fi

echo -e "\nEnter the target SCHEMA name, followed by [ENTER]:"
read SCHEMA_NAME;
if [[ -z ${SCHEMA_NAME} ]]; then echo "Schema name cannot be empty"; exit 1; fi

echo -e "\nEnter the target TABLE name, followed by [ENTER]:"
read TABLE_NAME;
if [[ -z ${TABLE_NAME} ]]; then echo "Table name cannot be empty"; exit 1; fi

# PK and UQ Check
echo "Looking for Clustered Indexes -> PKs and UQs"
QUERYPK="SELECT GROUP_CONCAT(COLUMN_NAME) FROM information_schema.COLUMNS where TABLE_SCHEMA='${SCHEMA_NAME}' and TABLE_NAME='${TABLE_NAME}' and COLUMN_KEY='PRI' ORDER BY ORDINAL_POSITION ASC"
QUERYUQ="SELECT GROUP_CONCAT(COLUMN_NAME) FROM information_schema.COLUMNS where TABLE_SCHEMA='${SCHEMA_NAME}' and TABLE_NAME='${TABLE_NAME}' and COLUMN_KEY='UNI' ORDER BY ORDINAL_POSITION ASC"
# PK_COLUMN=$(mysql -u${USER} -p${PZPASS} -h${HOST_NAME} -P${DB_PORT} ${SCHEMA_NAME} -Nse "${QUERY}" 2> /dev/null)

# PK Check
PK_COLUMN=$(mysql --login-path=${LOGINPATH} -A ${SCHEMA_NAME} -Nse "${QUERYPK}" 2> /dev/null)
echo "Found Primary Key: ${PK_COLUMN}"
# UQ Check
UQ_COLUMN=$(mysql --login-path=${LOGINPATH} -A ${SCHEMA_NAME} -Nse "${QUERYUQ}" 2> /dev/null)
if [[ -z ${UQ_COLUMN} ]]; then 
	UQ_COLUMN=""; 
else 
	FLAGADDUQ=0;
	
	QUERYUQNAME="SELECT INDEX_NAME FROM information_schema.STATISTICS where TABLE_SCHEMA='${SCHEMA_NAME}' and TABLE_NAME='${TABLE_NAME}' and COLUMN_NAME='${UQ_COLUMN}' and NON_UNIQUE=0 and INDEX_TYPE != 'PRIMARY'"
	UQ_NAME=$(mysql --login-path=${LOGINPATH} -A ${SCHEMA_NAME} -Nse "${QUERYUQNAME}" 2> /dev/null)
	echo "Found Unique Key on ${UQ_COLUMN} -> ${UQ_NAME}"
	DROP_UQ="DROP KEY ${UQ_NAME}";
	echo -e -n "\n??? Do you need to keep the Unique Key in the table ??? (y/n), if yes it will be modified for adding the partitioning column as part of the Unique Key: UNIQUE KEY (${UQ_COLUMN}, <partitioning column>)":
	read -n 1 </dev/tty
	if [[ $REPLY =~ ^[Yy]$ ]]; then 
		FLAGADDUQ=1; 
	else 
		NONUQCOLUMNKEY="ADD KEY IDX_${UQ_COLUMN}(${UQ_COLUMN}),"; 
	fi
fi

echo -e -n "\n??? Do you need do add the partitioning time-based column to the table ??? (y/n): "
read -n 1 </dev/tty
if [[ $REPLY =~ ^[Yy]$ ]]; then 
	echo -e "\nEnter the partitioning datetime/timestamp column name, followed by [ENTER]:"
	read DATE_COLUMN
	if [[ -z ${DATE_COLUMN} ]]; then echo "Datetime/timestamp column name cannot be empty"; exit 1; fi

	echo -e "\nSpecify partitioning column type: DATETIME or TIMESTAMP (or D, T) followed by [ENTER]:"
	read COLUMN_TYPE
	if [[ -z ${COLUMN_TYPE} ]]; then echo "Datetime/timestamp column type cannot be empty"; exit 1; fi

	ADD_COLUMN="ADD COLUMN ${DATE_COLUMN} ${COLUMN_TYPE} DEFAULT CURRENT_TIMESTAMP,"
else
	echo -e "\n\nEnter the partitioning datetime/timestamp column name, followed by [ENTER]:"
	read DATE_COLUMN
	if [[ -z ${DATE_COLUMN} ]]; then echo "Date column name cannot be empty"; exit 1; fi
	
	QUERY="SELECT DATA_TYPE FROM information_schema.COLUMNS where TABLE_SCHEMA='${SCHEMA_NAME}' and TABLE_NAME='${TABLE_NAME}' and COLUMN_NAME='${DATE_COLUMN}'"
#	COLUMN_TYPE=$(mysql -u${USER} -p${PZPASS} -h${HOST_NAME} -P${DB_PORT} ${DB_NAME} -Nse "${QUERY}" 2> /dev/null)
	COLUMN_TYPE=$(mysql --login-path=${LOGINPATH} -A ${DB_NAME} -Nse "${QUERY}" 2> /dev/null)
	case ${COLUMN_TYPE} in
		'datetime') PARTITIONING='TO_DAYS' ;;
		'timestamp') PARTITIONING='UNIX_TIMESTAMP' ;;
		'*') echo "DATE column type not supported"; exit 1;;
	esac
	echo "Found data type: ${COLUMN_TYPE}"	
fi
if [ $FLAGADDUQ -eq 1 ]; then EXTR_ADD_UQ="${DROP_UQ}, ADD UNIQUE KEY UQ_${UQ_COLUMN} (${UQ_COLUMN},${DATE_COLUMN})"; fi
if [ $FLAGADDUQ -eq 0 ]; then EXTR_ADD_UQ="${DROP_UQ}, ${NONUQCOLUMNKEY}"; fi
echo -e  -n "\n??? Do you need extra text to put before PARTITION BY RANGE (es. extra indexes, compression) ??? (y/n): "
read -n 1 </dev/tty
if [[ $REPLY =~ ^[Yy]$ ]]; then
	echo -e "\nSpecify the text followed by [ENTER]:";
	read EXTRA_TEXT
	if [[ -z ${EXTRA_TEXT} ]]; then echo "Extra text cannot be empty, since you requested it"; exit 1; fi; fi

echo -e "\n\nSpecify time range for partitioning: DAY or MONTH or YEAR [or D, M, Y] followed by [ENTER]:"
read TIME_RANGE
# Check if variable is empty or the dir already exists
if [[ -z ${TIME_RANGE} ]]; then echo "Time range cannot be empty"; exit 1; fi

case $(echo $TIME_RANGE | tr '[:upper:]' '[:lower:]') in
	'd'|'day')
		first=1
		curmonth=$(${DATE_CMD} "+%b")
#		echo -e -n "pt-online-schema-change --${RUN} --user=${USER} ${OSC_ALTER_OPTION} --alter\n\"DROP PRIMARY KEY, ${ADD_COLUMN} ADD PRIMARY KEY(${PK_COLUMN}, ${DATE_COLUMN}), INDEX IDX_${DATE_COLUMN}(${DATE_COLUMN}) ${EXTRA_TEXT}\nPARTITION BY RANGE(${PARTITIONING}(${DATE_COLUMN}))\n("
		echo -e -n "pt-online-schema-change --${RUN} --defaults-file=${PTOSC_CONN_FILE} ${OSC_ALTER_OPTION} --ask-pass --alter\n\"DROP PRIMARY KEY, ${ADD_COLUMN} ADD PRIMARY KEY(${PK_COLUMN}, ${DATE_COLUMN}), ADD KEY IDX_${DATE_COLUMN}(${DATE_COLUMN}),${EXTR_ADD_UQ} ${EXTRA_TEXT}\nPARTITION BY RANGE(${PARTITIONING}(${DATE_COLUMN}))\n("
		for s in $(seq $((FIRST_DAY -1 )) 1 $((FIRST_DAY + DAYS_IN_ADV)))
		do
			if [ $first -eq 1 ]; then first=0; else echo -n ","; fi

			curday=$(${DATE_CMD} -d "$curmonth 1 + $s day" "+%Y-%m-%d")
			printf "PARTITION p%d VALUES LESS than (${PARTITIONING}('$curday')) \n" $s
		done
#		echo -e ")\" \n${OSC_LOAD_OPTION} D=${SCHEMA_NAME},t=${TABLE_NAME},S=${MYSQl_SOCKET}"
		echo -e ")\" \n${OSC_LOAD_OPTION} D=${SCHEMA_NAME},t=${TABLE_NAME}"
	;;
	'm'|'month')
		first=1
		curyear=$(${DATE_CMD} "+%Y")
		#echo -e -n "pt-online-schema-change --${RUN} --user=${USER} ${OSC_ALTER_OPTION} --alter\n\"DROP PRIMARY KEY, ${ADD_COLUMN} ADD PRIMARY KEY(${PK_COLUMN}, ${DATE_COLUMN}), INDEX IDX_${DATE_COLUMN}(${DATE_COLUMN}) ${EXTRA_TEXT}\nPARTITION BY RANGE(${PARTITIONING}(${DATE_COLUMN}))\n("
		echo -e -n "pt-online-schema-change --${RUN} --defaults-file=${PTOSC_CONN_FILE} ${OSC_ALTER_OPTION} --ask-pass --alter\n\"DROP PRIMARY KEY, ${ADD_COLUMN} ADD PRIMARY KEY(${PK_COLUMN}, ${DATE_COLUMN}), ADD KEY IDX_${DATE_COLUMN}(${DATE_COLUMN}),${EXTR_ADD_UQ} ${EXTRA_TEXT}\nPARTITION BY RANGE(${PARTITIONING}(${DATE_COLUMN}))\n("
		for s in $(seq $((FIRST_MON )) 1 $((FIRST_MON + NUM_MONTHS)))
		do
			if [ $first -eq 1 ]; then first=0; else echo -n ","; fi

			curday=$(${DATE_CMD} -d "1 Jan $curyear + $s months" "+%Y-%m-%d")
			if [[ $s -lt 10 ]]; then  
				printf "PARTITION p${curyear}0%d VALUES LESS than (${PARTITIONING}('$curday')) \n" $s
			else
				printf "PARTITION p${curyear}%d VALUES LESS than (${PARTITIONING}('$curday')) \n" $s
			fi
		done
#		echo -e ")\" \n ${OSC_LOAD_OPTION} D=${SCHEMA_NAME},t=${TABLE_NAME},S=${MYSQl_SOCKET}"
		echo -e ")\" \n ${OSC_LOAD_OPTION} D=${SCHEMA_NAME},t=${TABLE_NAME}"
	;;
	'y'|'year' )
		first=1
		curyear=$(${DATE_CMD} "+%Y")
#		echo -n "pt-online-schema-change --${RUN} --user=${USER} ${OSC_ALTER_OPTION} --alter\n\"DROP PRIMARY KEY, ${ADD_COLUMN} ADD PRIMARY KEY(${PK_COLUMN}, ${DATE_COLUMN}), INDEX IDX_${DATE_COLUMN}(${DATE_COLUMN}) ${EXTRA_TEXT} PARTITION BY RANGE(${PARTITIONING}(${DATE_COLUMN})) ("
		echo -n "pt-online-schema-change --${RUN} --defaults-file=${PTOSC_CONN_FILE} ${OSC_ALTER_OPTION} --ask-pass --alter\n\"DROP PRIMARY KEY, ${ADD_COLUMN} ADD PRIMARY KEY(${PK_COLUMN}, ${DATE_COLUMN}), ADD KEY IDX_${DATE_COLUMN}(${DATE_COLUMN}),${EXTR_ADD_UQ} ${EXTRA_TEXT} PARTITION BY RANGE(${PARTITIONING}(${DATE_COLUMN})) ("
		for s in $(seq $FIRST_YEAR 1 $((FIRST_YEAR + NUM_YEARS)))
		do
			if [ $first -eq 1 ]; then first=0; else echo -n ","; fi

			curday=$(${DATE_CMD} -d "1 Jan $s" "+%Y-%m-%d")
			printf "\nPARTITION p${curyear}%d VALUES LESS than ($s)" $((s-1))
		done
#		echo -e ")\" \n ${OSC_LOAD_OPTION} D=${SCHEMA_NAME},t=${TABLE_NAME},S=${MYSQl_SOCKET}"
		echo -e ")\" \n ${OSC_LOAD_OPTION} D=${SCHEMA_NAME},t=${TABLE_NAME}"
	;;
	*) echo "Time range not recognized"; exit 1;;
esac

exit 0
