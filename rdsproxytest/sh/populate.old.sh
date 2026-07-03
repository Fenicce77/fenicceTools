qryBegin="BEGIN;"
qryCommit="COMMIT;"
qrytrans=""
DEFMAXINS=1000
MYSERVER=`hostname`

MYCONF=$1
#if [ $# -eq 0 ]; then
#       NUMINS=${DEFMAXINS}
#       echo "No insertion account limit provided, Default value : ${NUMINS} will be used "
#else
#       NUMINS=$1
#fi

help()
{
    echo "Usage: populate.sh [ -f | --conf ]
               [ -b | --batch ]
               [ -c | --chunk ]
               [ -h | --help  ]"
    exit 2
}

SHORT=f:,b:,c:,h
LONG=conf:,size:,help
OPTS=$(getopt -a -n populate --options $SHORT --longoptions $LONG -- "$@")

VALID_ARGUMENTS=$# # Returns the count of arguments that are in short or long options

if [ "$VALID_ARGUMENTS" -eq 0 ]; then
  help
fi

eval set -- "$OPTS"

while :
do
  case "$1" in
    -f | --conf )
      MYCONF=$2
      shift
      ;;
    -b | --batch )
      BATCHSIZE=$2
      shift
      ;;
    -c | --chunk )
      CHUNKSIZE=$2
      shift
      ;;
    -h | --help)
      help
      ;;
    --)
      shift;
      break
      ;;
    *)
      echo "Unexpected option: $1"
      help
      ;;
  esac
done

#MYCONF=$1
PARAMS="--defaults-file=${MYCONF}"
MYSERVER=`cat ${MYCONF} | grep host | awk -F'=' '{print $2}'`
INITROWSINTABLE=`echo "select count(*) as total from T1;"|mysql ${PARAMS} -Av jucy -N`
echo "[`date +"%Y-%m-%d %H:%M:%S"]` Initial Rows in table : ${INITROWSINTABLE}"

for i in {1..${BATCHSIZE}};do
        host=`hostname`
        qrynew="INSERT INTO T1 (K,host,hostfrom,created_ts) VALUES (${i},@@hostname,'${MYSERVER}',now());"
        qrytrans="${qrytrans}${qrynew}"
        batchmod=`echo $((${i} % ${CHUNKSIZE}))`
        if [[ $batchmod -eq 0 ]]; then

                #qrytrans="${qrytrans};SELECT SLEEP(10);"
                qrytrans="${qrytrans};SELECT NOW() AS CURRENT_DATETIME;SELECT SLEEP(20);SELECT NOW() AS CURRENT_DATETIME;"
        fi

        fulltrans="${qryBegin}${qrytrans}${qryCommit}"
done

fulltrans="${qryBegin}${qrytrans}${qryCommit}"

echo $fulltrans | mysql ${PARAMS} -Av jucy -N
ROWSINTABLE=`echo "select count(*) as total from T1;"|mysql ${PARAMS} -Av jucy -N`
echo "[`date +"%Y-%m-%d %H:%M:%S"]` Final Rows in table : ${ROWSINTABLE}"