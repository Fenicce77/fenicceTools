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

# Messages output LABELS
OKMESGLABEL="${grn}[PT-KILL][INFO]${off}"
OKMESGLABEL="${grn}[PT-KILL][OK]${off}"
WARNMSGLABEL="${yel}[PT-KILL][WARNING]${off}"
ERRORMSGLABEL="${red}[PT-KILL][ERROR]${off}"

# BINPATH
GREPBINPATH=`which grep`
PTKILLBINPATH=`which pt-kill`


if [[ -z $1 ]] 
then 
	echo -e "${red}[PT-KILL][ERROR]${off} NO CONFIGURATION FILE WITH CONNECTION PARAMATERS PROVIDED."
	exit -1
fi

# configuration file
MYCONFILE=$1

# Configuration Parameters
#PTKILLUSR=`grep "myuser" ${MYCONFILE} |  awk -F'=' '{print $2}'| sed 's/"//g'`
#PTKILLPWD=`grep "mypass" ${MYCONFILE} |  awk -F'=' '{print $2}'| sed 's/"//g'`
PTKILLDIR=`grep "ptrootdir" ${MYCONFILE} |  awk -F'=' '{print $2}'| sed 's/"//g'`
PTKILLCNF=`grep "ptkillcnf" ${MYCONFILE} |  awk -F'=' '{print $2}'| sed 's/"//g'`

# Logfile
PTKILLLOGFILE="${PTKILLDIR}/pt-kill.log"
# PIDFILE
PIDKILLFILE="${PTKILLDIR}/ptkill.pid"

while [[ ! -f "${PIDFILE}" ]]; do
	# pid verification
	PIDFROMFILE=`cat ${PIDFILE}`
	ps -ef | ${GREPBINPATH} "${PIDFROMFILE}" | ${GREPBINPATH} -v grep 
	if [[ $? -eq 0 ]]; then
		echo "[`date +"%Y-%m-%d %H:%M:%S"`]${OKMESGLABEL} ${grn}PID FOUND AND VERIFIED!! PT-KILL process Running...Nothing to do${off}"
		exit 0
	else
		echo "[`date +"%Y-%m-%d %H:%M:%S"`]${ERRORMSGLABEL} ${red}PID NOT FOUND!! PT-KILL process STOP${off}"
		echo "[`date +"%Y-%m-%d %H:%M:%S"`]${WARNMSGLABEL} ${mag}Running pt-kill${off}"

		${PTKILLBINPATH} --config ${PTKILLCNF} --pid=${PIDFILE} --print --log=${PTKILLLOGFILE}

	fi
done
