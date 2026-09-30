#!/opt/homebrew/bin/bash

MONGOSHBINPATH=`which mongosh`
export MONGOADMINUSR="mongoAdmin"
export MONGOADMINPAS="HYVKzSy93gS0fwjroK0IOA=="
export ADMINDB="admin"
export MONGOHOST="gcssrs01/gcss-mongodbcluster01-node01.betika.private,gcss-mongodbcluster01-node02.betika.private,gcss-mongodbcluster01-node03.betika.private"

${MONGOSHBINPATH} --host="${MONGOHOST}" --authenticationDatabase=${ADMINDB} -u ${MONGOADMINUSR} --password="${MONGOADMINPAS}" ${ADMINDB}
