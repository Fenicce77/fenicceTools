#!/opt/homebrew/bin/bash
source betika/mongodb/conf/develrsgcss/devel-gcssmongodb01-node03.conf
MONGOSHBINPATH=`which mongosh`

${MONGOSHBINPATH} --host="${MONGOHOST}" --authenticationDatabase=${ADMINDB} -u ${MONGOADMINUSR} --password="${MONGOADMINPAS}" ${ADMINDB} 
