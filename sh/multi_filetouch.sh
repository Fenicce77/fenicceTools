#!/bin/sh
# current hostname
HOSTNAME=$(hostname)
# sample files base dir
BASEDIR="/mysql/mysqlbackup/sampling/data"
# Base dir for current host
HOSTBASEDIR="${BASEDIR}/${HOSTNAME}"
# current year
YY=$(date +%Y)
# current month
MM=$(date +%m)
# YY and MM for current host dir files located
HOSTYYMMFILESDIR="${HOSTBASEDIR}/${YY}/$MM/"

#mydaydate=$(date +"%Y%m%d" -d "10 day ago")
# Starting day
INITDAY=$(date +"%d" -d "10 day ago")
# Ending day
ENDDAY=$(date +"%d" -d "7 day ago")
CURRDAY=$(date +"%d")
echo "******************************************** "
echo "* HOSTYYMMFILESDIR : ${HOSTYYMMFILESDIR}"
echo "* INITDAY : ${INITDAY}"
echo "* ENDDAY : ${ENDDAY}"
echo "******************************************** "
for i in `seq $INITDAY $ENDDAY`;
do
#	for f in `ls /mysql/mysqlbackup/sampling/data/mysql-mattermost-gaming-1.ltrudev.internal/2021/09/18/`
	DIRFILEPATHTOTOUCH="${HOSTYYMMFILESDIR}${i}"
	DIFF=$(echo "$CURRDAY-$i"|bc)
	mydaydate=$(date +"%Y%m%d" -d "${DIFF} day ago")
	echo "* DIRFILEPATHTOTOUCH : ${DIRFILEPATHTOTOUCH}"
	echo "* mydaydate = ${mydaydate}"
	for f in `ls ${DIRFILEPATHTOTOUCH}/`
	do 
		FILEPATHTOTOUCH="${DIRFILEPATHTOTOUCH}/${f}"
		echo "> File to touch : ${FILEPATHTOTOUCH}"
		HH=$(echo $f|awk -F'.' '{print $1"59"}')
		newfiledate="$mydaydate$HH"
		echo "date for ${f}:"$newfiledate
		CMD="touch -t $newfiledate ${FILEPATHTOTOUCH}"
		echo " Touch to execute : $CMD"
		touch -t $newfiledate ${FILEPATHTOTOUCH}
	done
done