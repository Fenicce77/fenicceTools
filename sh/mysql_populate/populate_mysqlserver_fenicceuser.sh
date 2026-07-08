#!/opt/homebrew/bin/bash
# Table creation mysql8 vesion
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
#
# Mysql 5.7 version
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
# ) ENGINE=InnoDB DEFAULT CHARSET=utf8 COLLATE=utf8_general_ci;
MYSQLBINPATH=`which mysql`

qryBegin="BEGIN;"
qryCommit="COMMIT;"
qrytrans=""
DEFMAXINS=1000
LOGINPATH=$1
#MYUSER="fenicce"
#MYPASS="f3n1ccEP4Sswd"
#if [ $# -eq 0 ]; then 
#	NUMINS=${DEFMAXINS}
#	echo "No insertion account limit provided, Default value : ${NUMINS} will be used "
#else
#	NUMINS=$1
#fi


#INITROWSINTABLE=`echo "select count(*) as total from t1;"|mysql -u${MYUSER} -h $MYSERVER -A feniccedb -N -p${MYPASS}`
INITROWSINTABLE=`echo "select count(*) as total from t1;"| ${MYSQLBINPATH} --login-path=${LOGINPATH} -A feniccedb -N`
echo "[`date +"%Y-%m-%d %H:%M:%S"]` Initial Rows in table : ${INITROWSINTABLE}"
for i in {1..1000};do
	host=`hostname`
	qrynew="INSERT INTO t1 (K,host,hostfrom,created_ts) VALUES (${i},@@hostname,'${MYSERVER}',now());"
	qrytrans="${qrytrans}${qrynew}"
	#if [[ $i -eq 500 ]]; then
		#statements
	fulltrans="${qryBegin}${qrytrans}${qryCommit}"
	#echo $fulltrans | mysql test
	#fi
done
fulltrans="${qryBegin}${qrytrans}${qryCommit}"
#echo $fulltrans
# echo $fulltrans | mysql -u${MYUSER} -h $MYSERVER -A feniccedb -N -p${MYPASS}
# ROWSINTABLE=`echo "select count(*) as total from t1;"|mysql -u${MYUSER} -h $MYSERVER -A feniccedb -N -p${MYPASS}`
echo $fulltrans | ${MYSQLBINPATH} --login-path=${LOGINPATH} -A feniccedb -N
ROWSINTABLE=`echo "select count(*) as total from t1;"|${MYSQLBINPATH} --login-path=${LOGINPATH} -A feniccedb -N`
echo "[`date +"%Y-%m-%d %H:%M:%S"]` Final Rows in table : ${ROWSINTABLE}"

