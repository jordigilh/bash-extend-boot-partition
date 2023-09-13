#!/bin/bash

# Command parameters
INCREMENT_BOOT_PARTITION_SIZE=
DEVICE_NAME=

# Script parameters
BOOT_PARTITION_NUMBER=
SUCCESSIVE_PARTITION_NUMBER=
BOOT_PARTITION_FLAG="boot"
LOGICAL_VOLUME_DEVICE_NAME=
INCREMENT_BOOT_PARTITION_SIZE_IN_BYTES=

function is_device_mounted() {
    /usr/bin/findmnt --source "$1" 1>&2>/dev/null
    status=$?
    if [[  status -eq 0 ]]; then
        echo "Device $1 is mounted" >&2
        exit 1
    fi
}

function validate_device_name() {
    DEVICE_NAME="$1"
    if [[ -z "$DEVICE_NAME" ]]; then
        echo "Missing device name"
        exit 1
    fi
    if [[ ! -e "$DEVICE_NAME" ]]; then 
        echo "Device $DEVICE_NAME not found"
        exit 1
    fi
    err=$(/usr/sbin/fdisk -l "$DEVICE_NAME" 2>&1)
    status=$?
    if [[ $status -ne 0 ]]; then
        echo "Failed to open device $DEVICE_NAME: $err"
        exit 1
    fi
}

function validate_increment_partition_size() {
    INCREMENT_BOOT_PARTITION_SIZE="$1"
    if [[ -z "$INCREMENT_BOOT_PARTITION_SIZE" ]]; then
        echo "Missing incremental size for boot partition"
        print help
        exit 1
    fi
    ret=$(/usr/bin/numfmt --from=iec "$INCREMENT_BOOT_PARTITION_SIZE" 2>&1)
    status=$?
     if [[ $status -ne 0 ]]; then
        echo "Invalid size value for '$INCREMENT_BOOT_PARTITION_SIZE': $ret"
        exit $status
    fi
    INCREMENT_BOOT_PARTITION_SIZE_IN_BYTES=$ret
}

# capture and validate the device name that holds the partition
# capture and validate amount of space to increase for boot
function parse_flags() {
    validate_device_name "$1"
    validate_increment_partition_size "$2"
}


function get_boot_partition_number() {
    BOOT_PARTITION_NUMBER=$(/usr/sbin/parted -m "$DEVICE_NAME" print  | /usr/bin/sed -n '/^[0-9]*:/p'| /usr/bin/sed -n '/'$BOOT_PARTITION_FLAG'/p'| /usr/bin/awk -F':' '{print $1}')
    status=$?
    if [[ $status -ne 0 ]]; then
        echo "Unable to identify boot partition number for '$DEVICE_NAME': $BOOT_PARTITION_NUMBER"
        exit 1
    fi
    if [[ "$(wc -l <<<"$BOOT_PARTITION_NUMBER")" -ne "1" ]]; then
        echo "Found multiple partitions with the boot flag enabled for device $DEVICE_NAME"
        exit 1
    fi
    if ! [[ "$BOOT_PARTITION_NUMBER" == +([[:digit:]]) ]]; then
        echo "Invalid boot partition number '$BOOT_PARTITION_NUMBER'"
        exit 1
    fi
    is_device_mounted "$DEVICE_NAME$BOOT_PARTITION_NUMBER"
    is_ext4 "$DEVICE_NAME$BOOT_PARTITION_NUMBER"
}


function get_successive_partition_number() {
    boot_line_number=$(/usr/sbin/parted -m "$DEVICE_NAME" print |/usr/bin/sed -n '/^'"$BOOT_PARTITION_NUMBER"':/ {=}')
    status=$?
    if [[ $status -ne 0 ]]; then
        echo "Unable to identify boot partition number for '$DEVICE_NAME'"
        exit $status
    fi
    if [[ -z "$boot_line_number" ]]; then
        echo "No boot partition found"
        exit 1
    fi
    # get the partition number from the next line after the boot partition 
    SUCCESSIVE_PARTITION_NUMBER=$(/usr/sbin/parted -m "$DEVICE_NAME" print | /usr/bin/sed -n -e '/^'"$BOOT_PARTITION_NUMBER"':/{n;p;}' -e h| /usr/bin/awk -F':' '{print $1}')
    if ! [[ $SUCCESSIVE_PARTITION_NUMBER == +([[:digit:]]) ]]; then
        echo "Invalid successive partition number '$SUCCESSIVE_PARTITION_NUMBER'"
        exit 1
    fi
    is_device_mounted "$DEVICE_NAME""$SUCCESSIVE_PARTITION_NUMBER"
}

function init_variables(){
    parse_flags "$1" "$2"
    get_boot_partition_number
    get_successive_partition_number
}

function calculate_expected_resized_file_system_size_in_blocks(){
    device=$1
    # Retrieve the estimated minimum size in bytes that the device can be shrank
    ret=$(/usr/sbin/e2fsck -f -y "$device" 2>&1)
    status=$?
    if [[ status -ne 0 ]]; then
        echo "File system check failed for $device: $ret"
        exit $status
    fi
    total_block_count=$(/usr/sbin/tune2fs -l "$device" | /usr/bin/awk '/Block count:/{print $3}')
    block_size_in_bytes=$(/usr/sbin/tune2fs -l "$device" | /usr/bin/awk '/Block size:/{print $3}')
    increment_boot_partition_in_blocks=$(( INCREMENT_BOOT_PARTITION_SIZE_IN_BYTES / block_size_in_bytes ))
    new_fs_size_in_blocks=$(( total_block_count - increment_boot_partition_in_blocks ))
    echo $new_fs_size_in_blocks
}


function check_filesystem_size() {
    device=$1
    new_fs_size_in_blocks=$(calculate_expected_resized_file_system_size_in_blocks "$device")
    # it is possible that running this command after resizing it might give an even smaller number. 
    minimum_blocks_required=$(/usr/sbin/resize2fs -P "$device" 2> /dev/null | /usr/bin/awk  '{print $NF}')
    
    if [[ "$new_fs_size_in_blocks" -le "0" ]]; then
        echo "Unable to shrink volume: New size is 0 blocks"
        exit 1
    fi
    if [[ $minimum_blocks_required -gt $new_fs_size_in_blocks ]]; then
        echo "Unable to shrink volume: Estimated minimum size of the file system $1 ($minimum_blocks_required blocks) is greater than the new size $new_fs_size_in_blocks blocks" >&2
        exit 1
    fi
}

function get_device_type(){
    val=$( /usr/sbin/pvs --noheadings -o NAME,fmt | /usr/bin/sed -n 's#'"$DEVICE_NAME""$SUCCESSIVE_PARTITION_NUMBER"' ##p' | /usr/bin/awk 'NF { $1=$1; print }' 2>&1)
    status=$?
    if [[ status -ne 0 ]]; then
        echo "Failed to retrieve device type: $val"
        exit 1
    fi
    echo "$val"
}

function is_ext4(){
    device=$1
    fstype=$(/usr/bin/lsblk -fs "$device" --noheadings -o FSTYPE -d| /usr/bin/awk 'NF { $1=$1; print }')
    status=$?
    if [[ $status -ne 0 ]]; then
        exit $status
    fi
    if [[ "$fstype" != "ext4" ]]; then
        echo "Device $device does not contain an ext4 file system: $fstype"
        exit 1
    fi
}

function resolve_device_name(){
    local device=$DEVICE_NAME$SUCCESSIVE_PARTITION_NUMBER
    device_type=$(get_device_type "$device")
    if [[ $device_type == "lvm2" ]]; then
        # It's an LVM block device 
        # Determine which is the last LV in the PV
        # shellcheck disable=SC2016
        device=$(/usr/sbin/pvdisplay "$device" -m | /usr/bin/sed  -n '/Logical volume/h; ${x;p;}' | /usr/bin/awk  '{print $3}')
        status=$?
        if [[ status -ne 0 ]]; then
            echo "Failed to identify the last LV in $device"
            exit $status
        fi
        # Capture the LV device name
        LOGICAL_VOLUME_DEVICE_NAME=$device
    fi
}

function check_device(){
    local device=$DEVICE_NAME$SUCCESSIVE_PARTITION_NUMBER
    resolve_device_name
    if [[ -n $LOGICAL_VOLUME_DEVICE_NAME ]]; then
        #calculate_required_lv_shrinking_size
        # if it's a logical volume then use the mapped device name
        device=$LOGICAL_VOLUME_DEVICE_NAME
    fi
    is_device_mounted "$device"
    is_ext4 "$device"
    check_filesystem_size "$device"   
}

function shrink_logical_volume() {
    ret=$(/usr/sbin/lvreduce --resizefs -L -"$INCREMENT_BOOT_PARTITION_SIZE" "$LOGICAL_VOLUME_DEVICE_NAME" 2>&1)
    status=$?
    if [[ $status -ne 0 ]]; then
        echo "Failed to shrink logical volume $LOGICAL_VOLUME_DEVICE_NAME: $err"
        exit $status
    fi
}

function evict_end_PV() {
    local device=$DEVICE_NAME$SUCCESSIVE_PARTITION_NUMBER
    ret=$(/usr/sbin/pvmove --alloc anywhere "$device":"$1"- "$device":0-"$1" 2>&1)
    status=$?
    if [[ $status -ne 0 ]]; then        
        echo "Failed to move PEs in PV $LOGICAL_VOLUME_DEVICE_NAME: $ret"
        exit $status
    fi
}

function shrink_physical_volume() {
    local device=$DEVICE_NAME$SUCCESSIVE_PARTITION_NUMBER
    pe_size_in_bytes=$(/usr/sbin/pvdisplay "$device" --units b| /usr/bin/awk 'index($0,"PE Size") {print $3}')
    mod_delta=$((INCREMENT_BOOT_PARTITION_SIZE_IN_BYTES % pe_size_in_bytes))
    if [[ "$mod_delta" != 0 ]];then
        INCREMENT_BOOT_PARTITION_SIZE_IN_BYTES=$((INCREMENT_BOOT_PARTITION_SIZE_IN_BYTES+mod_delta))
    fi
    total_pe_count=$(/usr/sbin/pvs "$device" -o pv_pe_count --noheadings | /usr/bin/sed 's/^[[:space:]]*//g') 
    evict_size_in_PE=$((INCREMENT_BOOT_PARTITION_SIZE_IN_BYTES/pe_size_in_bytes))
    shrink_start_PE=$((total_pe_count - evict_size_in_PE))

    pv_new_size_in_bytes=$(( shrink_start_PE*pe_size_in_bytes ))
    pv_new_size_formatted=$(/usr/bin/numfmt --to=iec $pv_new_size_in_bytes --format %.2f)
    ret=$(/usr/sbin/pvresize --setphysicalvolumesize "$pv_new_size_formatted" -t "$device" -y 2>&1)
    status=$?
    if [[ $status -ne 0 ]]; then
        if [[ $status -eq 5 ]]; then
            # ERRNO 5 is equivalent to command failed: https://github.com/lvmteam/lvm2/blob/2eb34edeba8ffc9e22b6533e9cb20e0b5e93606b/tools/errors.h#L23
            # Try to recover by evicting the ending PEs elsewhere in the PV, in case it's a failure due to ending PE's being inside the shrinking area.
            evict_end_PV $shrink_start_PE
        else 
            echo "Failed to resize PV $device: $ret"
            exit $status
        fi
    fi
    ret=$(/usr/sbin/pvresize --setphysicalvolumesize "$pv_new_size_formatted" "$device" -y 2>&1)
    status=$?
    if [[ $status -ne 0 ]]; then
            echo "Failed to resize PV $device during retry: $ret"
            exit $status  
    fi
}

function calculate_new_end_partition_size_in_bytes(){
    local device=$DEVICE_NAME$SUCCESSIVE_PARTITION_NUMBER
    current_partition_size_in_bytes=$(/usr/sbin/parted -m "$DEVICE_NAME" unit b print| /usr/bin/awk '/^'"$SUCCESSIVE_PARTITION_NUMBER"':/ {split($0,value,":"); print value[3]}'| /usr/bin/sed -e's/B//g')
    status=$?
    if [[ $status -ne 0 ]]; then
        echo "Failed to convert new device size to megabytes $device: $ret"
        exit 1
    fi

    new_partition_size_in_bytes=$(( current_partition_size_in_bytes - INCREMENT_BOOT_PARTITION_SIZE_IN_BYTES))
    echo "$new_partition_size_in_bytes"
}

function resize_fs(){
    local device=$DEVICE_NAME$SUCCESSIVE_PARTITION_NUMBER
    new_size_in_blocks=$(calculate_expected_resized_file_system_size_in_blocks "$device")
    ret=$(/usr/sbin/resize2fs -F "$device" "$new_size_in_blocks" 2>&1 )
    status=$?
    if [[ $status -ne 0 ]]; then
        echo "Failed to resize file system in $device to size: $ret"
        exit 1
    fi
}

function shrink_partition(){
    local device=$DEVICE_NAME$SUCCESSIVE_PARTITION_NUMBER
    device_type=$(get_device_type "$device")
    if [[ "$device_type" == "lvm2" ]]; then
        shrink_logical_volume
        shrink_physical_volume 
    elif [[ "$device_type" == "part" ]]; then 
        resize_fs
    else
        echo "Unknown device type $device_type"
        exit 1
    fi    
    new_end_partition_size_in_bytes=$(calculate_new_end_partition_size_in_bytes)
    ret=$(echo Yes | /usr/sbin/parted "$DEVICE_NAME" ---pretend-input-tty unit B resizepart "$SUCCESSIVE_PARTITION_NUMBER" "$new_end_partition_size_in_bytes" 2>&1 )
    status=$?
    if [[ $status -ne 0 ]]; then
        echo "Failed to resize device $device to size: $ret"
        exit 1
    fi
}

function shift_successive_partition() {
    # If boot partition is not the last one, shift the successive partition to the right to take advantage of the newly fred space. Use 'echo '<amount_to_shift>,' | sfdisk --move-data <device name> -N <partition number>
    # to shift the partition to the right.
    # The astute eye will notice that we're moving the partition, not the last logical volume in the partition.
    ret=$(echo "+$INCREMENT_BOOT_PARTITION_SIZE,"| /usr/sbin/sfdisk --move-data "$DEVICE_NAME" -N "$SUCCESSIVE_PARTITION_NUMBER" --no-reread 2>&1)
    status=$?
    if [[ status -ne 0 ]]; then
        echo "Failed to shift partition '$DEVICE_NAME$SUCCESSIVE_PARTITION_NUMBER': $ret"
        exit $status
    fi
}

function extend_boot_partition() {
    # Resize the boot partition by extending it to take the available space: parted <device> resizepart <partition number> +<extra size>/ check sfdisk as an alternative option)
    # The + tells it to shift the end to the right.
    # If the boot partition is effectivelly the last one, we're shifting the boot partition left, and then taking over the same amount of shifted space to the right,
    # essentially increasing the boot partition by as much as $INCREMENT_BOOT_PARTITION_SIZE
    ret=$(echo "+$INCREMENT_BOOT_PARTITION_SIZE,"| /usr/sbin/sfdisk "$DEVICE_NAME" -N "$BOOT_PARTITION_NUMBER" --no-reread 2>&1)
    status=$?
    if [[ $status -ne 0 ]]; then
        echo "Failed to shift boot partition '$DEVICE_NAME$BOOT_PARTITION_NUMBER': $ret"
        exit $status
    fi
    # Extend the boot file system with `resize2fs <boot_partition>`
    ret=$(/usr/sbin/resize2fs "$DEVICE_NAME""$BOOT_PARTITION_NUMBER")
    status=$?
    if [[ $status -ne 0 ]]; then
        echo "Failed to resize boot partition '$DEVICE_NAME$BOOT_PARTITION_NUMBER': $ret"
        exit $status
    fi
}



main() {
    init_variables "$1" "$2"
    check_device
    shrink_partition
    shift_successive_partition
    extend_boot_partition
}

main "$@"