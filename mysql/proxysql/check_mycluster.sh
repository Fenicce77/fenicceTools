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
# New version for executing locally 
# execute it as root with no user
MYQRY="select @@read_only;"
MYCONF="mycluster.cnf"
MYUSR=`grep "user" ${MYCONF} |  awk -F'=' '{print $2}'| sed 's/"//g'`
MYPWD=`grep "password" ${MYCONF} |  awk -F'=' '{print $2}'| sed 's/"//g'`
echo "MySQL User : ${MYUSR} / MySQL Pass : ${MYPWD}"

#MNGSRV=`grep "host" ${MYCNF} |  awk -F'=' '{print $2}'`
echo -e "Enter the ${cyn}MySQL Server list for checking connectivity and latency in format : srv1 srv2 ... srvN followed by [ENTER]:"
read DBSERVERLIST;
if [[ -z ${DBSERVERLIST} ]] 
then 
	echo -e "MySQL DB Server cannot be empty Starting again..."
	continue
fi
echo "===================================================================================== "
echo "Enter the ${cyn}Checking connectivity and latency for :${off}${red}`echo ${DBSERVERLIST}` ${off} (delay 5s)"
echo "===================================================================================== "
echo ""
while true
do
	echo " =============================================================================================== "
	echo "${mag}[`date +"%Y-%m-%d %H:%M:%S"`]${off}"
	for srv in `echo $DBSERVERLIST`
	do
		#time echo "select @@read_only;" | mysql -u${MYUSR} -h ${srv} -p${$MYPWD}
		# nl=$'\n'
		# output=$(TIMEFORMAT='%R %U %S %P'; echo "select @@read_only;" | mysql -u${MYUSR} -h ${srv} -p${$MYPWD})`
		# set ${output##*$nl}; real_time=$1 user_time=$2 system_time=$3 cpu_percent=$4
		# output=${output%$nl*}
		echo ">> Checking Server : ${yel}$srv${off} <<"
		exectime=`time echo "select @@read_only;" | mysql -u${MYUSR} -h ${srv} -p${MYPWD}`
		echo $exectime
		echo " -------------------------------------------- "
	done
	echo "Slepping 5s..."
	sleep 5s
done
