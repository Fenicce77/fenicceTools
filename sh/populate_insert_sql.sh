#!/bin/sh
# CREATE TABLE IF NOT EXISTS `t1` (
#   `id` int(11) NOT NULL AUTO_INCREMENT,
#   `k` int(11) NOT NULL DEFAULT '0',
#   `host` char(120) NOT NULL DEFAULT '',
#   `hostfrom` char(120) NOT NULL DEFAULT '',
#   `created_ts` timestamp default current_timestamp,
#   `update_ts` timestamp default current_timestamp on update current_timestamp,
#   PRIMARY KEY (`id`),
#   KEY `idx_internal_id` (`k`),
#   KEY `idx_internal_id_created` (`k`,`created_ts`),
#   KEY `idx_internal_id_updated` (`k`,`update_ts`),
#   KEY `idx_host` (`host`),
#   KEY `idx_hostfrom` (`hostfrom`),
#   KEY `idx_k_host` (`k`,`host`),
#   KEY `idx_k_hostfrom` (`k`,`hostfrom`)
# ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

#qryBegin="BEGIN;"
#qryCommit="COMMIT;"
qrytrans=""
DEFMAXINS=1000
MYSERVER=$1
MYUSER="rmateos"
MYPASS="MyB0nham2k21"
if [ -z "$2" ]; then 
	NUMINS=${DEFMAXINS}
	echo "No insertion account limit provided, Default value : ${NUMINS} will be used "
	exit 1
else
	NUMINS=$2
	echo "Insertion account limit provided : ${NUMINS} "
fi
#exit 0
#INITROWSINTABLE=`echo "select count(*) as total from t1;"|mysql -u${MYUSER} -h $MYSERVER -A feniccedb -N -p${MYPASS}`
#echo "[`date +"%Y-%m-%d %H:%M:%S"]` Initial Rows in table : ${INITROWSINTABLE}"
for i in $(seq 1 $NUMINS);do
	host=`hostname`
	echo "INSERT INTO t1 (K,host,hostfrom,created_ts) VALUES (${i},@@hostname,'${MYSERVER}',now());" >> /tmp/kk.sql
	qrytrans="${qrytrans}${qrynew}"
	#if [[ $i -eq 500 ]]; then
		#statements
	#fulltrans="${qryBegin}${qrytrans}${qryCommit}"
	fulltrans="${qrytrans}"
	#echo $fulltrans | mysql test
	#fi
done
fulltrans="${qryBegin}${qrytrans}${qryCommit}"
#echo $fulltrans
#echo $fulltrans | mysql -u${MYUSER} -h $MYSERVER -A feniccedb -N -p${MYPASS}
#ROWSINTABLE=`echo "select count(*) as total from t1;"|mysql -u${MYUSER} -h $MYSERVER -A feniccedb -N -p${MYPASS}`
#echo "[`date +"%Y-%m-%d %H:%M:%S"]` Final Rows in table : ${ROWSINTABLE}"

