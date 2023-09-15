# bash-extend-boot-partition
Script to extend the ext4 boot partition using BIOS by reducing the partition size of the adjacent partition by a given amount. It only works with ext4 file systems and supports both standard partitions with ext4 and partitions with LVM hosting ext4 file systems.

The script determines which partition number is the boot partition by looking for the boot flag. This process won't work with an EFI boot partition because the boot partition that contains the kernel and the initramfs are in a partition that does not have the flag.

Usage: extend.sh <device_name> <increase_size>

Example
    `$>resize.sh /dev/vdb 1G`