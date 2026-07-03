#!/bin/bash
# Coor Vars
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

# DB Connection parameters file
MYCONF=$1
# MySQL Binary Path
MYSQLBIN=`which mysql`
# MySQL DB servername to connect
DBSERVERNAME=$2
# echo -e "\nEnter the ${cyn}MySQL DB Server Name (or IP)${off} for Innodb Buffer Pool Load Status [ENTER]:"
# read DBSERVERNAME;
# if [[ -z ${DBSERVERNAME} ]] 
# then 
# 	echo -e "${red}Checking all servers known!!${off}\n\n"
# fi

# Main Program
# Querying Status Variable Innodb_buffer_pool_load_status and returns corresponding information 
while true; do
		#COMPLETED=`echo "SHOW STATUS LIKE 'Innodb_buffer_pool_load_status';" | $MYSQLBIN --defaults-extra-file=${MYCONF} -h ${DBSERVERNAME} -N | grep -ci "load completed"`
		COMPLETED=`echo "SHOW STATUS LIKE 'Innodb_buffer_pool_load_status';" | $MYSQLBIN --login-path=prod | grep -ci "load completed"`
		if [ ${COMPLETED} -eq 1 ];then
			#LOADED=`echo "SHOW STATUS LIKE 'Innodb_buffer_pool_load_status';" | $MYSQLBIN --defaults-extra-file=${MYCONF} -h ${DBSERVERNAME} -N | awk '{print $2" "$3" "$4" "$5" "$6" "$7" "$8}'`
			LOADED=`echo "SHOW STATUS LIKE 'Innodb_buffer_pool_load_status';" | $MYSQLBIN --login-path=prod | awk '{print $2" "$3" "$4" "$5" "$6" "$7" "$8}'`
			echo "${mag}[`date +"%Y-%m-%d %H:%M:%S"`]${off} ${grn}Innodb ${LOADED} !!${off}"
			exit 0
		else
			#VAL=`echo "SHOW STATUS LIKE 'Innodb_buffer_pool_load_status';" | $MYSQLBIN --defaults-extra-file=${MYCONF} -h ${DBSERVERNAME} -N | awk '{print $3}'`
			VAL=`echo "SHOW STATUS LIKE 'Innodb_buffer_pool_load_status';" | $MYSQLBIN --login-path=prod | awk '{print $3}'`
			PCT=$(echo "scale=2; ${VAL}*100" | bc)
			echo "${mag}[`date +"%Y-%m-%d %H:%M:%S"`]${off} ${yel}Innodb Buffer Pool Warmup...${red}$VAL${off} pages ${red}${PCT}%${off}"
		fi
	echo "${cyn}Slepping 5s...${off}"
	echo ""
	sleep 5s
done