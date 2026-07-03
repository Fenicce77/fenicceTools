#!/usr/local/bin/bash
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
#DBSERVERLIST="${HOME}/mysql_servers_list.txt"
DBSERVERLIST="${HOME}/servers_login_list.pro.txt"
# Environment to check. PROD by default
#ENV="prod"
# OBJTYPE: Object Type to check, values avalable: DB, TAB, COL, PROC, TRIG, USER
#     - DB   : DB SCHEMA
#	  - TAB  : TABLE
#	  - COL  : COLUMN
#	  - PROC : PROCEDURE
#	  - TRIG : TRIGGER
#	  - USER : USER

OBJTYPE=$2
OBJECTNAME=$3
# Search DB Schema QRY
QRYSEARCHDB="select @@hostname,SCHEMA_NAME as db FROM information_schema.SCHEMATA WHERE SCHEMA_NAME LIKE '%${OBJECTNAME}%';"
# Search TABLE QRY
QRYSEARCHTAB="select @@hostname,CONCAT(TABLE_SCHEMA,'.',TABLE_NAME) AS TABLE_FULL_NAME FROM information_schema.TABLES WHERE TABLE_NAME like '%${OBJECTNAME}%' AND TABLE_SCHEMA NOT IN ('mysql','information_schema','mysql','performance_schema','sys');"
# Search Column
QRYSEARCHCOL="SELECT 
	TABLE_SCHEMA,TABLE_NAME,COLUMN_NAME,DATA_TYPE,COLUMN_TYPE,
	CASE COLUMN_KEY
		WHEN 'PRI' THEN 'PK INDEX COMPONENT'
        WHEN 'UNI' THEN 'UNIQUE INDEX COMPONENT'
        WHEN 'MUL' THEN 'INDEX '
        ELSE 'NON INDEXED'
	end IS_KEY,
	EXTRA 
FROM 
	INFORMATION_SCHEMA.COLUMNS 
WHERE 
	COLUMN_NAME like '%${OBJECTNAME}%' 
	AND TABLE_SCHEMA not in ('sys','mysql','information_schema','performance_schema');"
QRYSEARCHUSR="select @@hostname, CONCAT(USER,'@',host) as fullusername FROM mysql.user where user like '%${OBJECTNAME}%';"
#QRYSEARCHPROC="SELECT ROUTINE_SCHEMA, ROUTINE_NAME,ROUTINE_TYPE,DEFINER,CREATED,LAST_ALTERED FROM INFORMATION_SCHEMA.ROUTINES where ROUTINE_NAME like '%${OBJECTNAME}%' AND ROUTINE_SCHEMA not in ('mysql','information_schema','mysql','performance_schema','sys');"
QRYSEARCHPROC="SELECT @@hostname,ROUTINE_SCHEMA, ROUTINE_NAME,ROUTINE_TYPE,DEFINER,CREATED,LAST_ALTERED FROM INFORMATION_SCHEMA.ROUTINES where ROUTINE_SCHEMA not in ('mysql','information_schema','mysql','performance_schema','sys');"
#QRYSEARCHTRIG="SELECT TRIGGER_SCHEMA, TRIGGER_NAME,ROUTINE_TYPE,DEFINER,CREATED FROM INFORMATION_SCHEMA.TRIGGERS where TRIGGER_NAME like '%${OBJECTNAME}%' AND TRIGGER_NAME not in ('mysql','information_schema','mysql','performance_schema','sys');"
QRYSEARCHTRIG="SELECT @@hostname,TRIGGER_SCHEMA, TRIGGER_NAME,DEFINER FROM INFORMATION_SCHEMA.TRIGGERS where TRIGGER_SCHEMA not in ('mysql','information_schema','mysql','performance_schema','sys');"
# for SRV in `cat ${HOME}/mysql_servers_list.txt`
# do
# 	#echo "${cyn}Connecting to ${off}${yel}$SRV${off}" 
# 	#echo "[`date +"%Y-%m-%d %H:%M:%S"`][SEARC][FULL][INFO] Starting Logical Backup at : `date +"%Y-%m-%d %H:%M:%S"`]" >>
# 	echo "$QRY" | mysql --login-path=prod -h $SRV -N; 
# 	if [ $? -ne 0 ];then
# 		echo "${yel}[`date +"%Y-%m-%d %H:%M:%S"`][SEARCH]${off}${red}[ERROR]${off}Error Connecting Attempt to server:${red}$SRV${off}"
# 	else
# 		echo "${yel}[`date +"%Y-%m-%d %H:%M:%S"`][SEARCH]${off}${grn}[OK]${off}Succesfully connected : ${off}${grn}$SRV${off}"
# 	fi

# done
for SRV in `cat ${DBSERVERLIST}`
do
	case $OBJTYPE in
		"DB" )
			for SRV in `cat $DBSERVERLIST`; do echo "${cyn}Connecting to ${off}${yel}$SRV${off}"; echo ${QRYSEARCHDB} | mysql --login-path=${SRV} -t; done
			;;
		"TAB" )
			for SRV in `cat $DBSERVERLIST`; do echo "${cyn}Connecting to ${off}${yel}$SRV${off}"; echo ${QRYSEARCHTAB} | mysql --login-path=${SRV} -t; done
			;;
		"COL" )
			for SRV in `cat $DBSERVERLIST`; do echo "${cyn}Connecting to ${off}${yel}$SRV${off}";echo ${QRYSEARCHDB} | mysql --login-path=${SRV} -t; done
			;;
		"USER" )
			for SRV in `cat $DBSERVERLIST`; do echo "${cyn}Connecting to ${off}${yel}$SRV${off}";echo ${QRYSEARCHUSR} | mysql --login-path=${SRV} -t; done
			;;
		"PROC" )
			for SRV in `cat $DBSERVERLIST`; do echo "${cyn}Connecting to ${off}${yel}$SRV${off}";echo ${QRYSEARCHPROC} | mysql --login-path=${SRV} -t; done
			;;
		"TRIG" )
			for SRV in `cat $DBSERVERLIST`; do echo "${cyn}Connecting to ${off}${yel}$SRV${off}";echo ${QRYSEARCHTRIG} | mysql --login-path=${SRV} -t; done
			;;
	esac
done