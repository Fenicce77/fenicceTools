#!/bin/bash

infile=$1
bulksize=$2
fullsize=`wc -l $infile`
MYCNF="/root/scripts/mysql/db.my.cnf"
#socket=$3
maxLA=600 # Load Average Maximo(*100) para ejecutar inserciones
# Log File
LOGFILE=$1".log"
# tmp file for executing by batches
tmpfile=$1."tmp"
# track file for storing last line processed
trackfile=$1".trackfile"

# Generamos el fichero sql que usaremos para las cargas
nlines=`cat $infile | wc -l`

# MySQL Binary Path
MYSQLBIN=`which mysql`

echo ">>>>>>>>>>>>>> Process started at : `date` <<<<<<<<<<<<<<<<<<<<<">>$LOGFILE
# Creamos el fichero de seguimiento de lectura
if [ ! -f ${trackfile} ]; then
        echo "0" > $trackfile
        echo "`date`: Starting load process..."  >> $LOGFILE
else
        echo "`date`: Resuming load process..."  >> $LOGFILE
fi

endpos=`cat $trackfile`
lastpos=$endpos

#echo "$endpos lines processed out of $nlines" >>$LOGFILE



while [[ $endpos -lt $nlines ]]; 
do
    # Check Load Average
    currLA=`uptime | cut -d, -f4 | cut -d: -f2 | sed 's/\.//g' | sed 's/ //g'`
    while [ $currLA -gt $maxLA ]; do
        echo "LA*100 too high (over $maxLA); skipping insert...">>$LOGFILE
        sleep 60s
        currLA=`uptime | cut -d, -f4 | cut -d: -f2 | sed 's/\.//g' | sed 's/ //g'`
    done

    blocksize=`echo $nlines-$lastpos | bc`
    endpos=`echo $lastpos+$bulksize | bc`

    echo " - blocksize = $blocksize" >> $LOGFILE
    echo " - bulksize  = $bulksize" >> $LOGFILE
    echo " - endpos    = $endpos" >> $LOGFILE
    
    echo "last number line read from $infile : $lastpos">>$LOGFILE
#    echo "bulksize= $bulksize"
#    echo "endpos = $endpos"

    if [ $blocksize -lt $bulksize ];then
	echo "$blocksize lines remain in file!! Bulksize changed to $blocksize" >> $LOGFILE 
	endpos=`echo $lastpos+$blocksize | bc`
	echo "set names latin1;" >> $tmpfile
	tail -n $blocksize $infile >> $tmpfile
	#endpos=`echo $lastpos+$blocksize | bc`
    else
    	echo "bulksize= $bulksize" >> $LOGFILE
	endpos=`echo $lastpos+$bulksize | bc`
	
    #rm $tmpfile # no deberia hacer falta...
  	head -n $endpos $infile | tail -n $bulksize > $tmpfile
    fi
    
    cat $tmpfile | ${MYSQLBIN} --login-path=prod 2>&1 >> $1".out"
  
    EXIT=$?
    if [ $EXIT -ne 0 ]; then
        echo "Error loading data in MySQL instance.  Aborting...."
        exit -1
    fi
    echo $endpos > $trackfile
    lastpos=$endpos
    if [ $lastpos -lt $nlines ];then
	echo "`date`: $endpos lines processed out of $nlines" >>$LOGFILE
    	echo "Sleeping 10s.." >> $LOGFILE
    	sleep 10s
	end=1
    else
	end=0
    fi

done
if [ $end -eq 0 ];then
	echo "File succesfully processed!!" >> $LOGFILE
	echo ">>>>>>>>>>>>>> Process terminated succesfully at : `date` <<<<<<<<<<<<<<<<<<<" >>$LOGFILE
	mv $trackfile $trackile".old"
fi
