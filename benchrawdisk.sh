#!/bin/bash

function format_speed {
	RAW=$1 # disk speed in KB/s
	RESULT=$RAW
	local DENOM=1
	local UNIT="KB/s"

	# ensure raw value is not null, if it is, return blank
	if [ -z "$RAW" ]; then
		echo ""
		return 0
	fi

	# check if disk speed >= 1 GB/s
	if [ "$RAW" -ge 1000000 ]; then
		DENOM=1000000
		UNIT="GB/s"
	# check if disk speed < 1 GB/s && >= 1 MB/s
	elif [ "$RAW" -ge 1000 ]; then
		DENOM=1000
		UNIT="MB/s"
	fi

	# divide the raw result to get the corresponding formatted result (based on determined unit)
	RESULT=$(awk -v a="$RESULT" -v b="$DENOM" 'BEGIN { print a / b }')
	# shorten the formatted result to two decimal places (i.e. x.xx)
	RESULT=$(echo $RESULT | awk -F. '{ printf "%0.2f",$1"."substr($2,1,2) }')
	# concat formatted result value with units and return result
	RESULT="$RESULT $UNIT"
	echo $RESULT
}

function format_iops {
	RAW=$1 # iops
	RESULT=$RAW

	# ensure raw value is not null, if it is, return blank
	if [ -z "$RAW" ]; then
		echo ""
		return 0
	fi

	# check if IOPS speed > 1k
	if [ "$RAW" -ge 1000 ]; then
		# divide the raw result by 1k
		RESULT=$(awk -v a="$RESULT" 'BEGIN { print a / 1000 }')
		# shorten the formatted result to one decimal place (i.e. x.x)
		RESULT=$(echo $RESULT | awk -F. '{ printf "%0.1f",$1"."substr($2,1,1) }')
		RESULT="$RESULT"k
	fi

	echo $RESULT
}

function disk_test {
	FIO_SIZE=2G
    FIO_CMD=fio
	# run a quick test to generate the fio test file to be used by the actual tests
	echo -en "Generating fio test file..."
	$FIO_CMD --name=setup --ioengine=libaio --rw=read --bs=64k --iodepth=64 --numjobs=2 --size=2G --runtime=1 --gtod_reduce=1 --filename="$DISK_PATH/test.fio" --direct=1 --minimal &> /dev/null
	echo -en "\r\033[0K"

	# get array of block sizes to evaluate
	BLOCK_SIZES=("$@")

	for BS in "${BLOCK_SIZES[@]}"; do
		# run rand read/write mixed fio test with block size = $BS
		echo -en "Running fio random mixed R+W disk test with $BS block size..."
		DISK_TEST=$(timeout 35 $FIO_CMD --name=rand_rw_$BS --ioengine=libaio --rw=randrw --rwmixread=50 --bs=$BS --iodepth=64 --numjobs=2 --size=$FIO_SIZE --runtime=30 --gtod_reduce=1 --direct=1 --filename="$DISK_PATH/test.fio" --group_reporting --minimal 2> /dev/null | grep rand_rw_$BS)
		DISK_IOPS_R=$(echo $DISK_TEST | awk -F';' '{print $8}')
		DISK_IOPS_W=$(echo $DISK_TEST | awk -F';' '{print $49}')
		DISK_IOPS=$(awk -v a="$DISK_IOPS_R" -v b="$DISK_IOPS_W" 'BEGIN { print a + b }')
		DISK_TEST_R=$(echo $DISK_TEST | awk -F';' '{print $7}')
		DISK_TEST_W=$(echo $DISK_TEST | awk -F';' '{print $48}')
		DISK_TEST=$(awk -v a="$DISK_TEST_R" -v b="$DISK_TEST_W" 'BEGIN { print a + b }')
		DISK_RESULTS_RAW+=( "$DISK_TEST" "$DISK_TEST_R" "$DISK_TEST_W" "$DISK_IOPS" "$DISK_IOPS_R" "$DISK_IOPS_W" )

		DISK_IOPS=$(format_iops $DISK_IOPS)
		DISK_IOPS_R=$(format_iops $DISK_IOPS_R)
		DISK_IOPS_W=$(format_iops $DISK_IOPS_W)
		DISK_TEST=$(format_speed $DISK_TEST)
		DISK_TEST_R=$(format_speed $DISK_TEST_R)
		DISK_TEST_W=$(format_speed $DISK_TEST_W)

		DISK_RESULTS+=( "$DISK_TEST" "$DISK_TEST_R" "$DISK_TEST_W" "$DISK_IOPS" "$DISK_IOPS_R" "$DISK_IOPS_W" )
		echo -en "\r\033[0K"
	done
}

echo -en "Preparing system for disk tests..."

#format disk as ext4 and create temp directory to store disk write/read test files

DISK_PATH=/mnt/diskbench
mkdir -p "$DISK_PATH"
RAW_DISK=$1
mkfs.ext4 -q $RAW_DISK
mount $RAW_DISK $DISK_PATH

echo -en "\r\033[0K"

# init global array to store disk performance values
declare -a DISK_RESULTS DISK_RESULTS_RAW
# disk block sizes to evaluate
BLOCK_SIZES=( "4k" "64k" "512k" "1m" )

# execute disk performance test
disk_test "${BLOCK_SIZES[@]}"

CURRENT_PARTITION=$(df -P $DISK_PATH 2>/dev/null | tail -1 | cut -d' ' -f 1)
[[ ! -z $JSON ]] && JSON_RESULT+=',"partition":"'$CURRENT_PARTITION'","fio":['
DISK_RESULTS_NUM=$(expr ${#DISK_RESULTS[@]} / 6)
DISK_COUNT=0

echo -en "Cleaning test file and clear disk format..."

#umount and remove format
umount $DISK_PATH
rm -r $DISK_PATH
sgdisk -Z $RAW_DISK > /dev/null
udevadm trigger

echo -en "\r\033[0K"

# print disk speed test results
echo -e "fio Disk Speed Tests (Mixed R/W 50/50) (Partition $CURRENT_PARTITION):"
echo -e "---------------------------------"

while [ $DISK_COUNT -lt $DISK_RESULTS_NUM ] ; do
    if [ $DISK_COUNT -gt 0 ]; then printf "%-10s | %-20s | %-20s\n"; fi
    printf "%-10s | %-11s %8s | %-11s %8s\n" "Block Size" "${BLOCK_SIZES[DISK_COUNT]}" "(IOPS)" "${BLOCK_SIZES[DISK_COUNT+1]}" "(IOPS)"
    printf "%-10s | %-11s %8s | %-11s %8s\n" "  ------" "---" "---- " "----" "---- "
    printf "%-10s | %-11s %8s | %-11s %8s\n" "Read" "${DISK_RESULTS[DISK_COUNT*6+1]}" "(${DISK_RESULTS[DISK_COUNT*6+4]})" "${DISK_RESULTS[(DISK_COUNT+1)*6+1]}" "(${DISK_RESULTS[(DISK_COUNT+1)*6+4]})"
    printf "%-10s | %-11s %8s | %-11s %8s\n" "Write" "${DISK_RESULTS[DISK_COUNT*6+2]}" "(${DISK_RESULTS[DISK_COUNT*6+5]})" "${DISK_RESULTS[(DISK_COUNT+1)*6+2]}" "(${DISK_RESULTS[(DISK_COUNT+1)*6+5]})"
    printf "%-10s | %-11s %8s | %-11s %8s\n" "Total" "${DISK_RESULTS[DISK_COUNT*6]}" "(${DISK_RESULTS[DISK_COUNT*6+3]})" "${DISK_RESULTS[(DISK_COUNT+1)*6]}" "(${DISK_RESULTS[(DISK_COUNT+1)*6+3]})"
    if [ ! -z $JSON ]; then
        JSON_RESULT+='{"bs":"'${BLOCK_SIZES[DISK_COUNT]}'","speed_r":'${DISK_RESULTS_RAW[DISK_COUNT*6+1]}',"iops_r":'${DISK_RESULTS_RAW[DISK_COUNT*6+4]}
        JSON_RESULT+=',"speed_w":'${DISK_RESULTS_RAW[DISK_COUNT*6+2]}',"iops_w":'${DISK_RESULTS_RAW[DISK_COUNT*6+5]}',"speed_rw":'${DISK_RESULTS_RAW[DISK_COUNT*6]}
        JSON_RESULT+=',"iops_rw":'${DISK_RESULTS_RAW[DISK_COUNT*6+3]}',"speed_units":"KBps"},'
        JSON_RESULT+='{"bs":"'${BLOCK_SIZES[DISK_COUNT+1]}'","speed_r":'${DISK_RESULTS_RAW[(DISK_COUNT+1)*6+1]}',"iops_r":'${DISK_RESULTS_RAW[(DISK_COUNT+1)*6+4]}
        JSON_RESULT+=',"speed_w":'${DISK_RESULTS_RAW[(DISK_COUNT+1)*6+2]}',"iops_w":'${DISK_RESULTS_RAW[(DISK_COUNT+1)*6+5]}',"speed_rw":'${DISK_RESULTS_RAW[(DISK_COUNT+1)*6]}
        JSON_RESULT+=',"iops_rw":'${DISK_RESULTS_RAW[(DISK_COUNT+1)*6+3]}',"speed_units":"KBps"},'
    fi
    DISK_COUNT=$(expr $DISK_COUNT + 2)
done
[[ ! -z $JSON ]] && JSON_RESULT=${JSON_RESULT::${#JSON_RESULT}-1} && JSON_RESULT+=']'
