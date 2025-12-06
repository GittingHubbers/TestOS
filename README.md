# TestOS

A DOS-like 32-bit operating system built from scratch, featuring a custom bootloader, FAT12 filesystem, protected-mode kernel, command-line shell, and file editor.

---

## 🚀 Getting Started

Follow the steps below to build the OS image and launch it in QEMU.

### 1. Build the OS Image

Run the project Makefile to assemble the bootloader, kernel, and generate the FAT12 disk image:

```bash
make
```

### 2. Run the QEMU Command listed in 'qemu command.txt'
Note: Please be sure to have QEMU installed.
```bash
qemu-system-i386 -device piix3-ide,id=ide -drive id=disk,file=build/main.img,format=raw,if=none -device ide-hd,drive=disk,bus=ide.0,unit=0,cyls=80,heads=2,secs=18 -boot c -m 256 -no-reboot -no-shutdown
```
