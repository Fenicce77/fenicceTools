#!/bin/bash
#
blk=$(tput blink)
bld=$(tput bold)           	 # Bold
red=${bld}$(tput setaf 1)    # Red
grn=${bld}$(tput setaf 2)    # Green
yel=${bld}$(tput setaf 3)    # Yellow
blu=${bld}$(tput setaf 4)    # Blue
mag=${bld}$(tput setaf 5)    # Purple
cyn=${bld}$(tput setaf 6)    # Cyan
wht=${bld}$(tput setaf 7)    # White
off=$(tput sgr0)             # Text reset


echo "===================================================================================== "
echo "Enter the ${cyn}Open connections : User - Host - Account in MySQL DB Server ${off} (delay 5s)"
echo "===================================================================================== "
echo ""
while true
do
	echo "=========" 
	echo "[`date +"%Y-%m-%d %H:%M:%S"`]"
	echo "${blu}MySQL Connection Pool${off}"
	echo "SELECT * FROM stats.stats_mysql_connection_pool order by hostgroup;"| mysql -t
	echo "${blu}MySQL Server Ping Log${off}"
	echo "SELECT hostname,time_start_us,from_unixtime(time_start_us/1000/1000) as datetime, ping_success_time_us,ping_error FROM monitor.mysql_server_ping_log;"| mysql -t
	echo "Sleeping...next check in 3s"
	sleep 3s
done