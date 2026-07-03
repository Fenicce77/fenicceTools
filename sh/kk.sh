#!/bin/bash
#aws rds describe-db-log-files --db-instance-identifier prod-jucy-site-db --profile jucy --region us-east-1 --output text | awk -v day="$yesterday" '/mysql-slowquery.log.day./ {print $3}' |sort -k3 -t. |while read logfile; do echo ${logfile}; done
# fnamehead="mysql-slowquery.log.`date +"%Y-%m-%d" -d "1 day ago"`"

yesterday=`date +%Y-%m-%d -d '1 day ago'` 
aws rds describe-db-log-files --db-instance-identifier prod-jucy-site-db --profile jucy --region us-east-1 --output text | awk -v day="$yesterday" '/mysql-slowquery.log.{print $day}/ {print $3}' |sort -k3 -t. |while read logfile; do echo ${logfile}; done
#aws rds describe-db-log-files --db-instance-identifier prod-jucy-site-db --profile jucy --region us-east-1 --output text | awk -v day="$yesterday" '/mysql-slowquery.log.$day./ {print $3}' |sort -k3 -t. |while read logfile; do echo ${logfile}; done
