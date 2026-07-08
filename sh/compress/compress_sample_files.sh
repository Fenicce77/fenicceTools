#!/bin/sh
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

HOSTNAME=$(hostname)
RETENTION=7 # NOTE : pass as parameter
SAMPLEBASEDIR="/mysql/mysqlbackup/innodb/data"
SAMPLEHOSTDIR="${SAMPLEBASEDIR}/${HOSTNAME}"
LOGFILE="/var/log/compress_sample_files.log"
YEAR=$(date +%Y)
MONTH=$(date +%m)
# for dir in `find /mysql/mysqlbackup/sampling/data/$(hostname)/$(date +%Y)/$(date +%m)/ -type d -mtime +9`; do
COMPRESSERR=0
if [[ -z $1 ]] 
then 
	echo "${red}[`date +"%Y-%m-%d %H:%M:%S"`][WARN] No Retention parameter provided, default ${RETENTION} days will be used ${off}"
else
	RETENTION=$1
	echo "${red}[`date +"%Y-%m-%d %H:%M:%S"`][INFO] Sampling Retention parameter provided : ${RETENTION} days will be used ${off}"
fi

DELETERETENTION=`expr ${RETENTION} + 15`
echo "[`date +"%Y-%m-%d %H:%M:%S"]`[START] STARTING INNODB STATUS TRACKING FILES COMPRESSION" >> $LOGFILE
echo "[`date +"%Y-%m-%d %H:%M:%S"]`[START] STARTING INNODB STATUS TRACKING FILES COMPRESSION" 
echo "[`date +"%Y-%m-%d %H:%M:%S"]`[INFO] Sampling Retention to Apply : ${RETENTION} days" >> $LOGFILE
echo "[`date +"%Y-%m-%d %H:%M:%S"]`[INFO] Sampling Retention to Apply : ${RETENTION} days" 
echo "[`date +"%Y-%m-%d %H:%M:%S"]`[INFO] Checking Monthly Sampling Directories older than ${RETENTION} days" >> $LOGFILE
echo "[`date +"%Y-%m-%d %H:%M:%S"]`[INFO] Checking Monthly Sampling Directories older than ${RETENTION} days" 
echo "[`date +"%Y-%m-%d %H:%M:%S"]`[INFO][CLEAN] Checking compressed files older than ${DELETERETENTION} days for removing" >> $LOGFILE
echo "[`date +"%Y-%m-%d %H:%M:%S"]`[INFO][CLEAN] Checking compressed files older than ${DELETERETENTION} days for removing"
for f in `find $SAMPLEHOSTDIR -type f -name "*.tar.gz" -mtime +${DELETERETENTION}`
do
	echo "[`date +"%Y-%m-%d %H:%M:%S"]`[INFO][CLEAN] * File to Remove : ${f}" >> $LOGFILE
	echo "[`date +"%Y-%m-%d %H:%M:%S"]`[INFO][CLEAN] * File to Remove : ${f}"
	rm -f ${f} 
	if [ $? -eq 0 ];then
		echo "[`date +"%Y-%m-%d %H:%M:%S"]`[INFO][CLEAN][OK] ${f} SUCCESFULLY DELETED!!" >> $LOGFILE
		echo "[`date +"%Y-%m-%d %H:%M:%S"]`[INFO][CLEAN][${grn}OK${off}] ${f} ${grn}SUCCESFULLY DELETED${off}!! "
	fi
done
#echo "[`date +"%Y-%m-%d %H:%M:%S"]`[INFO] Compressing Tracking files older than ${RETENTION} days stored in : ${SAMPLEHOSTDIR}/${YEAR}/${MONTH}/" >> $LOGFILE
#echo "[`date +"%Y-%m-%d %H:%M:%S"]`[INFO] Compressing Tracking files older than ${RETENTION} days stored in : ${SAMPLEHOSTDIR}/${MONTH}/" >> $LOGFILE
echo "[`date +"%Y-%m-%d %H:%M:%S"]`[INFO] Compressing Tracking files older than ${RETENTION} days stored in : ${SAMPLEHOSTDIR}/" >> $LOGFILE
#for dir in `find $SAMPLEHOSTDIR/$YEAR/$MONTH/ -type d -mtime +${RETENTION}`
#for dir in `find $SAMPLEHOSTDIR/$MONTH -type d -mtime +${RETENTION}`
for dir in `find $SAMPLEHOSTDIR -type d -mtime +${RETENTION}`
do
	#tar --use-compress-program="pigz -k -3 -p 2" -cf $dir.tar.gz $dir/
	for f in `ls ${dir}`
	do
		pigz -k -3 -p2 ${dir}/${f}
		
		if [ $? -eq 0 ];then 
			fname="${dir}/${f}.gz"
			ls $fname > /dev/null 2>&1
			if [ $? -eq 0 ]; then
					echo "${grn} ${dir}/${f} Succesfully compressed to ${fname} ${off}"
					echo "[`date +"%Y-%m-%d %H:%M:%S"]`[COMPRESS][OK] ${dir}/${f} Succesfully compressed to : ${fname} " >> $LOGFILE
					echo "${cyn} Removing uncompressed source file ${f} ${off}"					
					echo "[`date +"%Y-%m-%d %H:%M:%S"]`[INFO]Removing uncompressed source file ${dir}/${f}" >> $LOGFILE
					rm -f ${dir}/${f}
					if [ $? -eq 0 ]; then 
						echo "${grn} ${dir}/${f} file succesfully removed${off}"
						echo "[`date +"%Y-%m-%d %H:%M:%S"]`[DELETE][OK]Removing uncompressed source file">> $LOGFILE
					else
						echo "${grn} ${dir}/${f} NOT removed${off}"
						echo "[`date +"%Y-%m-%d %H:%M:%S"]`[DELETE][WARN]${dir}/${f} NOT removed">> $LOGFILE
						COMPRESSERR=2
					fi
			fi
		else
			COMPRESSERR=$?
			echo "${red} ${dir}/${f} not compressed!!${off}"
			echo "[`date +"%Y-%m-%d %H:%M:%S"]`[COMPRESS][WARN] ${dir}/${f} not compressed!!">> $LOGFILE
		fi
	done
	if [ $COMPRESSERR -eq 0 ];then
		echo "${grn} Files succesfully compressed in ${dir}${off}"
		echo "[`date +"%Y-%m-%d %H:%M:%S"]`[COMPRESS][OK] Files Succesfully compressed in ${dir}">> $LOGFILE
		#echo "${cyn} Removing uncompressed files ${dir}${off}"
		#rm -f ${dir}/*.sample
		#if [ $? -eq 0 ];then 
		#	echo "${grn}Uncompressed sample files succesfully removed${off}"
			echo "${cyn}Compressing dayli sampling directory ${dir} to ${dir}.tar.gz ${off}"
			echo "[`date +"%Y-%m-%d %H:%M:%S"]`[COMPRESS][INFO] Compressing dayli sampling directory ${dir} to ${dir}.tar.gz">> $LOGFILE
			tar cfz ${dir}.tar.gz ${dir}/ > /dev/null 2>&1
			if [ $? -eq 0 ];then
				ls ${dir}.tar.gz > /dev/null 2>&1
				if [ $? -eq 0 ];then
					echo "${grn} ${dir} Succesfully compressed in ${dir}.tar.gz ${off}"
					echo "[`date +"%Y-%m-%d %H:%M:%S"]`[COMPRESS][OK] Dayli sampling directory ${dir} Succesfully compressed in ${dir}.tar.gz">> $LOGFILE
					echo "${grn} ${dir} Removing uncompressed ${dir} ${off}"
					echo "[`date +"%Y-%m-%d %H:%M:%S"]`[REMOVE][INFO] Removing uncompressed files in ${dir}"
					rm -rf ${dir}
					if [ $? -eq 0 ];then
						echo "${grn} ${dir} Succesfully Removed ${dir} ${off}"
						echo "[`date +"%Y-%m-%d %H:%M:%S"]`[REMOVE][OK] Uncompressed files in ${dir} Succesfully Removed">> $LOGFILE
					fi
				fi
			fi
		#fi
	else
		echo "${red} Files in ${dir} not compressed. Please check files${off}"
		echo "[`date +"%Y-%m-%d %H:%M:%S"]`[REMOVE][ERROR] Files in ${dir} not compressed. Please check files">> $LOGFILE
	fi
done

## NOTE : Add check for removing compressed directories regarding a retention policy. For example, keep only last month
