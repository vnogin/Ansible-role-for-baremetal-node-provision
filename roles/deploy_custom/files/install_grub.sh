#!/bin/sh

# code from DIB bash ramdisk
readonly target_disk=$1
readonly root_part=$2
# FIXME Need to distinguish root_boot variavle to block boot device and raid device
readonly root_boot=$3
readonly root_part_mount=/mnt/rootfs
CHROOT_CMD="chroot $root_part_mount /bin/bash -c"
# We need to run partprobe to ensure all partitions are visible
partprobe $target_disk

mkdir -p $root_part_mount

mount $root_part $root_part_mount
if [ $? != "0" ]; then
   echo "Failed to mount root partition $root_part on $root_part_mount"
   exit 1
fi
mkdir -p /tmp/boot
cp -r $root_part_mount/boot/* /tmp/boot/

mkdir -p $root_part_mount/boot
mkdir -p $root_part_mount/dev
mkdir -p $root_part_mount/sys
mkdir -p $root_part_mount/proc
# FIXME need to use raid device instead of block device which is RAID member
mount $root_boot $root_part_mount/boot
mount -o bind /dev $root_part_mount/dev
mount -o bind /sys $root_part_mount/sys
mount -o bind /proc $root_part_mount/proc
mount -o bind /run $root_part_mount/run

cp -r /tmp/boot/*  $root_part_mount/boot/
cp /etc/resolv.conf $root_part_mount/etc/

${CHROOT_CMD} "export DEBIAN_FRONTEND=noninteractive && apt-get -y install lvm2 mdadm"

# Find grub version
V=
if [ -x $root_part_mount/usr/sbin/grub2-install ]; then
    V=2
fi

# Install grub
ret=1
if ${CHROOT_CMD} "/usr/sbin/grub$V-install ${target_disk}"; then
    echo "Generating the grub configuration file"
# FIXME Remove hardcoded path
    cat << EOF > $root_part_mount/etc/grub.d/09_swraid1_setup
#!/bin/sh
exec tail -n +3 $0
# This file provides an easy way to add custom menu entries.  Simply type the
# menu entries you want to add after this comment.  Be careful not to change
# the 'exec tail' line above.
menuentry 'Ubuntu' --class ubuntu --class gnu-linux --class gnu --class os {
        recordfail
        insmod gzio
        insmod part_msdos
        insmod part_msdos
        insmod diskfilter
        insmod mdraid1x
        insmod lvm
        insmod ext2
	insmod ext4
	set root='(md0)'
        linux   /boot/vmlinuz-4.2.0-27-generic root=/dev/mapper/vg0-root_standard ro   nomdmonddf nomdmonisw
        initrd  /boot/initrd.img-4.2.0-27-generic
EOF
# FIXME Remove hardcoded path
# TODO Add SWAP partition to fstab
cat << EOF > $root_part_mount/etc/fstab
/dev/mapper/vg0-root_standard /               ext4    errors=remount-ro 0       1
/dev/md0 /boot           		      ext4    defaults        0       2
EOF

${CHROOT_CMD} "update-grub"
${CHROOT_CMD} "update-initramfs -u"

    # tell GRUB2 to preload its "lvm" module to gain LVM booting on direct-attached disks
    if [ "$V" = "2" ]; then
        echo "GRUB_PRELOAD_MODULES=lvm" >> $root_part_mount/etc/default/grub
    fi
    ${CHROOT_CMD} "/usr/sbin/grub$V-mkconfig -o /boot/grub$V/grub.cfg"
    ret=$?
fi

umount $root_part_mount/boot
umount $root_part_mount/dev
umount $root_part_mount/sys
umount $root_part_mount/proc
umount $root_part_mount/run
umount $root_part_mount

if [ $ret != "0" ]; then
    echo "Installing grub bootloader failed"
fi
exit $ret
