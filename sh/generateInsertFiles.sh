#!/usr/local/bin/bash

ROWSTOINSERT=100 # default value

LOADSET=$1
ROWSTOINSERT=$LOADSET
#for i in { 1..$1};do
#for i  (( i=1; i<=$ROWSTOINSERT; i++ ));
i=1
while [[ i -le ${ROWSTOINSERT} ]];
do
	host=`hostname`
	qrynew="INSERT INTO t1 (K,host,hostfrom,created_ts) VALUES (${i},@@hostname,'${host}',now());"
#	qrytrans="${qrytrans}${qrynew}"
	#if [[ $i -eq 500 ]]; then
		#statements
#	fulltrans="${qryBegin}${qrytrans}${qryCommit}"
	echo $qrynew
	i=$[$i+1]
	#echo $fulltrans | mysql test
	#fi
done