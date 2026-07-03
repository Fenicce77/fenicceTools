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

# configuration file
MYCONFILE="./myremotedump.cnf"
# Configuration Parameters
MYBKPUSR=`grep "myuser" ${MYCONFILE} |  awk -F'=' '{print $2}'| sed 's/"//g'`
MYBKPPWD=`grep "mypass" ${MYCONFILE} |  awk -F'=' '{print $2}'| sed 's/"//g'`
MYSRV=`grep "myserver" ${MYCONFILE} |  awk -F'=' '{print $2}'| sed 's/"//g'`
DUMPDIRROOT=`grep "myrootdumpdir" ${MYCONFILE} |  awk -F'=' '{print $2}'| sed 's/"//g'`
# Backup directories
# Root dir
#DUMPDIRROOT="/mysql/mysqlbackup"

# Main logical dir
DUMPBASEDIR="${DUMPDIRROOT}/mysqldumpbackup"
DUMPDBBASEDIR="${DUMPDBBASEDIR}/DBs"
BACKUPLOGDIR="${DUMPBASEDIR}/log"
BACKUPLOGFILE="${BACKUPLOGDIR}/MySQLBkpLogical.log"
# PIDFILE
LOCKFILE="/tmp/MySQLBkpLogicalPID.lock"
ERRORCODE=0
DBLISTQRY="select schema_name from information_schema.SCHEMATA where schema_name not in ('mysql','information_schema','sys','performance_schema');"
ONLYSCHEMADUMPPARAMS="--no-data --skip-triggers --single-transaction --set-gtid-purged=OFF"
ONLYDATADUMPPARAMS="--no-create-info --skip-triggers --single-transaction --set-gtid-purged=OFF"
ONLYROUTINESDUMPPARAMS="--routines --no-create-info --no-data --single-transaction --set-gtid-purged=OFF"

# Check Base Dump Directory is created, if not created it
if [ ! -d ${DUMPBASEDIR} ]; then
	mkdir -p ${DUMPBASEDIR} && mkdir -p ${BACKUPLOGDIR}
	DIROUTLOG="[`date +"%Y-%m-%d %H:%M:%S"`][BACKUP][FULL][INFO] Base Backup Directory : ${DUMPBASEDIR} and ${BACKUPLOGDIR} created!!"
	DIROU="${grn}[`date +"%Y-%m-%d %H:%M:%S"`][BACKUP][FULL][INFO] Base Backup Directory : ${DUMPBASEDIR} and ${BACKUPLOGDIR} created!!${off}"
else
	DIROUTLOG="[`date +"%Y-%m-%d %H:%M:%S"`][BACKUP][FULL][INFO] Base Backup Directory ${DUMPBASEDIR} already exists !!"
	DIROUT="[`date +"%Y-%m-%d %H:%M:%S"`][BACKUP][FULL][INFO] Base Backup Directory ${DUMPBASEDIR} already exists !!${off}"
fi

echo " ============================================================================================================================================ " >> ${BACKUPLOGFILE}
echo " ============================================================================================================================================ "
echo "[`date +"%Y-%m-%d %H:%M:%S"`][BACKUP][FULL][INFO] Starting Logical Backup at : `date +"%Y-%m-%d %H:%M:%S"`]" >> ${BACKUPLOGFILE}
echo "${cyn}[`date +"%Y-%m-%d %H:%M:%S"`][BACKUP][FULL][INFO] Starting Logical Backup at : `date +"%Y-%m-%d %H:%M:%S"`]${off}"
echo ${DIROUT}
echo ${DIROUTLOG} >> ${BACKUPLOGFILE}

# lockfile management. Check if other process is already running
if [ -f "$LOCKFILE" ];then
	RUNPID=`cat $BACKUPLOCKFILE`
	echo "[`date +"%Y-%m-%d %H:%M:%S"`][BACKUP][FULL][WARNING] A Backup Instance still running with PID=${RUNPID}" >> ${BACKUPLOGFILE}
	echo "${yel}[`date +"%Y-%m-%d %H:%M:%S"`][BACKUP][FULL][WARNING] A Backup Instance still running with PID=${RUNPID} ${off}" 
	echo "[`date +"%Y-%m-%d %H:%M:%S"`][BACKUP][FULL][WARNING] Please Check Processes running, kill or wait until it finished before run. " >> ${BACKUPLOGFILE}
	echo "${yel}[`date +"%Y-%m-%d %H:%M:%S"`][BACKUP][FULL][WARNING] Please Check Processes running, kill or wait until it finished before run. ${off}" 
	echo "[`date +"%Y-%m-%d %H:%M:%S"`][BACKUP][FULL][WARNING] Exiting" >> ${BACKUPLOGFILE}
	echo "${yel}[`date +"%Y-%m-%d %H:%M:%S"`][BACKUP][FULL][WARNING] Exiting${off}" 
	ERRORCODE=1
	exit $ERRORCODE
else
	# BackupPID
	RUNPID=$$
	echo "[`date +"%Y-%m-%d %H:%M:%S"`][BACKUP][FULL][INFO] No Backups running!! Backup Procedure PID file created. PID=${RUNPID}" >> ${BACKUPLOGFILE}
	echo "${grn}[`date +"%Y-%m-%d %H:%M:%S"`][BACKUP][FULL][INFO] No Backups running!! Backup Procedure PID file created. PID=${RUNPID} ${off}" 
	echo ${RUNPID} > $LOCKFILE
fi


# execute above query 
for DB in `echo ${DBLISTQRY} |mysql -N`; do
	DBBACKUPDIR="${DUMPDBBASEDIR}/${DB}"
	# Check Base Dump Directory is created, if not created it
	if [ ! -d ${DBBACKUPDIR} ]; then
		echo "[`date +"%Y-%m-%d %H:%M:%S"`][BACKUP][FULL][INFO][DB=${DB}] Backup Directory for schema ${DB} not exists. Creating ${DBBACKUPDIR} !!" >> ${BACKUPLOGFILE}
		echo "[`date +"%Y-%m-%d %H:%M:%S"`][BACKUP][FULL][INFO][DB=${DB}] Backup Directory for schema ${DB} not exists. Creating ${DBBACKUPDIR} !!"
		mkdir -p ${DBBACKUPDIR} 
		echo "[`date +"%Y-%m-%d %H:%M:%S"`][BACKUP][FULL][INFO][DB=${DB}] Backup Directory for schema ${DB} : ${DBBACKUPDIR} created!!" >> ${BACKUPLOGFILE}
		echo "[`date +"%Y-%m-%d %H:%M:%S"`][BACKUP][FULL][INFO][DB=${DB}] Backup Directory for schema ${DB} : ${DBBACKUPDIR} created!!"
	else
		echo "[`date +"%Y-%m-%d %H:%M:%S"`][BACKUP][FULL][INFO][DB=${DB}] Backup Directory for schema ${DB} : ${DBBACKUPDIR} already exists !!" >> ${BACKUPLOGFILE}
		echo "[`date +"%Y-%m-%d %H:%M:%S"`][BACKUP][FULL][INFO][DB=${DB}] Backup Directory for schema ${DB} : ${DBBACKUPDIR} already exists !!"
	fi
	# schema dump --->> no drop schema on backup output for restoring only tables for each one
	echo "[`date +"%Y-%m-%d %H:%M:%S"`][BACKUP][FULL][INFO][DB=${DB}] Dumping Schema Definition for ${DB} into ${DBBACKUPDIR}/${DB}.schema.sql.gz" >> ${BACKUPLOGFILE}
	echo "[`date +"%Y-%m-%d %H:%M:%S"`][BACKUP][FULL][INFO][DB=${DB}] Dumping Schema Definition for ${DB} into ${DBBACKUPDIR}/${DB}.schema.sql.gz"
	mysqldump $ONLYSCHEMADUMPPARAMS ${DB} | gzip > "${DBBACKUPDIR}/${DB}.schema.sql.gz"
	if [[ $? -ne 0 ]]; then
		echo "[`date +"%Y-%m-%d %H:%M:%S"`][BACKUP][FULL][ERROR][DB=${DB}] Dumping Schema Definition into ${DBBACKUPDIR}/${DB}.schema.sql.gz FAILED" >> ${BACKUPLOGFILE}
		echo "${yel}[`date +"%Y-%m-%d %H:%M:%S"`][BACKUP][FULL][ERROR][DB=${DB}] Dumping Schema Definition into ${DBBACKUPDIR}/${DB}.schema.sql.gz FAILED${off}"
		ERRORCODE=20
	else
		echo "[`date +"%Y-%m-%d %H:%M:%S"`][BACKUP][FULL][OK][DB=${DB}] Dumping Schema Definition into ${DBBACKUPDIR}/${DB}.schema.sql.gz SUCCEED!!" >> ${BACKUPLOGFILE}
		echo "${grn}[`date +"%Y-%m-%d %H:%M:%S"`][BACKUP][FULL][OK][DB=${DB}] Dumping Schema Definition into ${DBBACKUPDIR}/${DB}.schema.sql.gz SUCCEED!!${off}"
	fi
	# data dump 
	echo "[`date +"%Y-%m-%d %H:%M:%S"`][BACKUP][FULL][INFO][DB=${DB}] Dumping Schema Data for ${DB} into ${DBBACKUPDIR}/${DB}.data.sql.gz" >> ${BACKUPLOGFILE}
	echo "[`date +"%Y-%m-%d %H:%M:%S"`][BACKUP][FULL][INFO][DB=${DB}] Dumping Schema Data for ${DB} into ${DBBACKUPDIR}/${DB}.data.sql.gz"
	mysqldump $ONLYDATADUMPPARAMS ${DB} | gzip > "${DBBACKUPDIR}/${DB}.data.sql.gz"
	if [[ $? -ne 0 ]]; then
		echo "[`date +"%Y-%m-%d %H:%M:%S"`][BACKUP][FULL][ERROR][DB=${DB}] Dumping Data Definition into ${DBBACKUPDIR}/${DB}.data.sql.gz FAILED" >> ${BACKUPLOGFILE}
		echo "${yel}[`date +"%Y-%m-%d %H:%M:%S"`][BACKUP][FULL][ERROR][DB=${DB}] Dumping Data Definition into ${DBBACKUPDIR}/${DB}.data.sql.gz FAILED${off}"
		ERRORCODE=21
	else
		echo "[`date +"%Y-%m-%d %H:%M:%S"`][BACKUP][FULL][OK][DB=${DB}] Dumping Data Definition into ${DBBACKUPDIR}/${DB}.data.sql.gz SUCCEED!!" >> ${BACKUPLOGFILE}
		echo "${grn}[`date +"%Y-%m-%d %H:%M:%S"`][BACKUP][FULL][OK][DB=${DB}] Dumping Data Definition into ${DBBACKUPDIR}/${DB}.data.sql.gz SUCCEED!!${off}"
	fi
	# triggers dump
	DBROUTINESQRY="select count(routine_name) from information_schema.routines where ROUTINE_SCHEMA='${DB}';"
	DBTRIGGERSQRY="select count(trigger_name) from information_schema.triggers where TRIGGER_SCHEMA='${DB}';"
	ROUTCOUNT=`echo ${DBROUTINESQRY} | mysql -N`
	TRIGCOUNT=`echo ${DBTRIGGERSQRY} | mysql -N`
	RTACCOUNT=$(($ROUTCOUNT + $TRIGCOUNT))
	if [[ $RTACCOUNT -eq 0 ]]; then
		echo "[`date +"%Y-%m-%d %H:%M:%S"`][BACKUP][FULL][INFO][DB=${DB}] No triggers and/or Routines to be dumped in Schema : ${DB}" >> ${BACKUPLOGFILE}
		echo "${cyn}[`date +"%Y-%m-%d %H:%M:%S"`][BACKUP][FULL][INFO][DB=${DB}] No triggers and/or Routines to be dumped in Schema : ${DB}${off}"
	else
		echo "[`date +"%Y-%m-%d %H:%M:%S"`][BACKUP][FULL][INFO][DB=${DB}] Dumping Schema Routines for ${DB} into ${DBBACKUPDIR}/${DB}.routines.sql.gz" >> ${BACKUPLOGFILE}
		echo "${yel}[`date +"%Y-%m-%d %H:%M:%S"`][BACKUP][FULL][INFO][DB=${DB}] Dumping Schema Routines for ${DB} into ${DBBACKUPDIR}/${DB}.routines.sql.gz${off}"
		mysqldump $ONLYROUTINESDUMPPARAMS ${DB} | gzip > "${DBBACKUPDIR}/${DB}.routines.sql.gz"
		if [[ $? -ne 0 ]]; then
			echo "[`date +"%Y-%m-%d %H:%M:%S"`][BACKUP][FULL][ERROR][DB=${DB}] Dumping Routines Definition into ${DBBACKUPDIR}/${DB}.schema.sql.gz FAILED" >> ${BACKUPLOGFILE}
			echo "${yel}[`date +"%Y-%m-%d %H:%M:%S"`][BACKUP][FULL][ERROR][DB=${DB}] Dumping Routines Definition into ${DBBACKUPDIR}/${DB}.schema.sql.gz FAILED!! ${off}"
			ERRORCODE=22
		else
			echo "[`date +"%Y-%m-%d %H:%M:%S"`][BACKUP][FULL][OK][DB=${DB}] Dumping Routines Definition into ${DBBACKUPDIR}/${DB}.schema.sql.gz SUCCEED!!" >> ${BACKUPLOGFILE}
			echo "${grn}[`date +"%Y-%m-%d %H:%M:%S"`][BACKUP][FULL][OK][DB=${DB}] Dumping Routines Definition into ${DBBACKUPDIR}/${DB}.schema.sql.gz SUCCEED!! ${off}"

		fi
	fi
	echo " -------------------------------------------------------------------------------------------------------------------------------------------- " >> ${BACKUPLOGFILE}
	echo " -------------------------------------------------------------------------------------------------------------------------------------------- " 
done
if [[ $ERRORCODE -eq 0 ]]; then
	#statements
	echo "[`date +"%Y-%m-%d %H:%M:%S"`][BACKUP][FULL][INFO][FINISH][OK] Logical Backup finished successfully"  >> ${BACKUPLOGFILE}
	echo "${grn}[`date +"%Y-%m-%d %H:%M:%S"`][BACKUP][FULL][INFO][FINISH][OK] Logical Backup finished successfully !!${off}"
else
	echo "[`date +"%Y-%m-%d %H:%M:%S"`][BACKUP][FULL][INFO][FINISH][ERROR][ERRCODE=${ERRORCODE}] Logical Backup finished with warnings or errors"  >> ${BACKUPLOGFILE}
	echo "${red}[`date +"%Y-%m-%d %H:%M:%S"`][BACKUP][FULL][INFO][FINISH][ERROR][ERRCODE=${ERRORCODE}] Logical Backup with warnings or errors !!${off}"
fi
rm -f ${LOCKFILE}
echo "[`date +"%Y-%m-%d %H:%M:%S"`][BACKUP][FULL][INFO] Logical Backup Finished at : `date +"%Y-%m-%d %H:%M:%S"`]" >> ${BACKUPLOGFILE}
echo "${cyn}[`date +"%Y-%m-%d %H:%M:%S"`][BACKUP][FULL][INFO] Logical Backup Finished at : `date +"%Y-%m-%d %H:%M:%S"`]${off}"
exit $ERRORCODE
