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
# -- * $1 : array with
# -- * > js Initialization Path Name
# -- * >  ReplicaSet Name
# -- * >  Primary Node Name

function_rs_initiate(){
	declare -a arr=("${@}")
	jspathfile=${arr[0]}
    rsname=${arr[1]}
    rsprimary="${arr[2]}"
    rsnode2=`echo "$rsprimary"|sed "s/node[01]\+$/node02/"`
    rsnode3=`echo "$rsprimary"|sed "s/node[01]\+$/node03/"`
	cat << EOF > $jspathfile
// init_replica_set.js

// Define the replica set configuration object.
const replicaSetConfig = {
    // The name of the replica set. 
    _id: "${rsname}",

    // An array of objects, where each object defines a member of the replica set.
    members: [
        { _id: 0, host: "${rsprimary}.betika.private:27017" },
        { _id: 1, host: "${rsnode2}.betika.private:27017" },
        { _id: 2, host: "${rsnode3}.betika.private:27017" }
    ]
};

// Initiate the replica set with the specified configuration.
// This command should only be run once on a single node of the cluster.
try {
    const result = rs.initiate(replicaSetConfig);
    printjson(result);
} catch (e) {
    print("Error during replica set initiation: " + e);
    // If the replica set is already initialized, this will throw an error.
    // We can check the current status as a fallback.
    print("Checking current status...");
    printjson(rs.status());
}
EOF
}

RSSIZE="3"
DEFAULTRSPRIMARY=`hostname`
# Hostnames substitution for remaining nodes
BASE_DIR="/data"
MONGO_LOG_DIR="${BASE_DIR}/log/mongod"
MONGO_LOG_FILE_PATH="${MONGO_LOG_DIR}/mongod.log"

RSSECONDARY1=`hostname|sed "s/node[01]\+$/node02/"`
RSSECONDARY2=`hostname|sed "s/node[01]\+$/node03/"`
MONGOSHBINPATH=`which mongosh`

MONGO_CONF_DIR="/etc/mongod"
MONGOD_CONFFILE="${MONGO_CONF_DIR}/mongod.conf"
MONGOD_CONFFILE_BKP="${MONGO_CONF_DIR}/mongod.conf.bkp"
MONGOD_CONFFILE_TMP="${MONGO_CONF_DIR}/mongod.conf.tmp"
MONGOUSRSETUPCONN="${MONGO_CONF_DIR}/.mongo-users.js"
MONGOD_RS_JSFILE="${MONGO_CONF_DIR}/rsinitiate.js"

MONGODB_RS_NAME=`grep 'replSetName' ${MONGOD_CONFFILE}|awk -F':' '{print $2}'|sed 's/\"//g'|tr -d '[[:blank:]]'`
MONGODB_KEYFILE=`grep 'keyFile' ${MONGOD_CONFFILE}|awk -F':' '{print $2}'|sed 's/\"//g'|tr -d '[[:blank:]]'`
MONGOADMINUSER=`grep 'auth' ${MONGOUSRSETUPCONN}|awk -F '(' '{print $2}'|awk -F',' '{print $1}'`
MONGOADMINPWD=`grep 'auth' ${MONGOUSRSETUPCONN}|awk -F '(' '{print $2}'|awk -F',' '{print $2}'|awk -F ')' '{print $1}'`

MONGODB="admin"
MONGOAUTHDB="admin"
echo "admin user: ${MONGOADMINUSER} / pwd: ${MONGOADMINPWD}"
arrayrsinit=( $MONGOD_RS_JSFILE $MONGODB_RS_NAME $DEFAULTRSPRIMARY )

MSG=`log_message "STANDARD" "[MONGODB][REPLICASET]" "INFO" "Generating Replicaset Configuration"`
MSGRS1=`log_message "STANDARD" "[MONGODB][REPLICASET][CONFIG][DATA][RSNAME] " "INFO" "- ReplicaSet Name : ${MONGODB_RS_NAME}"`
MSGRS2=`log_message "STANDARD" "[MONGODB][REPLICASET][CONFIG][DATA][MEMBERS]" "INFO" "- ReplicaSet Members : Primary : ${DEFAULTRSPRIMARY}.betika.private "`
MSGRS3=`log_message "STANDARD" "[MONGODB][REPLICASET][CONFIG][DATA][MEMBERS]" "INFO" "- ReplicaSet Members : Secondary : ${RSSECONDARY1}.betika.private  "`
MSGRS4=`log_message "STANDARD" "[MONGODB][REPLICASET][CONFIG][DATA][MEMBERS]" "INFO" "- ReplicaSet Members : Secondary : ${RSSECONDARY2}.betika.private  "`
echo "${MSG}"
echo "${MSGRS1}"
echo "${MSGRS2}"
echo "${MSGRS3}"
echo "${MSGRS4}"
function_rs_initiate ${arrayrsinit[@]}

# Update mongod configuration file 
# Remove commented lines related to keyFile and replication
# --- Step 1 Remove # from keyFile and replication sections 
NEWMONGODCONFMSG1=`log_message "STANDARD" "[MONGODB][REPLICASET][CONFIG][MONGODCONF][NEW]" "OK" "Updating ${MONGOD_CONFFILE} for uncommenting lines related to keyFile and replication setup"`
echo "${NEWMONGODCONFMSG1}"
cat ${MONGOD_CONFFILE} |sed 's/\#  keyFile:/  keyFile:/g' |sed 's/\#replication:/replication:/g'|sed 's/\#  replSetName:/  replSetName:/g' > ${MONGOD_CONFFILE_TMP}
if [[ $? -eq 0 ]]; then
    if [[ -s ${MONGOD_CONFFILE_TMP} ]]; then
        NEWMONGODCONFMSGOK1=`log_message "STANDARD" "[MONGODB][REPLICASET][CONFIG][MONGODCONF][NEW]" "OK" "New mongod.conf created -> ${MONGOD_CONFFILE_TMP}!!"`
        NEWMONGODCONFMSGOK2=`log_message "STANDARD" "[MONGODB][REPLICASET][CONFIG][MONGODCONF][BACKUP]" "INFO" "New mongod.conf created -> ${MONGOD_CONFFILE_TMP}!!"`
        NEWMONGODCONFMSG2=`log_message "STANDARD" "[MONGODB][REPLICASET][CONFIG][MONGODCONF][BACKUP]" "INFO" "Renaming ${MONGOD_CONFFILE} to ${MONGOD_CONFFILE_BKP} and ${MONGOD_CONFFILE_TMP} to ${MONGOD_CONFFILE}"`
        NEWMONGODCONFMSGOK3=`log_message "STANDARD" "[MONGODB][REPLICASET][CONFIG][MONGODCONF][BACKUP]" "OK" "${MONGOD_CONFFILE} renamed to ${MONGOD_CONFFILE_BKP}"`
        NEWMONGODCONFMSGOK4=`log_message "STANDARD" "[MONGODB][REPLICASET][CONFIG][MONGODCONF][BACKUP]" "OK" "${MONGOD_CONFFILE_TMP} renamed to ${MONGOD_CONFFILE}"`
        #grep '\#  keyFile:\|\#replication:' ${MONGOD_CONFFILE_TMP}
        #if [[ $? -eq 0 ]]; then
        #    NEWMONGODCONFMSGERR1=`log_message "STANDARD" "[MONGODB][REPLICASET][CONFIG][MONGODCONF][NEW]" "ERROR" "keyFile and replication lines did not uncommented"`
        #    NEWMONGODCONFMSGERR2=`log_message "STANDARD" "[MONGODB][REPLICASET][CONFIG][MONGODCONF][NEW]" "ERROR" "New configuration file not successfully generated!! Exiting. Please check temporal file generated : ${MONGOD_CONFFILE_TMP}"`
        #    echo "${NEWMONGODCONFMSGERR1}"
        #    echo "${NEWMONGODCONFMSGERR2}"
        #    exit -3
        #else
                       
        echo "${NEWMONGODCONFMSGOK1}"
        echo "${NEWMONGODCONFMSGOK2}"
        echo "${NEWMONGODCONFMSG2}"
        mv ${MONGOD_CONFFILE} ${MONGOD_CONFFILE_BKP}
        if [[ $? -eq 0 ]]; then 
            mv ${MONGOD_CONFFILE_TMP} ${MONGOD_CONFFILE}
            if [[ $? -eq 0 ]]; then
                echo "${NEWMONGODCONFMSGOK3}"
                echo "${NEWMONGODCONFMSGOK4}"
            fi
        else
            NEWMONGODCONFMSGERR=`log_message "STANDARD" "[MONGODB][REPLICASET][CONFIG][MONGODCONF][NEW]" "ERROR" "Configuration file could not be rotated. Please check .conf files in ${MONGO_CONF_DIR}. Exiting"`
            echo "${NEWMONGODCONFMSGERR}"
            exiting -5
        fi
        #fi        
    fi
else
    NEWMONGODCONFMSGERR=`log_message "STANDARD" "[MONGODB][REPLICASET][CONFIG][MONGODCONF][NEW]" "ERROR" "Substitution from ${MONGOD_CONFFILE} to ${MONGOD_CONFFILE_TMP} reported error. Exiting"`
    echo "${NEWMONGODCONFMSGERR}"
    exit -2
fi
# -- Step 2 Restart mongod service for running new configuration
systemctl restart mongod
if [[ $? -ne 0 ]]; then
    MONGODSERVICESTARERR=`log_message "STANDARD" "[MONGODB][REPLICASET][SERVICE][RESTART]" "ERROR" "Mongo Service Restart Reported errors. Check errors mongod output log : ${MONGO_LOG_FILE_PATH} and systemctl status for mongod Service. Exiting"`
    echo "${MONGODSERVICESTARTERR}"
    exit -4
else
    MONGODSERVICESTARTOK=`log_message "STANDARD" "[MONGODB][REPLICASET][SERVICE][RESTART]" "OK" "Mongo Service Successfully Restarted and Reconfigured !!"`
fi
# Verification
# JS configuration file creation check
if [[ -e ${MONGOD_RS_JSFILE} ]]; then
	# JS configuration file should not be empty
	if [[ ! -s ${MONGOD_RS_JSFILE} ]]; then
		ERRORMSG=`log_message "STANDARD" "[MONGODB][REPLICASET][CONFIG][EMPTY]" "ERROR" " Replicaset JS Configuration File not succesfuly generated please check Parameters provided!!"`
		echo "${ERRORMSG}"
		exit -1
	else
		MSG=`log_message "STANDARD" "[MONGODB][REPLICASET]" "OK" " Replicaset JS Configuration File Created -> ${MONGOD_RS_JSFILE}"`
		echo "${MSG}"
		OUTPUTCLI="${MONGOSHBINPATH} --file ${MONGOD_RS_JSFILE} --authenticationDatabase=${MONGOAUTHDB} -u ${MONGOADMINUSER} -p XXXXXXXX ${MONGODB}"
		RUNMSG=`log_message "STANDARD" "[MONGODB][REPLICASET][SETUP]" "INFO" " Running ReplicaSet configuration JS script against mongo: ${OUTPUTCLI} "`
		echo "${RUNMSG}"
		${MONGOSHBINPATH} --file ${MONGOD_RS_JSFILE} --authenticationDatabase=${MONGOAUTHDB} -u ${MONGOADMINUSER} -p ${MONGOADMINPWD} ${MONGODB}
		if [[ $? -eq 0 ]]; then
			MSGOK=`log_message "STANDARD" "[MONGODB][REPLICASET][SETUP]" "OK" " ¡¡ReplicaSet : ${MONGODB_RS_NAME} Successfully configured, you can roll the rest of nodes!!"`
			echo "${MSGOK}"
		else
			MSGOK=`log_message "STANDARD" "[MONGODB][REPLICASET][SETUP]" "ERROR" " ¡¡ReplicaSet : ${MONGODB_RS_NAME} Not configured. Please check mongo log:"`
			echo "${MSGOK}"
		fi
	fi
fi

exit 0