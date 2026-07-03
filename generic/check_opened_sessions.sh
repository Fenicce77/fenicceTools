#!/opt/homebrew/bin/bash
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
# New version for executing remotely from own laptop/pc it can be deploy inside server.
# For connection customization, please check parameters $1 and $2 for env and servername. 
# To execute inside server, uncomment the # labeled lines (42 and 43), comment 44 and 45 lines and setup MYCONF variable and edit the file with corresponding parameters

# Connection with --login-path option, previous steps
## Execute mysql_config_editor with related parameters for generating encripted connection credentials, as following example:
## Execute and type the password desired when required : $ mysql_config_editor set --login-path=prod --user=<dbusername> --password
#### >> NOTE: login-path=prod for me is the corresponding identifier for the connection; in the config file generated will add a section labeled like [prod]
## This creates the corresponding .mylogin.cnf in your home dir


# MySQL Binary Path
MYSQLBIN=`which mysql`
# Connection configuration file
#MYCONF="${HOME}/mysql/.my.cnf"
#ENV=$1
# Server name/ip to connect
MYCONFILE=$1

# Check DBSERVERNAME parameter
if [[ -z $1 ]] 
then 
	echo -e "${red}[ERROR][NO CONNECTION FILE] MySQL/MariaDB Connection file cannot be empty.${off}${yel}Please, check parameters command line${off}..."
	echo -e "${cyn} Usage command line : ./check_opened_sessions.sh [MYCONFILE_PATH] [NO DBSERVERNAME]MySQL DB Server cannot be empty.${off}"
	echo -e "${yel} Example            : ./check_opened_sessions.sh /path/myconf.cnf${off}\n"
	exit -1
else
#	 MYCONF="${HOME}/.myconffiles/${DBSERVERNAME}.cnf"
	MYCONF=${MYCONFILE}
fi

echo "===================================================================================== "
echo "${cyn}Open connections : User - DB - Host Connection Source - Total Account in MySQL DB Server ${off} (delay 5s)"
echo "===================================================================================== "
echo ""

while true
do
	echo "-- ${cyn}Connections in${off} ${mag}`hostname`${off} at ${grn}[`date +"%Y-%m-%d %H:%M:%S"]`${off}"
	echo "SELECT USER,DB,substring_index(substring_index(HOST,':',1),'.',4) as HH,count(*) as total FROM information_schema.PROCESSLIST WHERE user not in ('rmateos','proxysql_check') group by USER,DB,HH ORDER BY USER;" | $MYSQLBIN --defaults-file=${MYCONF} -t -A information_schema
	echo "SELECT count(*) as total FROM information_schema.PROCESSLIST;" | $MYSQLBIN --defaults-file=${MYCONF} -t -A information_schema
#	echo "SELECT USER,DB,substring_index(substring_index(HOST,':',1),'.',4) as HH,count(*) as total FROM information_schema.PROCESSLIST group by USER,DB,HH ORDER BY total,USER,DB,HH DESC;" | $MYSQLBIN --login-path=prod -t -A information_schema
#	echo "SELECT count(*) as total FROM information_schema.PROCESSLIST;" | $MYSQLBIN --defaults-file=${MYCONF} -t -A information_schema
#	echo "SELECT count(*) as total FROM information_schema.PROCESSLIST;" | $MYSQLBIN --login-path=prod -t -A information_schema
	echo "Slepping 5s..."
	echo ""
	sleep 5
done
