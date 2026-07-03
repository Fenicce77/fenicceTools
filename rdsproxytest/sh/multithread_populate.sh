#!/bin/bash
#
# Multithread populate script 
PID=`echo $$`

#./populate2.sh -f rdsproxy.cnf -b 1000 -c 200

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

THREADSNUM=6
THREADSRUN=0
THREADS=0
CHECKDELAY=10
BASEDIR="/home/ec2-user/rdsproxytests"
LOGDIR="${BASEDIR}/log"
POPULATEBINPATH="${BASEDIR}/populate.sh"
MYCNF="${BASEDIR}/rdsproxy.cnf"
BATCHSIZEBASE=1000

# threads : array for storing pid related to each populate thread started
# threads array reset
unset threads
declare -a threads=()

if [[ ! -d ${LOGDIR} ]]; then
	echo -e "${yel}[`date +"%Y-%m-%d %H:%M:%S"`][MULTITHREAD][INFO]${LOGDIR} not exists...will be created${off}"
	mkdir -p ${LOGDIR}

	if [[ $? -eq 0 ]]; then
		echo -e "${yel}[`date +"%Y-%m-%d %H:%M:%S"`][MULTITHREAD][INFO]${off}${grn}[OK]${LOGDIR} Created!!${off}"
	fi
fi

echo -e "${yel}[`date +"%Y-%m-%d %H:%M:%S"`][MULTITHREAD][INFO] Running ${THREADSNUM} threads for populating test table!!${off}"

echo "[`date +"%Y-%m-%d %H:%M:%S"`][MULTITHREAD][INFO][DEBUG] Checking Threads array...."
echo " Original Array State: ${threads[@]}"
#exit -1
start_index=1
BATCHSIZE=$BATCHSIZEBASE
# Threads Array initialisation
# set to 0 on each pos
for (( i = $start_index; i <= ${THREADSNUM}; i++ ));
do
        threads[$i]=0
        #echo ${threads[$i]}
	    #statements
	    BATCHSIZE=$((${BATCHSIZEBASE}*$i))
	    CHUNKSIZE=$((${BATCHSIZE}/10))
	    echo -e "${cyn}[`date +"%Y-%m-%d %H:%M:%S"`][MULTITHREAD][INFO][RUN] Running populate Thread Number #1 - Batch Size : ${BATCHSIZE} (insertions) / Chunk Size :   ${CHUNKSIZE} (chunk of queries per transaction)${off}"
	    /bin/bash ${POPULATEBINPATH} -f ${MYCNF} -b ${BATCHSIZE} -c ${CHUNKSIZE} > ${LOGDIR}/${!}.out 2>&1 &
		if [[ ! -z ${!} ]]; then
			TH1=${!}
			threads[$i]=${!}
			THREADS=`expr ${THREADSRUN} + 1`
			THREADSRUN=${THREADS}
			echo -e "${grn}[`date +"%Y-%m-%d %H:%M:%S"`][MULTITHREAD][INFO][RUN]${off}${grn}[TH#${i}][TH#${i}PID=${threads[$i]}] Running populate Thread#${i} with PID=${threads[$i]} !!${off}"
			echo -e "${blu}[`date +"%Y-%m-%d %H:%M:%S"`][MULTITHREAD][INFO][CHECK] THREADS RUNNING : ${THREADSRUN} !!${off}"
		fi
 done


checknum=1
while [[ ${THREADSRUN} -gt 0 ]]; do
    echo -e "${mag}[`date +"%Y-%m-%d %H:%M:%S"`][MULTITHREAD][INFO][CHECK#${checknum}] Checking Current Threads Status!!${off}"
    for (( i=1; i<=${THREADSNUM}; i++ ))
    do
    	TH=${threads[i]}
    	RUNNING=${THREADSRUN}
    	echo -e "${cyn}[`date +"%Y-%m-%d %H:%M:%S"`][MULTITHREAD][INFO][CHECK][TH=${TH}] Checking if ${TH} is Running!!${off}"
    	j=1
    	while [ $j -lt 100 ]
    	do
    		THCHECK=`ps -aux | grep "${POPULATEBINPATH}" | grep ${TH} | grep -vi "sleep" | grep -vi "mysql" |grep -v grep | awk '{print $2}' | head -1`
    		if [[ ${THCHECK} -ne ${TH} ]]; then
    			j=`expr ${j} + 1`
    			RUNNING=0
    		else
    			j=100
    			RUNNING=1
    		fi
    		sleep 0.5
    	done
    	if [[ ${RUNNING} -eq 0 ]]; then
    		unset threads[$i]
            THREADS=`expr ${THREADSRUN} - 1`
            THREADSRUN=${THREADS}
            echo -e "${yel}[`date +"%Y-%m-%d %H:%M:%S"`][MULTITHREAD][INFO][RUN][FINISHED][TH=${TH}] Thread with PID=${TH} Already Finished!!${off} ${yel}THREADS RUNNING : ${THREADSRUN} ${off}"
        else

            echo -e "${mag}[`date +"%Y-%m-%d %H:%M:%S"`][MULTITHREAD][INFO][RUN][TH=${TH}] Thread with PID=${TH} Still Running!!${off}"
        fi
        #index=`expr ${index} + 1`
    done

    checknum=`expr ${checknum} + 1`

    if [[ ${THREADSRUN} -eq 0 ]]; then
    	echo -e "${grn}[`date +"%Y-%m-%d %H:%M:%S"`][MULTITHREAD][INFO][END] Multithread Program Succesfully Finished!!${off}"
    	exit 0
	fi

    echo -e "${mag}[`date +"%Y-%m-%d %H:%M:%S"`][MULTITHREAD][INFO][CHECK][WAIT] Waiting ${CHECKDELAY}s for next Check!!${off}"
    sleep ${CHECKDELAY}
    
done
