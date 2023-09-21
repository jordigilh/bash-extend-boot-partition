#!/bin/bash

# Command parameters
INCREMENT_BOOT_PARTITION_SIZE=
DEVICE_NAME=

# Script parameters
BOOT_PARTITION_NUMBER=
ADJACENT_PARTITION_NUMBER=
BOOT_PARTITION_FLAG="boot"
BOOT_FS_TYPE=
EXTENDED_PARTITION_TYPE=extended
LOGICAL_VOLUME_DEVICE_NAME=
INCREMENT_BOOT_PARTITION_SIZE_IN_BYTES=

function print_help(){
    echo ""
    echo "Script to extend the ext4/xfs boot partition in a BIOS system by shifting the adjacent partition to the boot partition by the parametrized size."
    echo "It expects the device to have enough free space to shift to the right, that is towards the end of the device, the adjacent partition."
    echo "It only works with ext4 and xfs file systems and supports both primary partitions and logical partitions."
    echo ""
    echo "The script determines which partition number is the boot partition by looking for the boot flag."
    echo "This process won't work with an EFI boot partition because the boot partition that contains the kernel and the initramfs are in a partition that does not have the flag."
    echo "The parametrized size supports M for MiB and G for GiB. If no units is given, it is interpreted as bytes"
    echo ""
    echo "Usage: $(basename "$0") <device_name> <increase_size_with_units>"
    echo ""
    echo "Example"
    echo " $>$(basename "$0") /dev/vdb 1G"
    echo " or"
    echo " $>$(basename "$0") /dev/vdb 1073741824"
    echo ""
    echo " This command will increase the boot partition in /dev/vdb by 1G and shift the adjacent partition in the device by the equal amount."
}

function get_device_type(){
    local device=$1
    val=$(lsblk "$device" -o type --noheadings 2>&1)
    local status=$?
    if [[ status -ne 0 ]]; then
        echo "Failed to retrieve device type for $device: $val"
        exit 1
    fi
    type=$(awk -F' ' 'END{print}'<<<"$val")
    if [[ -z $type ]]; then
        echo "Unknown device type for $device"
        exit 1
    fi
    if [[ $val == *"lvm"* ]]; then
        echo "lvm"
    else
        echo "part"
    fi
}

function ensure_device_not_mounted() {
    local device=$1
    local devices_to_check
    device_type=$(get_device_type "$device")
    if [[ $device_type == "lvm" ]]; then
        # It's an LVM block device 
        # Capture the LV device names. Since we'll have to shift the partition, we need to make sure all LVs are not mounted in the adjacent partition.
        devices_to_check=$(pvdisplay "$device" -m |grep "Logical volume" |awk '{print $3}')
    else 
        # Use the device and partition number instead
        devices_to_check=$device
    fi
    for device_name in $devices_to_check; do
        /usr/bin/findmnt --source "$device_name" 1>&2>/dev/null
        status=$?
        if [[  status -eq 0 ]]; then
            echo "Device $device_name is mounted"
            exit 1
        fi
    done
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
    ret=$(/usr/sbin/fdisk -l "$DEVICE_NAME" 2>&1)
    status=$?
    if [[ $status -ne 0 ]]; then
        echo "Failed to open device $DEVICE_NAME: $ret"
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


function get_fs_type(){
    local device=$1
    ret=$(blkid "$device" -o udev | sed -n -e 's/ID_FS_TYPE=//p' 2>&1)
    status=$?
    if [[ $status -ne 0 ]]; then
        exit $status
    fi
    echo "$ret"
}


function ensure_extendable_fs_type(){
    local device=$1
    ret=$(get_fs_type "$device")
    if [[ "$ret" != "ext4" ]] && [[ "$ret" != "xfs" ]]; then
        echo "Boot file system type $ret is not extendable"
        exit 1
    fi
    BOOT_FS_TYPE=$ret
}

function get_boot_partition_number() {
    BOOT_PARTITION_NUMBER=$(/usr/sbin/parted -m "$DEVICE_NAME" print  | /usr/bin/sed -n '/^[0-9]*:/p'| /usr/bin/sed -n '/'$BOOT_PARTITION_FLAG'/p'| /usr/bin/awk -F':' '{print $1}')
    status=$?
    if [[ $status -ne 0 ]]; then
        echo "Unable to identify boot partition number for '$DEVICE_NAME': $BOOT_PARTITION_NUMBER"
        exit 1
    fi
    if [[ "$(/usr/bin/wc -l <<<"$BOOT_PARTITION_NUMBER")" -ne "1" ]]; then
        echo "Found multiple partitions with the boot flag enabled for device $DEVICE_NAME"
        exit 1
    fi
    if ! [[ "$BOOT_PARTITION_NUMBER" == +([[:digit:]]) ]]; then
        echo "Invalid boot partition number '$BOOT_PARTITION_NUMBER'"
        exit 1
    fi
    ensure_device_not_mounted "$DEVICE_NAME""$BOOT_PARTITION_NUMBER"
    ensure_extendable_fs_type "$DEVICE_NAME""$BOOT_PARTITION_NUMBER"
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

function check_free_device_size() {
    free_space=$(/usr/sbin/parted -m "$DEVICE_NAME" unit b print free | /usr/bin/awk -F':'  '/'"^$ADJACENT_PARTITION_NUMBER:"'/{getline;print $0}'|awk -F':' '/free/{print $4}'|sed -e 's/B//g')
    if [[ -z $free_space ]]; then
        echo "No free space available in device $DEVICE_NAME after partition #$ADJACENT_PARTITION_NUMBER"
        exit 1
    fi
    
    if [[ $INCREMENT_BOOT_PARTITION_SIZE_IN_BYTES -gt $free_space ]]; then
        echo "Unable to extend boot partition: Available free space after partition $ADJACENT_PARTITION_NUMBER (""$free_space"" bytes) is smaller than the required size of ""$INCREMENT_BOOT_PARTITION_SIZE_IN_BYTES"" bytes" >&2
        exit 1
    fi
}

function get_volume_group_name(){
    local volume_group_name
    ret=$(/usr/sbin/pvs "$DEVICE_NAME""$ADJACENT_PARTITION_NUMBER" -o vg_name --noheadings|/usr/bin/sed 's/^[[:space:]]*//g')
    status=$?
    if [[ $status -ne 0 ]]; then
        echo "Failed to retrieve volume group name for logical volume $LOGICAL_VOLUME_DEVICE_NAME: $ret"
        exit $status
    fi
    echo "$ret"
}
function deactivate_volume_group(){
    local volume_group_name
    volume_group_name=$(get_volume_group_name)
    ret=$(/usr/sbin/vgchange -an "$volume_group_name" 2>&1)
    status=$?
    if [[ $status -ne 0 ]]; then
        echo "Failed to deactivate volume group $volume_group_name: $ret"
        exit $status
    fi
    # avoid potential deadlocks with udev rules before continuing
    sleep 1
}

function check_device(){
    local device=$DEVICE_NAME$ADJACENT_PARTITION_NUMBER
    local fs_type
    fs_type=$(get_fs_type "$device")
    if [[ "$fs_type" == "ext4" ]]; then
        ensure_device_not_mounted "$device"
    fi
    check_free_device_size
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
    if [[ $device_type == "lvm" ]]; then
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
    local device=$DEVICE_NAME$BOOT_PARTITION_NUMBER
    ret=$(echo "- +"| /usr/sbin/sfdisk "$DEVICE_NAME" -N "$BOOT_PARTITION_NUMBER" --no-reread --force 2>&1)
    status=$?
    if [[ $status -ne 0 ]]; then
        echo "Failed to shift boot partition '$device': $ret"
        exit $status
    fi
    check_filesystem "$device"
    update_kernel_partition_tables
    # Extend the boot file system with `resize2fs <boot_partition>`
    increment_boot_partition_in_blocks=$(convert_size_to_fs_blocks "$device" "$INCREMENT_BOOT_PARTITION_SIZE_IN_BYTES")
    total_block_count=$(/usr/sbin/tune2fs -l "$device" | /usr/bin/awk '/Block count:/{print $3}')
    new_fs_size_in_blocks=$(( total_block_count + increment_boot_partition_in_blocks ))
    if [[ "$BOOT_FS_TYPE" == "ext4" ]]; then
        ret=$(/usr/sbin/resize2fs "$device" $new_fs_size_in_blocks 2>&1)
        status=$?
    elif [[ "$BOOT_FS_TYPE" == "xfs" ]]; then
        ret=$(/usr/sbin/xfs_growfs "$device" -D $new_fs_size_in_blocks 2>&1)
        status=$?
    else
        echo "Device $device does not contain an ext4 or xfs file system: $BOOT_FS_TYPE"
        exit 1
    fi
    if [[ $status -ne 0 ]]; then
        echo "Failed to resize boot partition '$device': $ret"
        exit $status
    fi
}

function activate_volume_group(){
    local device=$DEVICE_NAME$ADJACENT_PARTITION_NUMBER
    device_type=$(get_device_type "$device")
    if [[ $device_type == "lvm" ]]; then
        local volume_group_name
        volume_group_name=$(get_volume_group_name)
        ret=$(/usr/sbin/vgchange -ay "$volume_group_name" 2>&1)
        status=$?
        if [[ $status -ne 0 ]]; then
            echo "Failed to activate volume group $volume_group_name: $ret"
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
    shift_adjacent_partition
    extend_boot_partition
    cleanup
}

main "$@"