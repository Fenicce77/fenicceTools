#!/bin/bash
MYSQLPID=`ps -ef | grep mysqld |grep -v grep |grep -v exporter | awk '{print $2}'`
echo "[`date +"%Y-%m-%d %H:%M:%S"]` Starting monitoring mysql/mysqltmp files.."
while true; do 
	NFILEOPEN=`ls -lhrt /proc/${MYSQLPID}/fd/ | grep "/mysql/mysqltmp" | sort -u | wc -l`
	echo "[`date +"%Y-%m-%d %H:%M:%S"]`Files Opened in mysql/mysqltmp:${NFILEOPEN} ... Waiting 5s"
	sleep 5s
	echo ""
done
