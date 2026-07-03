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
#MYCONF="rmateos.my.cnf"
HIERADATAPATH="/home/rmateos/git/vagrant/puppet/hiera-eyaml";
#HIERADATAPATH="/home/rmateos/git/vagrant2/vagrant/puppet/hiera-eyaml";
DEFNLOOP=1
OUTFILEPATH="/tmp/crypting_passwords.out"
> ${OUTFILEPATH}
echo -e "\nEnter the ${cyn}MySQL Password ${off} for crypting [ENTER]:"
read MYPWD;
if [[ -z $MYPWD ]] 
then 
	echo "${red}[`date +"%Y-%m-%d %H:%M:%S"`][ERROR]MySQL Password cannot be empty. Check it and Relaunch the script...${off}"
	exit -1
fi

echo -e "\n${yel}Enter the number of loop times${off}[ENTER]:"
read nloop;
if [[ -z $MYPWD ]] 
then 
	echo "${red}[`date +"%Y-%m-%d %H:%M:%S"`][WARNING]No number of loop times deailed, default value will be used : ${DEFNLOOP}...${off}"
	nloop = ${DEFNLOOP}
	exit -1
fi
#MYPWD="p*0abF4&p / j95iF2xWCa80z7g61ujAH14O / n4mBdUxtl1zFN1jJZfRycztR "

echo "Step 1 : Generating MySQL hash"

function myhashpwd {
PYTHON_ARG="$MYPWD" python - <<END
from hashlib import sha1;print "*" + sha1(sha1("$MYPWD").digest()).hexdigest().upper()
END
}

echo "${yel}MySQL Pass:${off}${blu}${MYPWD}${off}"
MYSQLHASHTPWD=$(myhashpwd)
#echo $MYSQLHASHTPWD
#PYTHONCOMM="from hashlib import sha1;print "*" + sha1(sha1("$MYPWD").digest()).hexdigest().upper()"
#MYSQLHASHTPWD=$(python -c 'from hashlib import sha1;print "*" + sha1(sha1("$MYPWD").digest()).hexdigest().upper()')
#MYSQLHASHTPWD=$(python -c '$PYTHONCOMM')
echo "${yel}MySQL Hash:${off}${blu}${MYSQLHASHTPWD}${off}"
echo "Step 2 : Generating MySQL encripted pass (loop times : ${nloop})"
#for i in {1..${nloop}} 
for ((i=1; i<=$nloop; i++))
do
#	echo "i = ${i}"
	MYSQLCRYPTPTPWD=$(eyaml encrypt -l "password_hash" -s "${MYSQLHASHTPWD}" -o string --pkcs7-public-key=${HIERADATAPATH}/public_key.pkcs7.pem)
	echo "${grn}######################################################################################${off}"
	echo "${yel}MySQL Source pass:${off}${red}${MYPWD}${off}"
	echo "${yel}MySQL Hash pass:${off}${red}${MYSQLHASHTPWD}${off}"
	echo "${yel}MySQL Crypted pass:${off}${red}${MYSQLCRYPTPTPWD}${off}"
	echo "${MYSQLCRYPTPTPWD}" >> ${OUTFILEPATH}
	echo "${grn}######################################################################################${off}"
done

echo "${yel}MySQL Crypted Passwords stored in :${off}${grn}${OUTFILEPATH}${off}"
