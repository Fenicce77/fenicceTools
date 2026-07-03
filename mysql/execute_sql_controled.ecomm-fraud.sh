#!/bin/bash
# #########################################################################################
# GENERAL CONSTANTS AND VARIABLES
#
# CONSTANTS
# Color Vars
blk=$(tput blink)
bld=$(tput bold)             # Bold
red=${bld}$(tput setaf 1)    # Red
grn=${bld}$(tput setaf 2)    # Green
yel=${bld}$(tput setaf 3)    # Yellow
blu=${bld}$(tput setaf 4)    # Blue
mag=${bld}$(tput setaf 5)    # Purple
cyn=${bld}$(tput setaf 6)    # Cyan
wht=${bld}$(tput setaf 7)    # White
off=$(tput sgr0)             # Text reset

# DB Connection parameters file
#MYCONF="rmateos.my.cnf"
#MYCNF="/root/scripts/mysql/db.my.cnf"
#socket=$3
# MySQL Binary Path
MYSQLBIN=`which mysql`
# Wait time
WAITTIME=5
# #######################################################################################################################################
# Parameters 
#  * $1 = infile  : File with lines to be processed
#  * $2 = bulsize : Bulk size. Amount of lines to be processed per batch
# #######################################################################################################################################
 
# File to be processed
infile=$1
# Num lines to be processed by batch
bulksize=$2
# Full account of lines to be processed
fullsize=`wc -l $infile`
# ######################################################################
# ### Load Average calculation regarding the amount of core_cpus of the current machine
# core cpu accounting
numcorecpus=`grep 'cpu cores' /proc/cpuinfo |wc -l`
# Top Load Average Allowed = numcorecpus x 100
LATop=`echo "$numcorecpus*100"|bc`
# Max Load Average Limit = LATop*0.8 (80% of the top LA) => In order to avoid reaching the alerts tresholds Max LA will be at top 80% 
maxLAtmp=`echo "$LATop*0.8"|bc`
maxLA=`echo "${maxLAtmp%.*}"`

# Function for checking load average
checkSrvLoad(){
    currLA=`uptime | cut -d, -f4 | cut -d: -f2 | sed 's/\.//g' | sed 's/ //g'`
    while [ $currLA -gt $maxLA ]; do
        echo -e "${yel}[`date +"%Y-%m-%d %H:%M:%S"`][WARNING]Current Load Average(LA*100) : ${currLA} too high (over $maxLA allowed); skipping execution. Sleeping 60s for server load decrease...${off}"
        echo -e "[`date +"%Y-%m-%d %H:%M:%S"`][WARING]Current Load Average(LA*100) : ${currLA} too high (over $maxLA allowed); skipping execution. Sleeping 60s for server load decrease...">>$LOGFILE
        sleep 60s
        currLA=`uptime | cut -d, -f4 | cut -d: -f2 | sed 's/\.//g' | sed 's/ //g'`
    done
}

# ######################################################################
# ### Log Files
# Log File
LOGFILE=$1".log"
# tmp file for executing by batches
tmpfile=$1."tmp"
# track file for storing last line processed
trackfile=$1".trackfile"

# Generamos el fichero sql que usaremos para las cargas
nlines=`cat $infile | wc -l`

echo ">>>>>>>>>>>>>> Process started at : `date` <<<<<<<<<<<<<<<<<<<<<">>$LOGFILE
# Creamos el fichero de seguimiento de lectura
# Tracking file generation 
if [ ! -f ${trackfile} ]; then
        echo "0" > $trackfile
        echo "`date`: Starting load process..."  >> $LOGFILE
else
        echo "`date`: Resuming load process..."  >> $LOGFILE
fi

endpos=`cat $trackfile`
lastpos=$endpos


while [[ $endpos -lt $nlines ]]; 
do

    checkSrvLoad

    blocksize=`echo $nlines-$lastpos | bc`
    endpos=`echo $lastpos+$bulksize | bc`

    echo " - blocksize = $blocksize" >> $LOGFILE
    echo " - bulksize  = $bulksize" >> $LOGFILE
    echo " - endpos    = $endpos" >> $LOGFILE
    
    echo "last number line read from $infile : $lastpos">>$LOGFILE
#    echo "bulksize= $bulksize"
#    echo "endpos = $endpos"

    if [ $blocksize -lt $bulksize ];then
	echo "$blocksize lines remain in file!! Bulksize changed to $blocksize" >> $LOGFILE 
	endpos=`echo $lastpos+$blocksize | bc`
	
	tail -n $blocksize $infile > $tmpfile
	#endpos=`echo $lastpos+$blocksize | bc`
    else
    	echo "bulksize= $bulksize" >> $LOGFILE
	endpos=`echo $lastpos+$bulksize | bc`
	
    #rm $tmpfile # no deberia hacer falta...
  	head -n $endpos $infile | tail -n $bulksize > $tmpfile
    fi
    
    #cat $tmpfile | mysql --defaults-file=${MYCNF} 2>&1 >> $1".out"
    #cat $tmpfile | mysql  >> $1".out"

    # code to be executed controled
    #cat $tmpfile | mysql --defaults-file=${MYCNF} 2>&1 >> $1".out"
    #cat $tmpfile | mysql  >> $1".out"
    for DEVICEID in `cat $tmpfile`
    do
        echo "${cyn}[`date +"%Y-%m-%d %H:%M:%S"`]${off}device_id for processing : ${DEVICEID}"
        echo "[`date +"%Y-%m-%d %H:%M:%S"`]device_id for processing : ${DEVICEID}" >> $LOGFILE
        #echo "CALL ECOMM_21123_CREATE_BACKUP_DEVICE_AND_BROWSER('${DEVICEID}') | mysql -A bigpaw 2>ECOMM_21123_CREATE_BACKUP_DEVICE_AND_BROWSER.err"
        # #time echo "ECOMM_21123_CREATE_BACKUP_DEVICE_AND_BROWSER(${DEVICEID})" 
        time echo "CALL ECOMM_21123_CREATE_BACKUP_DEVICE_AND_BROWSER('${DEVICEID}')" | mysql -A bigpaw 2>ECOMM_21123_CREATE_BACKUP_DEVICE_AND_BROWSER.err.tmp
         EXIT=$?
        if [ $EXIT -ne 0 ]; then
            cat ECOMM_21123_CREATE_BACKUP_DEVICE_AND_BROWSER.err.tmp >> ECOMM_21123_CREATE_BACKUP_DEVICE_AND_BROWSER.err
	        MYSQLERRMSG=`cat ECOMM_21123_CREATE_BACKUP_DEVICE_AND_BROWSER.err.tmp`
            echo -e "${red}[`date +"%Y-%m-%d %H:%M:%S"`]${off}[ERROR]Error executing queries/commands in MySQL instance.  Aborting...."
            echo -e "[`date +"%Y-%m-%d %H:%M:%S"`][ERROR]Error executing queries/commands in MySQL instance.  Aborting...." >> $LOGFILE
            echo -e "${red}[`date +"%Y-%m-%d %H:%M:%S"`]${off}[ERROR][MYSQLERROR]${MYSQLERRMSG}"
            echo -e "[`date +"%Y-%m-%d %H:%M:%S"`][ERROR][MYSQLERROR]${MYSQLERRMSG}" >> $LOGFILE
            #exit -1
        else            
        #     #time echo "ECOMM_21123_CREATE_BACKUP_USED_DEVICE(${DEVICEID})"
            echo -e "${cyn}[`date +"%Y-%m-%d %H:%M:%S"`]${off}${grn}[OK]CALL ECOMM_21123_CREATE_BACKUP_DEVICE_AND_BROWSER('${DEVICEID}') Executed succesfully!!${off}"
        #    echo "CALL ECOMM_21123_CREATE_BACKUP_USED_DEVICE('${DEVICEID}') | mysql -A bigpaw 2>ECOMM_21123_CREATE_BACKUP_USED_DEVICE.err"
            time echo "CALL ECOMM_21123_CREATE_BACKUP_USED_DEVICE('${DEVICEID}')" | mysql -A bigpaw 2>ECOMM_21123_CREATE_BACKUP_USED_DEVICE.err.tmp
            EXIT=$?
            if [ $EXIT -ne 0 ]; then
                cat ECOMM_21123_CREATE_BACKUP_USED_DEVICE.err.tmp >> ECOMM_21123_CREATE_BACKUP_USED_DEVICE.err
                MYSQLERRMSG2=`cat ECOMM_21123_CREATE_BACKUP_USED_DEVICE.err.tmp`
                echo -e "${red}[`date +"%Y-%m-%d %H:%M:%S"`]${off}[ERROR]Error executing queries/commands in MySQL instance.  Aborting...."
                echo -e "[`date +"%Y-%m-%d %H:%M:%S"`][ERROR]Error executing queries/commands in MySQL instance.  Aborting...." >> $LOGFILE
                echo -e "${red}[`date +"%Y-%m-%d %H:%M:%S"`]${off}[ERROR][MYSQLERROR]${MYSQLERRMSG2}"
                echo -e "[`date +"%Y-%m-%d %H:%M:%S"`][ERROR][MYSQLERROR]${MYSQLERRMSG2}" >> $LOGFILE
                #exit -1
             else
                echo -e "${cyn}[`date +"%Y-%m-%d %H:%M:%S"`]${off}${grn}[OK]CALL ECOMM_21123_CREATE_BACKUP_USED_DEVICE('${DEVICEID}') Executed succesfully!!${off}"
                echo -e "[`date +"%Y-%m-%d %H:%M:%S"`][OK]CALL ECOMM_21123_CREATE_BACKUP_USED_DEVICE('${DEVICEID}') Executed succesfully!!${off}" >> $LOGFILE
             fi
        fi
        checkSrvLoad
    done
 
    echo $endpos > $trackfile
    lastpos=$endpos
    if [ $lastpos -lt $nlines ];then
        echo -e "[`date +"%Y-%m-%d %H:%M:%S"`]$endpos lines processed out of $nlines" >>$LOGFILE
        echo -e "${mag}[`date +"%Y-%m-%d %H:%M:%S"`]${off}$endpos lines processed out of $nlines" >>$LOGFILE
    	echo "Sleeping 10s.." >> $LOGFILE
    	sleep 10s
	   end=1
    else
	   end=0
    fi
done

if [ $end -eq 0 ];then
	echo "${mag}[`date +"%Y-%m-%d %H:%M:%S"`]${off}${grn}File succesfully processed!!${off}" 
    echo "[`date +"%Y-%m-%d %H:%M:%S"`]File succesfully processed!!" >> $LOGFILE
	echo ">>>>>>>>>>>>>> Process terminated succesfully at : `date` <<<<<<<<<<<<<<<<<<<" >>$LOGFILE
    echo "${grn}>>>>>>>>>>>>>> Process terminated succesfully at : `date` <<<<<<<<<<<<<<<<<<<${off}"
	mv $trackfile $trackile".old"
fi
