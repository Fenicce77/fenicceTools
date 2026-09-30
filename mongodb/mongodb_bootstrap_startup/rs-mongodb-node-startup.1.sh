#!/bin/bash
# ReplicaSet configuration
# This script must be ran in primary node for generating the full rs.initiate command for remaining nodes 02,03
# --- Colors output variables ---
set -e
set -x

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

# -- Log message function
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

# --- Function for generating ReplicaSet inititate js file
# -- Paramaters info :
# -- * $1 : rs.initiate js output file path name
# -- * $2 : ReplicaSet Name
# -- * $3 : P
# -- * $4 : mongod output log file path name
# -- * $5 : mongod pid file path name
# -- * $6 : authorization keyFile full path name
# -- * $7 : replicaSet Name
function_rs_initiate(){
	declare -a arr=("${@}")
	jspathfile=${arr[0]}
	rsname=${arr[1]}
	rsprimary=${arr[2]}
	rsnode2=`echo "$rsprimary"|sed "s/node[01]\+$/node02/"`
	rsnode3=`echo "$rsprimary"|sed "s/node[01]\+$/node03/"`
	cat << EOF > $1
rs.initiate(
{
   _id: "${rsname}",
   version: 1,
   members: [
      { _id: 0, host : "${rsprimary}.betika.private:27017" },
      { _id: 1, host : "${rsnode2}.betika.private:27017" },
      { _id: 2, host : "${rsnode3}.betika.private:27017" }
   ]
}
)
EOF
}



RSSIZE="3"
DEFAULTRSPRIMARY=`hostname`
# Hostnames substitution for remaining nodes

RSSECONDARY1=`hostname|sed "s/node[01]\+$/node${02}/"`
RSSECONDARY2=`hostname|sed "s/node[01]\+$/node${03}/"`

MONGO_CONF_DIR="/etc/mongod"
MONGOD_CONFFILE="${MONGO_CONF_DIR}/mongod.conf"
MONGOD_RS_JSFILE="${MONGO_CONF_DIR}/rsinitiate.js"
MONGODB_RS_NAME=`grep 'replSetName' ${MONGOD_CONFFILE}|awk -F':' '{print $2}'|sed 's/\"//g'|tr -d '[[:blank:]]'`

arrayrsinit=( $MONGOD_RS_JSFILE $MONGODB_RS_NAME $DEFAULTRSPRIMARY )

function_rs_initiate ${arrayrsinit[@]}
ls -lh $MONGOD_RS_JSFILE

exit 0
