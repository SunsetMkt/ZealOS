#!/bin/sh

# Build OS using AUTO.ISO minimal auto-install as bootstrap to merge codebase, recompile system, attempt build limine UEFI hybrid ISO

# make sure we are in the correct directory
SCRIPT_DIR=$(realpath "$(dirname "$0")")
SCRIPT_NAME=$(basename "$0")
EXPECTED_DIR=$(realpath "$PWD")

if test "${EXPECTED_DIR}" != "${SCRIPT_DIR}"
then
	( cd "$SCRIPT_DIR" || exit ; "./$SCRIPT_NAME" "$@" );
	exit
fi

[ "$1" = "--headless" ] && QEMU_HEADLESS='-display none'
SUDO='none'
command -v doas && $SUDO=doas
command -v sudo&& $SUDO=sudo
if [ "$SUDO" = "none" ] ; then
  echo 'No sudo or doas installed. Cannot proceed.'
  exit 1
fi

KVM=''
(lsmod | grep -q kvm) && KVM=',accel=kvm'

# Set this true if you want to test ISOs in QEMU after building.
TESTING=false

TMPDIR="/tmp/zealtmp"
TMPISODIR="$TMPDIR/iso"
TMPDISK="$TMPDIR/ZealOS.raw"
TMPMOUNT="$TMPDIR/mnt"

# Change this if your default QEMU version does not work and you have installed a different version elsewhere.
QEMU_BIN_PATH=$(dirname "$(which qemu-system-x86_64)")

mount_tempdisk() {
	$SUDO modprobe nbd
	$SUDO $QEMU_BIN_PATH/qemu-nbd -c /dev/nbd0 -f raw $TMPDISK
	$SUDO partprobe /dev/nbd0
	$SUDO mount /dev/nbd0p1 $TMPMOUNT
}

umount_tempdisk() {
	sync
	$SUDO umount $TMPMOUNT
	$SUDO $QEMU_BIN_PATH/qemu-nbd -d /dev/nbd0
}

[ ! -d $TMPMOUNT ] && mkdir -p $TMPMOUNT
[ ! -d $TMPISODIR ] && mkdir -p $TMPISODIR

set -e
echo "Building ZealBooter..."
( cd ../zealbooter && make distclean all || echo "ERROR: ZealBooter build failed !")
set +e

echo "Making temp vdisk, running auto-install ..."
$QEMU_BIN_PATH/qemu-img create -f raw $TMPDISK 1024M
$QEMU_BIN_PATH/qemu-system-x86_64 -machine q35$KVM -drive format=raw,file=$TMPDISK -m 1G -rtc base=localtime -smp 4 -cdrom AUTO.ISO -device isa-debug-exit $QEMU_HEADLESS

echo "Copying all src/ code into vdisk Tmp/OSBuild/ ..."
rm ../src/Home/Registry.ZC 2> /dev/null
rm ../src/Home/MakeHome.ZC 2> /dev/null
rm ../src/Boot/Kernel.ZXE 2> /dev/null
mount_tempdisk
$SUDO mkdir $TMPMOUNT/Tmp/OSBuild/
$SUDO cp -r ../src/* $TMPMOUNT/Tmp/OSBuild
umount_tempdisk

echo "Rebuilding kernel headers, kernel, OS, and building Distro ISO ..."
$QEMU_BIN_PATH/qemu-system-x86_64 -machine q35$KVM -drive format=raw,file=$TMPDISK -m 1G -rtc base=localtime -smp 4 -device isa-debug-exit $QEMU_HEADLESS

LIMINE_BINARY_BRANCH="v4.x-branch-binary"

if [ -d "limine" ]
then
	cd limine
	git remote set-branches origin $LIMINE_BINARY_BRANCH
	git fetch
	git remote set-head origin $LIMINE_BINARY_BRANCH
	git switch $LIMINE_BINARY_BRANCH
	git pull
	rm limine-deploy
	rm limine-version

	cd ..
fi
if [ ! -d "limine" ]; then
    git clone https://github.com/limine-bootloader/limine.git --branch=$LIMINE_BINARY_BRANCH --depth=1
fi
make -C limine

touch limine/Limine-HDD.HH
echo "/*\$WW,1\$" > limine/Limine-HDD.HH
cat limine/LICENSE.md >> limine/Limine-HDD.HH
echo "*/\$WW,0\$" >> limine/Limine-HDD.HH
cat limine/limine-hdd.h >> limine/Limine-HDD.HH
sed -i 's/const uint8_t/U8/g' limine/Limine-HDD.HH
sed -i "s/\[\]/\[$(grep -o "0x" ./limine/limine-hdd.h | wc -l)\]/g" limine/Limine-HDD.HH

mount_tempdisk
echo "Extracting MyDistro ISO from vdisk ..."
cp $TMPMOUNT/Tmp/MyDistro.ISO.C ./ZealOS-MyDistro.iso
$SUDO rm $TMPMOUNT/Tmp/MyDistro.ISO.C 2> /dev/null
echo "Setting up temp ISO directory contents for use with limine xorriso command ..."
$SUDO cp -rf $TMPMOUNT/* $TMPISODIR
$SUDO rm $TMPISODIR/Boot/OldMBR.BIN 2> /dev/null
$SUDO rm $TMPISODIR/Boot/BootMHD2.BIN 2> /dev/null
$SUDO mkdir -p $TMPISODIR/EFI/BOOT
$SUDO cp limine/Limine-HDD.HH $TMPISODIR/Boot/Limine-HDD.HH
$SUDO cp limine/BOOTX64.EFI $TMPISODIR/EFI/BOOT/BOOTX64.EFI
$SUDO cp limine/limine-cd-efi.bin $TMPISODIR/Boot/Limine-CD-EFI.BIN
$SUDO cp limine/limine-cd.bin $TMPISODIR/Boot/Limine-CD.BIN
$SUDO cp limine/limine.sys $TMPISODIR/Boot/Limine.SYS
$SUDO cp ../zealbooter/zealbooter.elf $TMPISODIR/Boot/ZealBooter.ELF
$SUDO cp ../zealbooter/Limine.CFG $TMPISODIR/Boot/Limine.CFG
echo "Copying DVDKernel.ZXE over ISO Boot/Kernel.ZXE ..."
$SUDO mv $TMPMOUNT/Tmp/DVDKernel.ZXE $TMPISODIR/Boot/Kernel.ZXE
$SUDO rm $TMPISODIR/Tmp/DVDKernel.ZXE 2> /dev/null
umount_tempdisk

xorriso -joliet "on" -rockridge "on" -as mkisofs -b Boot/Limine-CD.BIN \
        -no-emul-boot -boot-load-size 4 -boot-info-table \
        --efi-boot Boot/Limine-CD-EFI.BIN \
        -efi-boot-part --efi-boot-image --protective-msdos-label \
        $TMPISODIR -o ZealOS-limine.iso

./limine/limine-deploy ZealOS-limine.iso

if [ "$TESTING" = true ]; then
	if [ ! -d "ovmf" ]; then
	    echo "Downloading OVMF..."
	    mkdir ovmf
	    cd ovmf
	    curl -o OVMF-X64.zip https://efi.akeo.ie/OVMF/OVMF-X64.zip
	    7z x OVMF-X64.zip
	    cd ..
	fi
	echo "Testing limine-zealbooter-xorriso isohybrid boot in UEFI mode ..."
	$QEMU_BIN_PATH/qemu-system-x86_64 -machine q35$KVM -m 1G -rtc base=localtime -bios ovmf/OVMF.fd -smp 4 -cdrom ZealOS-limine.iso $QEMU_HEADLESS
	echo "Testing limine-zealbooter-xorriso isohybrid boot in BIOS mode ..."
	$QEMU_BIN_PATH/qemu-system-x86_64 -machine q35$KVM -m 1G -rtc base=localtime -smp 4 -cdrom ZealOS-limine.iso $QEMU_HEADLESS
	echo "Testing native ZealC MyDistro legacy ISO in BIOS mode ..."
	$QEMU_BIN_PATH/qemu-system-x86_64 -machine q35$KVM -m 1G -rtc base=localtime -smp 4 -cdrom ZealOS-MyDistro.iso $QEMU_HEADLESS
fi

# comment these 2 lines if you want lingering old Distro ISOs
rm ./ZealOS-PublicDomain-BIOS-*.iso 2> /dev/null
rm ./ZealOS-BSD2-UEFI-*.iso 2> /dev/null

mv ./ZealOS-MyDistro.iso ./ZealOS-PublicDomain-BIOS-$(date +%Y-%m-%d-%H_%M_%S).iso
mv ./ZealOS-limine.iso ./ZealOS-BSD2-UEFI-$(date +%Y-%m-%d-%H_%M_%S).iso

echo "Deleting temp folder ..."
$SUDO rm -rf $TMPDIR
$SUDO rm -rf $TMPISODIR
echo "Finished."
echo
echo "ISOs built:"
ls | grep ZealOS-P
ls | grep ZealOS-B
echo
