@echo off
REM Flash the evergo images from Windows.
REM boot.img alone is enough - it carries the rootfs and installs it on first boot.

setlocal
cd /d "%~dp0.."

if not exist "out\boot.img" (
    echo out\boot.img missing - run build.sh first
    exit /b 1
)

echo == checking for the device
fastboot devices

echo == flashing boot_b
fastboot flash boot_b out\boot.img
if errorlevel 1 goto fail

echo == switching to slot b
fastboot --set-active=b
fastboot reboot

echo.
echo == after reboot
echo The phone runs mainline Linux with no on-screen console.
echo Plug it into this PC and open the new COM port at 115200 8N1.
echo The first boot takes about a minute while it copies the rootfs.
echo.
echo To return to Android:  fastboot --set-active=a
goto :eof

:fail
echo flashing failed
exit /b 1
