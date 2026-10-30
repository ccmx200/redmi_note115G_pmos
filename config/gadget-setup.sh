# 在 initramfs 里通过 configfs 建立 USB 网络 gadget。
#
# 先试 CDC-NCM（包聚合，比 RNDIS 快 2-3 倍），失败就退回 RNDIS。
# 两个都是 configfs 函数，不依赖内建的 g_ether，所以失败也不会让手机失联。
setup_usb_gadget() {
    mount -t configfs none /sys/kernel/config 2>/dev/null
    G=/sys/kernel/config/usb_gadget/evergo
    UDC=$(ls /sys/class/udc 2>/dev/null | head -1)
    [ -z "$UDC" ] && { log "gadget: no UDC"; return 1; }

    # 清掉上一次的残留
    if [ -d "$G" ]; then
        [ -e "$G/UDC" ] && echo "" > "$G/UDC" 2>/dev/null
        find "$G/configs" -type l -delete 2>/dev/null
        rm -rf "$G"/functions/* "$G"/configs/* "$G"/strings/* 2>/dev/null
        rmdir "$G" 2>/dev/null
    fi
    mkdir -p "$G" || return 1
    cd "$G" || return 1

    echo 0x1d6b > idVendor
    echo 0x0104 > idProduct
    echo 0x0200 > bcdUSB
    echo 0x0100 > bcdDevice
    mkdir -p strings/0x409
    echo "evergo" > strings/0x409/manufacturer
    echo "evergo" > strings/0x409/product
    echo "0001" > strings/0x409/serialnumber
    mkdir -p configs/c.1/strings/0x409
    echo "evergo network" > configs/c.1/strings/0x409/configuration
    echo 250 > configs/c.1/MaxPower

    for fn in ncm rndis; do
        if [ ! -d "functions/$fn.usb0" ]; then
            mkdir -p "functions/$fn.usb0" 2>/dev/null || { log "gadget: $fn unsupported"; continue; }
        fi
        echo "02:11:22:33:44:55" > "functions/$fn.usb0/host_addr" 2>/dev/null
        echo "02:11:22:33:44:56" > "functions/$fn.usb0/dev_addr" 2>/dev/null
        ln -sf "functions/$fn.usb0" configs/c.1/ 2>/dev/null
        if echo "$UDC" > UDC 2>/dev/null; then
            log "gadget: $fn bound to $UDC"
            # 等网卡出现
            i=0
            while [ $i -lt 20 ]; do
                [ -e /sys/class/net/usb0 ] && { delay 1; [ -e /sys/class/net/usb0 ] && return 0; }
                delay 1
                i=$((i+1))
            done
            log "gadget: $fn did not create usb0, trying next"
        else
            log "gadget: $fn UDC bind FAILED"
        fi
        # 失败，拆掉再试下一个
        echo "" > UDC 2>/dev/null
        rm -f "configs/c.1/$fn.usb0" 2>/dev/null
        rm -rf "functions/$fn.usb0" 2>/dev/null
    done
    return 1
}
