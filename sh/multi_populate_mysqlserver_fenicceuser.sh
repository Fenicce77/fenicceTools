#!/opt/homebrew/bin/bash
if [ $# -eq 0 ]; then 

	echo "No server name provided!!"
	echo "exiting"
	exit
else
	SERVERNAME=$1
fi
for i in {1..50};do ./populate_mysqlserver_fenicceuser.sh $SERVERNAME;done
