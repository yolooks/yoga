# 初始化控制节点虚拟机

## 拷贝rocky-8.10镜像

```
cd /data0/service/openstack
wget http://<ip>:<port>/rocky-8.10.qcow2
```

## 安装控制节点虚拟机

```
sh control.sh control-10_110_8_244 8 16 rocky-8.10.qcow2 br1
sh control.sh rabbitmq-10_110_8_246 8 16 rocky-8.10.qcow2 br1
sh control.sh mysql-10_110_8_248 8 16 rocky-8.10.qcow2 br1

virsh domiflist <domain>
brctl show
virsh vncdisplay <domain>
```

## 添加磁盘

```
cd /data0/yoga/<domain>
virsh destroy <domain>
qemu-img resize <disk> +500G
qemu-img info <disk>
virsh start <domain>

fdisk /dev/vda
reboot -h now

mkfs.ext4 /dev/vda2
echo "/dev/vda2 /data0 ext4 defaults 0 0" >> /etc/fstab
mkdir /data0
systemctl daemon-reload
mount -a
```

## ip规划

```
control:
xx.xx.xx.244 -- 物理机1 
xx.xx.xx.245

rabbitmq:
xx.xx.xx.246 -- 物理机1
xx.xx.xx.247

mysql:
xx.xx.xx.248 -- 物理机1 
xx.xx.xx.249
```

## vnc登录修改网卡配置

```
# vim /etc/sysconfig/network-scripts/ifcfg-eth0
BOOTPROTO=static
DEVICE=eth0
ONBOOT=yes
TYPE=Ethernet
IPADDR=<ip>
NETMASK=<netmask>
GATEWAY=<gateway>
```

## 机器修改

```
# hostname
hostnamectl set-hostname sg1-yoga-control00

# dns
echo "nameserver 8.8.8.8" > /etc/resolv.conf
```
