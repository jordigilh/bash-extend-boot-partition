# bash-extend-boot-partition
Script to extend the ext4 boot partition using BIOS by reducing the partition size of the adjacent partition by a given amount. It only works with ext4 file systems and supports both standard partitions with ext4 and partitions with LVM hosting ext4 file systems.

The script determines which partition number is the boot partition by looking for the boot flag. This process won't work with an EFI boot partition because the boot partition that contains the kernel and the initramfs are in a partition that does not have the flag.

Usage: extend.sh <device_name> <increase_size>

Example
    `$>resize.sh /dev/vdb 1G`


# Dependencies
This script requires the following binaries to work:
* /usr/sbin/resize2fs
* /usr/bin/awk
* /usr/sbin/tune2fs
* /usr/sbin/sfdisk (=> v2.38.1)
* /usr/sbin/partprobe
* /usr/sbin/pvresize
* /usr/sbin/parted
* /usr/bin/sed
* /usr/sbin/pvs
* /usr/bin/numfmt
* /usr/sbin/pvdisplay
* /usr/sbin/pvmove
* /usr/sbin/lvreduce
* /usr/bin/lsblk
* /usr/sbin/e2fsck
* /usr/sbin/fdisk
* /usr/bin/findmnt
* /usr/bin/wc

# Building sfdisk from the source
There are known issues with the `move-data` flag in `sfdisk` prior to v2.38.1 that could cause loss of data when performing the move operation. If your environment lacks a version of `sfdisk` equal or greater than v2.38.1 you will need to update it to a version equal or greater than 2.38.1. In case of older systems where there are no prebuild rpms available, you'll need to build it directly from the source.  

Here are the recommended steps to install `sfdisk` version 2.38.1 in your environment from the source directly.

* Download and untar the source code for v2.38.1 (this is the last version that works well with CentOS and RHEL 7 due to issues with the configuration (see https://wiki.strongswan.org/issues/3406)
```
[root@localhost ~]# wget https://github.com/util-linux/util-linux/archive/refs/tags/v2.38.1.tar.gz
```

* Install the required dependencies as listed when running the `autogen.sh` using your preferred package manager:
```
[root@localhost ~]# yum install gettext-devel libtool bison automake -y
```

* Run the `autogen.sh` command in the unpacked `util-linux` directory:
```
[root@localhost ~]# cd util-linux-2.38.1/
[root@localhost ~]# ./autogen.sh
```

* Configure the build to enable statically linked binaries:
```
[root@localhost ~]# ./configure --enable-static-programs=sfdisk
```

* Run the make command to generate the binary:
```
[root@localhost ~]# make sfdisk.static
```

* Replace your existing `sfdisk` with the new binary:
```
[root@localhost ~]# cp sfdisk.static /usr/bin/sfdisk
```