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

#for i in {1..50}; 
while (true); 
do 
	echo " ========================================================================== "
	echo " [`date +"%Y-%m-%d %H:%M:%S"]` Checking current MySQL Cluster status...     "
	echo " [`date +"%Y-%m-%d %H:%M:%S"]` MySQL Servers..."
	echo "select * from mysql_servers;" | mysql -t
	echo " [`date +"%Y-%m-%d %H:%M:%S"]` MySQL Runtime Servers..."
	echo "select * from runtime_mysql_servers;" | mysql -t
	echo "Sleeping 5s"
	sleep 5s
done
