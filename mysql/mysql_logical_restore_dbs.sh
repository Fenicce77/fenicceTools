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

# Backup/Restore directories
# Root dir
DUMPDIRROOT="/mysql/mysqlbackup"
# Main logical dir
DUMPBASEDIR="${DUMPDIRROOT}/logical"
# DBs dir
DUMPDBBASEDIR="${DUMPDIRROOT}/logical/DBs"
# Log dir
RESTORELOGDIR="${DUMPBASEDIR}/log"
RESTORELOGFILE="${RESTORELOGDIR}/MySQL_Restore_Logical.log"
for db in `ls ${DUMPDBBASEDIR}`
do
	cd ${DUMPDBBASEDIR}/${db}
	echo "${yel}[`date +"%Y-%m-%d %H:%M:%S"`][LOGICAL_RESTORE][INFO][DEFINITION][DB=${db}] Restoring schema tables for schema :${off}${cyn}${db}${off}"
	echo "[`date +"%Y-%m-%d %H:%M:%S"`][LOGICAL_RESTORE][INFO][DEFINITION][DB=${db}] Restoring schema tables for schema :${db}" >> ${RESTORELOGFILE}
	zcat ${db}.schema.sql.gz | mysql ${db}
	if [[ $? -ne 0 ]]; then
                echo "[`date +"%Y-%m-%d %H:%M:%S"`][LOGICAL_RESTORE][ERROR][DEFINITION][DB=${db}] Schema Tables Restore for ${db} FAILED" >> ${RESTORELOGFILE}
                echo "${yel}[`date +"%Y-%m-%d %H:%M:%S"`][LOGICAL_RESTORE][ERROR][DEFINITION][DB=${db}] Schema Tables Restore for ${db} FAILED${off}"
                ERRORCODE=21
    else
                echo "[`date +"%Y-%m-%d %H:%M:%S"`][LOGICAL_RESTORE][DEFINITION][OK][DB=${db}] Schema Tables Restore for ${db} SUCCEED!!" >> ${RESTORELOGFILE}
                echo "${grn}[`date +"%Y-%m-%d %H:%M:%S"`][LOGICAL_RESTORE][DEFINITION][OK][DB=${db}] Schema Tables Restore for ${db} SUCCEED!!${off}"
    fi
	zcat ${db}.data.sql.gz | mysql ${db}
	echo "${yel}[`date +"%Y-%m-%d %H:%M:%S"`][LOGICAL_RESTORE][INFO][DATA][DB=${db}] Restoring Data for schema :${off}${cyn}${db}${off}"
	echo "[`date +"%Y-%m-%d %H:%M:%S"`][LOGICAL_RESTORE][INFO][DATA][DB=${db}] Restoring Data for schema :${db}" >> ${RESTORELOGFILE}
	if [[ $? -ne 0 ]]; then
                echo "[`date +"%Y-%m-%d %H:%M:%S"`][LOGICAL_RESTORE][DATA][ERROR][DB=${db}] Data Restore for ${db} FAILED" >> ${RESTORELOGFILE}
                echo "${yel}[`date +"%Y-%m-%d %H:%M:%S"`][LOGICAL_RESTORE][DATA][ERROR][DB=${db}] Data Restore for ${db} FAILED${off}"
                ERRORCODE=21
    else
                echo "[`date +"%Y-%m-%d %H:%M:%S"`][LOGICAL_RESTORE][DATA][OK][DB=${db}] Data Restore for ${db} SUCCEED!!" >> ${RESTORELOGFILE}
                echo "${grn}[`date +"%Y-%m-%d %H:%M:%S"`][LOGICAL_RESTORE][DATA][OK][DB=${db}] Data Restore for ${db} SUCCEED!!${off}"
    fi
    if [[ -f ${db}.routines.sql.gz ]]; then
		echo "${yel}[`date +"%Y-%m-%d %H:%M:%S"`][LOGICAL_RESTORE][ROUTTRIG][INFO][DB=${db}] Restoring Routines for schema :${off}${cyn}${db}${off}"
		echo "[`date +"%Y-%m-%d %H:%M:%S"`][LOGICAL_RESTORE][ROUTTRIG][INFO][DB=${db}] Restoring Routines for schema :${db}" >> ${RESTORELOGFILE}
		zcat ${db}.routines.sql.gz | mysql ${db}
		if [[ $? -ne 0 ]]; then
	                echo "[`date +"%Y-%m-%d %H:%M:%S"`][LOGICAL_RESTORE][ROUTTRIG][ERROR][DB=${db}] Routines Restore for ${db} FAILED" >> ${RESTORELOGFILE}
	                echo "${yel}[`date +"%Y-%m-%d %H:%M:%S"`][LOGICAL_RESTORE][ROUTTRIG][ERROR][DB=${db}] Routines Restore for ${db} FAILED${off}"
	                ERRORCODE=21
	    else
	                echo "[`date +"%Y-%m-%d %H:%M:%S"`][LOGICAL_RESTORE][ROUTTRIG][OK][DB=${db}] Routines Restore for ${db} SUCCEED!!" >> ${RESTORELOGFILE}
	                echo "${grn}[`date +"%Y-%m-%d %H:%M:%S"`][LOGICAL_RESTORE][ROUTTRIG][OK][DB=${db}] Routines Tables Restore for ${db} SUCCEED!!${off}"
	    fi
	else 
		echo "${yel}[`date +"%Y-%m-%d %H:%M:%S"`][LOGICAL_RESTORE][ROUTTRIG][INFO][DB=${db}] No triggers and/or Routines to restore for schema : ${off}${cyn}${db}${off}"
		echo "[`date +"%Y-%m-%d %H:%M:%S"`][LOGICAL_RESTORE][ROUTTRIG][INFO][DB=${db}] No triggers and/or Routines to restore for schema : ${db}" >> ${RESTORELOGFILE}
	fi

done 