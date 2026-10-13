#!/opt/homebrew/bin/bash

MONGOSHBINPATH=`which mongosh`
export MONGOADMINUSR="mongouser"
export MONGOADMINPAS="mongopass"
export ADMINDB="admin"
export MONGOHOST="rsName/node01,node02,node03"

${MONGOSHBINPATH} --host="${MONGOHOST}" --authenticationDatabase=${ADMINDB} -u ${MONGOADMINUSR} --password="${MONGOADMINPAS}" ${ADMINDB}
