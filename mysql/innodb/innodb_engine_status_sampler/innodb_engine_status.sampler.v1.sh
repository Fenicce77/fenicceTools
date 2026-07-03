#!/opt/homebrew/bin/bash
#
#
#       takes a sample of SHOW ENGINE INNODB STATUS every 10 seconds and stores it in files
#       under $SAMPLEDIR for later use
#       (run it in background with nohup; user should have password in dot file)
#       get_reply routine only needed to drain the mysql output pipe otherwise script will block when it fills up
#
SAMPLEBASEDIR=$HOME/mysql/logs/innodb/
#SAMPLEBASEDIR="/mysql-logs/innodb"
#SAMPLEDIR=$SAMPLEBASEDIR/data/$(hostname)
SAMPLEDIR="$SAMPLEBASEDIR/data/localhost8033"
#USER=photographer
MYCNFBASEDIR="$HOME/mysql/cnf"
MYCNF="${MYCNFBASEDIR}/.photographer.my.cnf"
#
echo "$(pidof $0)"
echo -e "SAMPLEBASEDIR : ${SAMPLEBASEDIR}"
echo -e "SAMPLEDIR     : ${SAMPLEDIR}"
echo -e "MYCNFBASEDIR  : ${MYCNFBASEDIR}"
echo -e "MYCNF : ${MYCNF}"

# exit 0
# get_reply()
# {
#         while read -t 0.2 -u ${mysqlc[0]} row
#         do
#                 echo "$row" >/dev/null
#         done
# }

# coproc mysqlc { script -c "mysql -ANrs -u$USER 2>&1" /dev/null; }
#coproc mysqlc { script -c "mysql --defaults-file=$MYCNF -ANrs 2>&1" /dev/null; }
#coproc mysqlc { script -c "mysql --login-path=prod -ANrs 2>&1" /dev/null; }
#c=0
#echo "set session interactive_timeout=30;" >&${mysqlc[1]}
#echo "set session wait_timeout=30;" >&${mysqlc[1]}
while true
do
        #month=$(date +%m)
        #day=$(date +%d)
        #hour=$(date +%H)
        #folder=$SAMPLEDIR/$month/$day
        folder=$SAMPLEDIR/$(date +%Y%m%d)
        samplefile=$(date +%Y%m%d_%H)
        [ ! -d $folder ] && mkdir -p $folder
        # echo "pager cat >> $folder/$samplefile.sample" >&${mysqlc[1]}
        # echo "show engine innodb status;" >&${mysqlc[1]}
        echo "show engine innodb status\G" | mysql --defaults-file=$MYCNF -ANrs 2>&1 >> $folder/$samplefile.sample
        # get_reply
        sleep 10
done