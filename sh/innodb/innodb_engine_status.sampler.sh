#!/bin/bash
#
#       takes a sample of SHOW ENGINE INNODB STATUS every 10 seconds and stores it in files
#       under $SAMPLEDIR for later use
#       (run it in background with nohup; user should have password in dot file)
#       get_reply routine only needed to drain the mysql output pipe otherwise script will block when it fills up
#
#SAMPLEDIR=$HOME/sampling/data/$(hostname)

# Error input parameters ouput function
function error_param_msg (){

        echo -e " Usage command line : ${0} [instance_name]"
        echo -e " Example            : ${0} ke-primary"
#        echo -e " Example            : ${0} /root/scripts/mysql/.conf/ke-primary.cnf"
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

INSTANCENAME=$1
ROOTPATHNAME=$(dirname "$0")
CONFFILE="${ROOTPATHNAME}/.conf/${INSTANCENAME}.cnf"


HOST=`cat ${CONFFILE} | grep 'host' | awk -F'=' '{print $2}'`
PORT=`cat ${CONFFILE} | grep 'port' | awk -F'=' '{print $2}'`

echo "INSTANCE : ${INSTANCENAME}"
echo "DIRNAME: ${ROOTPATHNAME}"
echo "CONFFILE : ${CONFFILE}"
echo "HOST:PORT : ${HOST}:${PORT}"
#exit 0
startdatetime=`date +"%Y-%m-%d %H:%M:%S"`
#SAMPLEBASEDIR="/data/rmateos/betika_africa"
SAMPLEBASEDIR="/data/innodb"
SAMPLEDIR="${SAMPLEBASEDIR}/${HOST}_${PORT}"
LOCKFILE="${SAMPLEDIR}/lockfile.lock"
RUNPID=$$


if [ -f "$LOCKFILE" ]; then
        RUNNINGPID=`cat $LOCKFILE`
        MSG=`log_message "STANDARD" "[AUDIT]" "WARNING" "InnoDB Status Log Process is already running with PID=${RUNNINGPID}"`
        echo "${MSG}"
        ERRORCODE=1
        exit $ERRORCODE
else
	if [ ! -d $SAMPLEDIR ]; then
		mkdir -p $SAMPLEDIR
	fi
        echo "${RUNPID}" > $LOCKFILE
        MSG=`log_message "STANDARD" "[AUDIT][RUN]" "INFO" "InnoDB Status Log Process Started at ${startdatetime} with PID=${RUNPID}"`
        echo "${MSG}"
fi


while true
do

        folder=$SAMPLEDIR/$(date +%Y%m%d)
        samplefile=$(date +%Y%m%d_%H)
        [ ! -d $folder ] && mkdir -p $folder
#        echo "show engine innodb status\G" | mysql --login-path=innodb_monitor --host=${HOST} -P${PORT} -ANrs >> $folder/$samplefile.sample
	echo "show engine innodb status\G" | mysql --defaults-file=${CONFFILE} -ANrs >> $folder/$samplefile.sample
        sleep 5
done
