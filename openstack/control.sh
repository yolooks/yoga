#!/bin/bash

# 当前脚本放在/data0/service/openstack
# 安装虚拟机放在/data0/yoga

function environment {
    # brctl
    wget https://vault.centos.org/7.9.2009/os/x86_64/Packages/bridge-utils-1.5-9.el7.x86_64.rpm
    rpm -ivh bridge-utils-1.5-9.el7.x86_64.rpm
    echo "\n"

    # libvirt
    yum install -y qemu-kvm libvirt virt-manager virt-install libguestfs-tools
    service libvirtd restart
    service libvirtd status
}

function createVM {
    index=$1                      # 类型-下划线格式的ip
    vmCpu=$2
    vmMem=$(($3 * 1024 * 1024))
    vmDisk=$4
    vmBridge=$5

    prefix="yoga-"                # 虚拟机名称前缀
    vmName="${prefix}${index}"

    echo "index=$index"
    echo "cpu=$vmCpu"
    echo "mem=$vmMem(KB)"
    echo "disk=$vmDisk"
    echo "bridge=$vmBridge"
    echo "vm name=$vmName"
    echo "\n"

    dataDir="/data0/yoga"
    if [ ! -d $dataDir ]; then
        mkdir $dataDir
    fi

    vmDir="${dataDir}/${vmName}"
    if [ ! -d $vmDir ]; then
        mkdir $vmDir
    fi

    template="template.xml"
    vmFile="${vmDir}/${vmName}.xml"
    cp $template $vmFile

    sed -i "s/%VM_NAME%/$vmName/g" $vmFile
    sed -i "s/%VM_CPU%/$vmCpu/g" $vmFile
    sed -i "s/%VM_MEM%/$vmMem/g" $vmFile

    imagePath="${vmDir}/${vmDisk}"
    if [ ! -f $imagePath ]; then
        cp $vmDisk $imagePath
    fi
    sed -i "s@%VM_QCOW2_IMAGE_PATH%@$imagePath@g" $vmFile

    sed -i "s/%VM_BRIDGE%/$vmBridge/g" $vmFile

    virsh define $vmFile
    virt-sysprep -d $vmName --operations=-ssh-hostkeys,-ssh-userdir

    virsh start $vmName
    echo -e "\033[1;32m虚拟机: $vmName创建完毕....\033[0m"

    virsh list --all
}

environment
createVM $1 $2 $3 $4 $5

