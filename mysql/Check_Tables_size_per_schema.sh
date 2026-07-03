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

DBLISTQRY="select schema_name from information_schema.SCHEMATA where schema_name not in ('mysql','information_schema','sys','performance_schema');"
# DBSIZEQRY="SELECT TABLE_SCHEMA,TABLE_NAME,(DATA_LENGTH/1024/1024) AS DATA_SIZE_MB,(INDEX_LENGTH/1024/1024) AS INDEX_SIZE_MB,CHECKSUM,TABLE_ROWS FROM information_schema.TABLES WHERE TABLE_SCHEMA='${DB}' GROUP BY TABLE_SCHEMA,TABLE_NAME ORDER BY FULL_TABLESIZE_IN_MB DESC;"
for DB in `echo ${DBLISTQRY} |mysql --login-path=prod -N`; do
	DBSIZEQRY="SELECT TABLE_SCHEMA,TABLE_NAME,(DATA_LENGTH/1024/1024) AS DATA_SIZE_MB,(INDEX_LENGTH/1024/1024) AS INDEX_SIZE_MB,CHECKSUM,TABLE_ROWS FROM information_schema.TABLES WHERE TABLE_SCHEMA='${DB}' GROUP BY TABLE_SCHEMA,TABLE_NAME ORDER BY DATA_SIZE_MB DESC;"
	# Check Base Dump Directory is created, if not created it
	echo "${yel}[`date +"%Y-%m-%d %H:%M:%S"`][JOKERBET][TABLE_CHECKS][INFO][DB=${DB}] Dumping Schema Tables Information for ${DB} into ${DB}.tables.out${off}"
	echo ${DBSIZEQRY} | mysql --login-path=prod -N > ${DB}.tables.out
	echo "[`date +"%Y-%m-%d %H:%M:%S"`][JOKERBET][TABLE_CHECKS][INFO] Sleeping 5 seconds Before next check !!"
	sleep 5s
done