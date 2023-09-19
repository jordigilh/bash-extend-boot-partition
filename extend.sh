#!/bin/bash

# Command parameters
INCREMENT_BOOT_PARTITION_SIZE=
DEVICE_NAME=

# Script parameters
BOOT_PARTITION_NUMBER=
ADJACENT_PARTITION_NUMBER=
BOOT_PARTITION_FLAG="boot"
EXTENDED_PARTITION_TYPE=extended
LOGICAL_VOLUME_DEVICE_NAME=
INCREMENT_BOOT_PARTITION_SIZE_IN_BYTES=

function print_help(){
    echo "Script to extend the ext4 boot partition using BIOS by reducing the partition size of the adjacent partition by a given amount."
    echo "It only works with ext4 file systems and supports both standard partitions with ext4 and partitions with LVM hosting ext4 file systems."
    echo ""
    echo "The script determines which partition number is the boot partition by looking for the boot flag."
    echo "This process won't work with an EFI boot partition because the boot partition that contains the kernel and the initramfs are in a partition that does not have the flag."
    echo ""
    echo "Usage: $(basename "$0") <device_name> <increase_size>"
    echo ""
    echo "Example"
    echo " $>$(basename "$0") /dev/vdb 1G"
    echo " This command will increase the boot partition in /dev/vdb by 1G and reduce the next in line partition in the device by the equal amount."
}

function ensure_device_not_mounted() {
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
        print_help
        exit 1
    fi
    if [[ ! -e "$DEVICE_NAME" ]]; then 
        echo "Device $DEVICE_NAME not found"
        print_help
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
    if [[ -z $1 ]] && [[ -z $2 ]]; then
        print_help
        exit 1
    fi
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
    ensure_device_not_mounted "$DEVICE_NAME""$BOOT_PARTITION_NUMBER"
    ensure_fs_is_ext4 "$DEVICE_NAME""$BOOT_PARTITION_NUMBER"
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
    # get the extended partition number in case there is one, we will need to shrink it as well
    EXTENDED_PARTITION_NUMBER=$(/usr/sbin/parted "$DEVICE_NAME" print | /usr/bin/sed -n '/'"$EXTENDED_PARTITION_TYPE"'/p'|awk '{print $1}')
    if [[ -n "$EXTENDED_PARTITION_NUMBER" ]]; then
      # if there's an extended partition, use the last one as the target partition to shrink
      ADJACENT_PARTITION_NUMBER=$(/usr/sbin/parted "$DEVICE_NAME" print |grep -v "^$" |awk 'END{print$1}')
    else
        # get the partition number from the next line after the boot partition
        ADJACENT_PARTITION_NUMBER=$(/usr/sbin/parted "$DEVICE_NAME" print | /usr/bin/awk '/'"$BOOT_PARTITION_FLAG"'/{getline;print $1}')
    fi
    if ! [[ $ADJACENT_PARTITION_NUMBER == +([[:digit:]]) ]]; then
        echo "Invalid successive partition number '$ADJACENT_PARTITION_NUMBER'"
        exit 1
    fi
    ensure_device_not_mounted "$DEVICE_NAME""$ADJACENT_PARTITION_NUMBER"
}

function init_variables(){
    parse_flags "$1" "$2"
    get_boot_partition_number
    get_successive_partition_number
}

function check_filesystem(){
    local device=$1
    # Retrieve the estimated minimum size in bytes that the device can be shrank
    ret=$(/usr/sbin/e2fsck -fy "$device" 2>&1)
    local status=$?
    if [[ status -ne 0 ]]; then
        echo "Warning: File system check failed for $device: $ret"
    fi
}

function convert_size_to_fs_blocks(){
    local device=$1
    local size=$2
    block_size_in_bytes=$(/usr/sbin/tune2fs -l "$device" | /usr/bin/awk '/Block size:/{print $3}')
    echo $(( size / block_size_in_bytes ))
}

function calculate_expected_resized_file_system_size_in_blocks(){
    local device=$1
    increment_boot_partition_in_blocks=$(convert_size_to_fs_blocks "$device" "$INCREMENT_BOOT_PARTITION_SIZE_IN_BYTES")
    total_block_count=$(/usr/sbin/tune2fs -l "$device" | /usr/bin/awk '/Block count:/{print $3}')
    new_fs_size_in_blocks=$(( total_block_count - increment_boot_partition_in_blocks ))
    echo $new_fs_size_in_blocks
}


function check_filesystem_size() {
    local device=$1
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
    val=$( /usr/sbin/pvs --noheadings -o NAME,fmt | /usr/bin/sed -n 's#'"$DEVICE_NAME""$ADJACENT_PARTITION_NUMBER"' ##p' | /usr/bin/awk 'NF { $1=$1; print }' 2>&1)
    local status=$?
    if [[ status -ne 0 ]]; then
        echo "Failed to retrieve device type: $val"
        exit 1
    fi
    echo "$val"
}

function ensure_fs_is_ext4(){
    local device=$1
    fstype=$(/usr/bin/lsblk -fs "$device" --noheadings -o FSTYPE -d| /usr/bin/awk 'NF { $1=$1; print }')
    local status=$?
    if [[ $status -ne 0 ]]; then
        exit $status
    fi
    if [[ "$fstype" != "ext4" ]]; then
        echo "Device $device does not contain an ext4 file system: $fstype"
        exit 1
    fi
}

function resolve_device_name(){
    local device=$DEVICE_NAME$ADJACENT_PARTITION_NUMBER
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


function deactivate_volume_group(){
    local volume_group_name
    volume_group_name=$(/usr/sbin/pvs "$DEVICE_NAME""$ADJACENT_PARTITION_NUMBER" -o vg_name --noheadings|/usr/bin/sed 's/^[[:space:]]*//g')
    status=$?
    if [[ $status -ne 0 ]]; then
        echo "Failed to retrieve volume group name for logical volume $LOGICAL_VOLUME_DEVICE_NAME: $err"
        exit $status
    fi
    ret=$(/usr/sbin/vgchange -an "$volume_group_name" 2>&1)
    status=$?
    if [[ $status -ne 0 ]]; then
        echo "Failed to deactivate volume group $volume_group_name: $err"
        exit $status
    fi
    # avoid potential deadlocks with udev rules before continuing
    sleep 1
}

function check_device(){
    local device=$DEVICE_NAME$ADJACENT_PARTITION_NUMBER
    resolve_device_name
    if [[ -n $LOGICAL_VOLUME_DEVICE_NAME ]]; then
        #calculate_required_lv_shrinking_size
        # if it's a logical volume then use the mapped device name
        device=$LOGICAL_VOLUME_DEVICE_NAME
    fi
    ensure_device_not_mounted "$device"
    ensure_fs_is_ext4 "$device"
    check_filesystem "$device"
    check_filesystem_size "$device"
}

function shrink_logical_volume() {
    ret=$(/usr/sbin/lvreduce --resizefs -L -"$INCREMENT_BOOT_PARTITION_SIZE" "$LOGICAL_VOLUME_DEVICE_NAME" 2>&1)
    local status=$?
    if [[ $status -ne 0 ]]; then
        echo "Failed to shrink logical volume $LOGICAL_VOLUME_DEVICE_NAME: $err"
        exit $status
    fi
    check_filesystem "$LOGICAL_VOLUME_DEVICE_NAME"
}

function evict_end_PV() {
    local device=$DEVICE_NAME$ADJACENT_PARTITION_NUMBER
    local shrinking_start_PE=$1
    ret=$(/usr/sbin/pvmove --alloc anywhere "$device":"$shrinking_start_PE"-  2>&1)
    status=$?
    if [[ $status -ne 0 ]]; then        
        echo "Failed to move PEs in PV $LOGICAL_VOLUME_DEVICE_NAME: $ret"
        exit $status
    fi
    check_filesystem "$LOGICAL_VOLUME_DEVICE_NAME"
}

function shrink_physical_volume() {
    local device=$DEVICE_NAME$ADJACENT_PARTITION_NUMBER
    pe_size_in_bytes=$(/usr/sbin/pvdisplay "$device" --units b| /usr/bin/awk 'index($0,"PE Size") {print $3}')
    unusable_space_in_pv_in_bytes=$(/usr/sbin/pvdisplay --units B "$device" | /usr/bin/awk 'index($0,"not usable") {print $(NF-1)}'|/usr/bin/numfmt --from=iec)

    total_pe_count=$(/usr/sbin/pvs "$device" -o pv_pe_count --noheadings | /usr/bin/sed 's/^[[:space:]]*//g') 
    evict_size_in_PE=$((INCREMENT_BOOT_PARTITION_SIZE_IN_BYTES/pe_size_in_bytes))
    shrink_start_PE=$((total_pe_count - evict_size_in_PE))
    pv_new_size_in_bytes=$(( (shrink_start_PE*pe_size_in_bytes) + unusable_space_in_pv_in_bytes ))
    
    ret=$(/usr/sbin/pvresize --setphysicalvolumesize "$pv_new_size_in_bytes"B -t "$device" -y 2>&1)
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
    ret=$(/usr/sbin/pvresize --setphysicalvolumesize "$pv_new_size_in_bytes"B "$device" -y 2>&1)
    status=$?
    if [[ $status -ne 0 ]]; then
            echo "Failed to resize PV $device during retry: $ret"
            exit $status  
    fi
    check_filesystem "$LOGICAL_VOLUME_DEVICE_NAME"
}

function calculate_new_end_partition_size_in_bytes(){
    local partition_number=$1
    local device=$DEVICE_NAME$partition_number
    current_partition_size_in_bytes=$(/usr/sbin/parted -m "$DEVICE_NAME" unit b print| /usr/bin/awk '/^'"$partition_number"':/ {split($0,value,":"); print value[3]}'| /usr/bin/sed -e's/B//g')
    status=$?
    if [[ $status -ne 0 ]]; then
        echo "Failed to convert new device size to megabytes $device: $ret"
        exit 1
    fi

    new_partition_size_in_bytes=$(( current_partition_size_in_bytes - INCREMENT_BOOT_PARTITION_SIZE_IN_BYTES))
    echo "$new_partition_size_in_bytes"
}

function resize_fs(){
    local device=$DEVICE_NAME$ADJACENT_PARTITION_NUMBER
    new_size_in_blocks=$(calculate_expected_resized_file_system_size_in_blocks "$device")
    ret=$(/usr/sbin/resize2fs -F "$device" "$new_size_in_blocks" 2>&1 )
    status=$?
    if [[ $status -ne 0 ]]; then
        echo "Failed to resize file system in $device to size: $ret"
        exit 1
    fi
}

function shrink_partition() {
    local partition_number=$1
    new_end_partition_size_in_bytes=$(calculate_new_end_partition_size_in_bytes "$partition_number")
    ret=$(echo Yes | /usr/sbin/parted "$DEVICE_NAME" ---pretend-input-tty unit B resizepart "$partition_number" "$new_end_partition_size_in_bytes" 2>&1 )
    status=$?
    if [[ $status -ne 0 ]]; then
        echo "Failed to resize device $DEVICE_NAME$partition_number to size: $ret"
        exit 1
    fi
}

function shrink_adjacent_partition(){
    local device_type
    device_type=$(get_device_type "$DEVICE_NAME""$ADJACENT_PARTITION_NUMBER")
    if [[ "$device_type" == "lvm2" ]]; then
        shrink_logical_volume
        shrink_physical_volume 
    elif [[ "$device_type" == "part" ]]; then 
        resize_fs
    else
        echo "Unknown device type $device_type"
        exit 1
    fi
    shrink_partition "$ADJACENT_PARTITION_NUMBER"
    if [[ -n "$EXTENDED_PARTITION_NUMBER" ]]; then
        # resize the extended partition
        shrink_partition "$EXTENDED_PARTITION_NUMBER"
    fi
}

function shift_adjacent_partition() {
    # If boot partition is not the last one, shift the successive partition to the right to take advantage of the newly fred space. Use 'echo '<amount_to_shift>,' | sfdisk --move-data <device name> -N <partition number>
    # to shift the partition to the right.
    # The astute eye will notice that we're moving the partition, not the last logical volume in the partition.
    local target_partition=$ADJACENT_PARTITION_NUMBER
    if [[ -n "$EXTENDED_PARTITION_NUMBER" ]]; then
        target_partition=$EXTENDED_PARTITION_NUMBER
    fi
    ret=$(echo "+$INCREMENT_BOOT_PARTITION_SIZE,"| /usr/sbin/sfdisk --move-data "$DEVICE_NAME" -N "$target_partition" --force 2>&1)
    status=$?
    if [[ status -ne 0 ]]; then
        echo "Failed to shift partition '$DEVICE_NAME$target_partition': $ret"
        exit $status
    fi
}

function update_kernel_partition_tables(){
    # Ensure no size inconsistencies between PV and partition
    local device=$DEVICE_NAME$ADJACENT_PARTITION_NUMBER
    device_type=$(get_device_type "$device")
    if [[ $device_type == "lvm2" ]]; then
        ret=$(/usr/sbin/pvresize "$device" -y 2>&1)
        status=$?
        if [[ status -ne 0 ]]; then
            echo "Failed to align PV and partition sizes '$device': $ret"
            exit $status
        fi
        # ensure that the VG is not active so that the changes to the kernel PT are reflected by the partx command
        deactivate_volume_group
    fi
    ret=$(/usr/sbin/partprobe "$DEVICE_NAME")
    status=$?
    if [[ $status -ne 0 ]]; then
        echo "Errors found while updating the kernel's partition tables for '$device': $ret"
        exit $status
    fi
}

function extend_boot_partition() {
    # Resize the boot partition by extending it to take the available space: parted <device> resizepart <partition number> +<extra size>/ check sfdisk as an alternative option)
    # The + tells it to shift the end to the right.
    # If the boot partition is effectivelly the last one, we're shifting the boot partition left, and then taking over the same amount of shifted space to the right,
    # essentially increasing the boot partition by as much as $INCREMENT_BOOT_PARTITION_SIZE
    ret=$(echo "- +"| /usr/sbin/sfdisk "$DEVICE_NAME" -N "$BOOT_PARTITION_NUMBER" --no-reread --force 2>&1)
    status=$?
    if [[ $status -ne 0 ]]; then
        echo "Failed to shift boot partition '$device': $ret"
        exit $status
    fi
    local device=$DEVICE_NAME$BOOT_PARTITION_NUMBER
    check_filesystem "$device"
    update_kernel_partition_tables
    # Extend the boot file system with `resize2fs <boot_partition>`
    increment_boot_partition_in_blocks=$(convert_size_to_fs_blocks "$device" "$INCREMENT_BOOT_PARTITION_SIZE_IN_BYTES")
    total_block_count=$(/usr/sbin/tune2fs -l "$device" | /usr/bin/awk '/Block count:/{print $3}')
    new_fs_size_in_blocks=$(( total_block_count + increment_boot_partition_in_blocks ))
    ret=$(/usr/sbin/resize2fs "$device" $new_fs_size_in_blocks 2>&1)
    status=$?
    if [[ $status -ne 0 ]]; then
        echo "Failed to resize boot partition '$device': $ret"
        exit $status
    fi
}

function activate_volume_group(){
    local device=$DEVICE_NAME$ADJACENT_PARTITION_NUMBER
    device_type=$(get_device_type "$device")
    if [[ $device_type == "lvm2" ]]; then
        local volume_group_name
        volume_group_name=$(/usr/sbin/pvs "$device" -o vg_name --noheadings|/usr/bin/sed 's/^[[:space:]]*//g')
        status=$?
        if [[ $status -ne 0 ]]; then
            echo "Failed to retrieve volume group name for logical volume $LOGICAL_VOLUME_DEVICE_NAME: $err"
            exit $status
        fi
        ret=$(/usr/sbin/vgchange -ay "$volume_group_name" 2>&1)
        status=$?
        if [[ $status -ne 0 ]]; then
            echo "Failed to activate volume group $volume_group_name: $err"
            exit $status
        fi
        # avoid potential deadlocks with udev rules before continuing
        sleep 1
    fi
}

# last steps are to run the fsck on boot partition and activate the volume gruop if necessary
function cleanup(){
    # activate the volume group belonging to the adjacent partition if necessary.
    activate_volume_group
    # run a file system check to the boot file system
    check_filesystem "$DEVICE_NAME""$BOOT_PARTITION_NUMBER"
}

main() {
    init_variables "$1" "$2"
    check_device
    shrink_adjacent_partition
    shift_adjacent_partition
    extend_boot_partition
    cleanup
}

main "$@"