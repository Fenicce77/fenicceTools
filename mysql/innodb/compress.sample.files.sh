#!/usr/bin/bash
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

# Error input parameters ouput function
function error_param_msg (){

        echo -e " Usage command line : ${0} [config_file]"
        echo -e " Example            : ${0} /root/scripts/sh/compress.sample.files.cnf"
}

# Log message function
function log_message(){

        LABEL=$2
        MESSAGE_HEAD_LINE="[`date +"%Y-%m-%d %H:%M:%S"`]${LABEL}"


        case "$3" in
                'OK' ) MESSAGE_TYPE="${grn}${MESSAGE_HEAD_LINE}[OK]"
                           MESSAGE_TYPE_LOG="${MESSAGE_HEAD_LINE}[OK]"
                        ;;
                'INFO' ) MESSAGE_TYPE="${blu}${MESSAGE_HEAD_LINE}[INFO]"
                           MESSAGE_TYPE_LOG="${MESSAGE_HEAD_LINE}[INFO]"
                        ;;
                'ERROR' ) MESSAGE_TYPE="${red}${MESSAGE_HEAD_LINE}[ERROR]"
                                  MESSAGE_TYPE_LOG="${MESSAGE_HEAD_LINE}[ERROR]"
                        ;;
                'WARNING' ) MESSAGE_TYPE="${yel}${MESSAGE_HEAD_LINE}[WARN]"
                                        MESSAGE_TYPE_LOG="${MESSAGE_HEAD_LINE}[WARN]"
                        ;;
                
        esac

        case "$1" in
                'STANDARD' ) MESSAGE_HEAD="${MESSAGE_TYPE}"
                        ;;
                'LOG' ) MESSAGE_HEAD="${MESSAGE_TYPE_LOG}"
                        ;;
        esac
        MSG=$4

        #MESSAGE_HEAD="${MESSAGE_TYPE}"
        echo "${MESSAGE_HEAD} ${MSG} ${off}"
}

# Input parameters check and verification
if [[ $# -eq 0 ]]; then

        MSG=`log_message "LOG" "[PARAMETERS]" "ERROR" "NO PARAMETERS PROVIDED !!"`
        echo "${MSG}"
        error_param_msg
        ERRORCODE=-10
        exit ${ERRORCODE}
fi

CONFFILE=$1
LOGDIR=`cat ${CONFFILE} | grep 'logdir' | awk -F'=' '{print $2}'`
DAILYTOCOMPRESSRET=`cat ${CONFFILE} | grep 'dailytocompressret' | awk -F'=' '{print $2}'`
TOREMOVALRETENTION=`cat ${CONFFILE} | grep 'toremovalretention' | awk -F'=' '{print $2}'`

COMPRESSERR=0

MSG=`log_message "LOG" "[PRE-START]" "INFO" "Starting Compress and Removing Innodb Engine Status Files Stored in : ${LOGDIR} !!"`
echo "${MSG}"

MSG=`log_message "LOG" "[PRE-START]" "INFO" "Source Files Retention to Compress       : ${DAILYTOCOMPRESSRET} days "`
echo "${MSG}"
MSG=`log_message "LOG" "[PRE-START]" "INFO" "Compressed Directories Retention to Keep : ${TOREMOVALRETENTION} days "`
echo "${MSG}"

MSG=`log_message "LOG" "[START]" "INFO" "Removing Files Compressed dayli directories older than ${TOREMOVALRETENTION} days !!"`
echo "${MSG}"
MSG=`log_message "LOG" "[FILES][COMPRESSED][REMOVAL][LIST]" "INFO" "List of Compressed Files older than ${TOREMOVALRETENTION} days to remove: !!"`
echo "${MSG}"

find ${LOGDIR} -type f -mtime +${TOREMOVALRETENTION} -name '*.tar.gz'

MSG=`log_message "LOG" "[FILES][COMPRESSED][REMOVAL]" "INFO" "Removing Compressed Dayli Files Directories older than ${TOREMOVALRETENTION} days : !!"`
echo "${MSG}"

find ${LOGDIR} -type f -mtime +${TOREMOVALRETENTION} -name '*.tar.gz' -exec rm -f {} \;
if [ $? -eq 0 ]; then 

	MSG=`log_message "LOG" "[FILES][COMPRESSED][REMOVAL]" "OK" "Removing Compressed Files older than ${TOREMOVALRETENTION} days REMOVED!!"`
	echo "${MSG}"
else

	MSG=`log_message "LOG" "[FILES][COMPRESSED][REMOVAL]" "ERROR" "Removing Compressed Files older than ${TOREMOVALRETENTION} days REMOVED!!"`
	echo "${MSG}"
fi


MSG=`log_message "LOG" "[FILES][COMPRESSED][REMOVAL]" "INFO" "Removing Compressed Files than ${TOREMOVALRETENTION} days"`
echo "${MSG}"

MSG=`log_message "LOG" "[FILES][DIRS][REMOVAL]" "INFO" "Removing Directories for Files Older than ${TOREMOVALRETENTION} days"`
echo "${MSG}"

for d in `find ${LOGDIR} -type d -mtime +${TOREMOVALRETENTION}`
do

	MSG=`log_message "LOG" "[DIR][COMPRESSED][REMOVAL]" "INFO" "Removing Directories for Files Older than ${TOREMOVALRETENTION} days"`
	echo "${MSG}"

	rm -r ${d}
	if [ $? -eq 0 ]; then 
		MSG=`log_message "LOG" "[DIR][COMPRESSED][REMOVAL]" "OK" " ${d} REMOVED!!"`
		echo "${MSG}"
	else
		MSG=`log_message "LOG" "[DIR][COMPRESSED][REMOVAL]" "ERROR" " ${d} NOT REMOVED!!"`
		echo "${MSG}"	

	fi
done

for dir in `find ${LOGDIR} -type d -mtime +${DAILYTOCOMPRESSRET}`
do
	for f in `find ${dir} -name '*.sample'`
	do
		pigz -k -3 -p2 ${f}
		
		if [ $? -eq 0 ];then 
			fname="${f}.gz"
			ls $fname > /dev/null 2>&1
			if [ $? -eq 0 ]; then

					MSG=`log_message "LOG" "[FILE][DAILY][SOURCE][COMPRESS]" "OK" " ${f} Succesfully compressed to : ${fname}"`
					echo "${MSG}"

					MSG=`log_message "LOG" "[FILE][DAILY][SOURCE][COMPRESS][REMOVAL]" "INFO" " Removing uncompressed source file ${f}"`
					echo "${MSG}"
					rm -f ${f}
					if [ $? -eq 0 ]; then 

						MSG=`log_message "LOG" "[FILE][DAILY][SOURCE][COMPRESS][DELETE]" "OK" " ${f} file succesfully removed !!"`
						echo "${MSG}"

					else

						MSG=`log_message "LOG" "[FILE][DAILY][SOURCE][COMPRESS][DELETE]" "WARNING" " ${f}  NOT removed !!"`
						echo "${MSG}"

						COMPRESSERR=2
					fi
			fi
		else
			COMPRESSERR=$?
			MSG=`log_message "LOG" "[FILE][DAILY][SOURCE][COMPRESS]" "WARNING" " ${f}  NOT compressed !!"`
			echo "${MSG}"
		fi
	done
	if [ $COMPRESSERR -eq 0 ];then

		MSG=`log_message "LOG" "[FILE][DAILY][SOURCE][COMPRESS]" "OK" " Files Succesfully compressed in ${dir} !!"`
		echo "${MSG}"

		MSG=`log_message "LOG" "[FILE][DAILY][SOURCE][REMOVAL]" "INFO" " Removing uncompressed files ${dir}"`
		echo "${MSG}"
		#rm -f ${dir}/*.sample
		#if [ $? -eq 0 ];then 
		#	echo "Uncompressed sample files succesfully removed"
			# echo "Compressing daily sampling directory ${dir} to ${dir}.tar.gz "
			# echo "[`date +"%Y-%m-%d %H:%M:%S"]`[COMPRESS][INFO] Compressing daily sampling directory ${dir} to ${dir}.tar.gz"
			MSG=`log_message "LOG" "[DIR][DAILY][COMPRESS][SOURCE]" "INFO" " Compressing daily sampling directory ${dir} to ${dir}.tar.gz"`
			echo "${MSG}"

			tar cvfz ${dir}.tar.gz ${dir}/* > /dev/null 2>&1
			if [ $? -eq 0 ];then
				ls ${dir}.tar.gz > /dev/null 2>&1
				if [ $? -eq 0 ];then

					MSG=`log_message "LOG" "[DIR][DAILY][COMPRESS][SOURCE]" "OK" " Daily sampling directory ${dir} Succesfully compressed in ${dir}.tar.gz"`
					echo "${MSG}"

					MSG=`log_message "LOG" "[DIR][DAILY][SOURCE][REMOVAL]" "INFO" " Removing uncompressed files in ${dir}"`
					echo "${MSG}"

					rm -rf ${dir}
					if [ $? -eq 0 ];then

						MSG=`log_message "LOG" "[DIR][DAILY][SOURCE][REMOVAL]" "OK" " Uncompressed files in ${dir} Succesfully Removed"`
						echo "${MSG}"

					fi
				fi
			fi
		#fi
	else

		MSG=`log_message "LOG" "[FILE][DAILY][SOURCE][COMPRESS]" "ERROR" " Files in ${dir} not compressed. Please check files !! "`
		echo "${MSG}"
	fi
done

