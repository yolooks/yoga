#!/bin/bash

usage() {
    echo "Usage: sh compute.sh -i <本机IP> -n <nic> -r <region> -v <vip> -t <token> -u <rabbitmq_user> -p <rabbitmq_pass> -h <rabbitmq_host>"
    echo "  -i    本机IP地址（必填，格式如 10.110.96.5）"
    echo "  -n    物理网卡名称（必填）"
    echo "  -r    region名称（必填）"
    echo "  -v    虚拟IP（VIP）（必填）"
    echo "  -t    Keystone Token（必填）"
    echo "  -u    RabbitMQ 用户名（必填）"
    echo "  -p    RabbitMQ 密码（必填）"
    echo "  -h    RabbitMQ 主机IP地址（必填）"
    exit 1
}

my_ip=""          # 宿主机ip
nic=""            # 物理网卡(控制节点:eth0 计算节点:bond1)
region=""         # 当前计算节点所属集群区域
vip=""            # 控制节点虚ip
token=""          # keystone 秘钥
rabbitmq_user=""
rabbitmq_pass=""
rabbitmq_host=""

while getopts ":i:n:r:v:t:u:p:h:" opt; do
    case $opt in
        i) my_ip="$OPTARG" ;;
        n) nic="$OPTARG" ;;
        r) region="$OPTARG" ;;
        v) vip="$OPTARG" ;;
        t) token="$OPTARG" ;;
        u) rabbitmq_user="$OPTARG" ;;
        p) rabbitmq_pass="$OPTARG" ;;
        h) rabbitmq_host="$OPTARG" ;;
        *) usage ;;
    esac
done

[ -z "$my_ip" ] && echo "错误: 本机IP (-i) 必须指定" && usage
[ -z "$nic" ] && echo "错误: 网卡 (-n) 必须指定" && usage
[ -z "$region" ] && echo "错误: Region (-r) 必须指定" && usage
[ -z "$vip" ] && echo "错误: 虚拟IP (-v) 必须指定" && usage
[ -z "$token" ] && echo "错误: Keystone Token (-t) 必须指定" && usage
[ -z "$rabbitmq_user" ] && echo "错误: RabbitMQ 用户 (-u) 必须指定" && usage
[ -z "$rabbitmq_pass" ] && echo "错误: RabbitMQ 密码 (-p) 必须指定" && usage
[ -z "$rabbitmq_host" ] && echo "错误: RabbitMQ 主机 (-h) 必须指定" && usage

function print_param {
	echo "参数确认:"
    echo "my_ip=$my_ip"
    echo "nic=$nic"
    echo "region=$region"
    echo "vip=$vip"
    echo "token=$token"
    echo "rabbitmq_user=$rabbitmq_user"
    echo "rabbitmq_pass=$rabbitmq_pass"
    echo "rabbitmq_host=$rabbitmq_host"
}

function info {
    echo -e "\033[0;32m[INFO] $*\033[0m"
}

function error {
    echo -e "\033[0;31m[ERROR] $*\033[0m"
}

function install_openstack_yoga_package {
    info "关闭防火墙"
    systemctl stop firewalld.service
    systemctl status firewalld.service
    getenforce

    info "安装openstack yoga包"
    dnf install -y centos-release-openstack-yoga.noarch
    dnf install -y python3-openstackclient
    dnf install -y openstack-selinux
    info "查询openstack yoga包"
    rpm -qa | grep openstack

    info "修改yum源, 适配rocky linux"
    if [ ! -d /etc/yum.repos.d/backup ]; then
        mkdir /etc/yum.repos.d/backup
    fi
    mv /etc/yum.repos.d/CentOS-Advanced-Virtualization.repo /etc/yum.repos.d/backup
    mv /etc/yum.repos.d/CentOS-Ceph-Pacific.repo /etc/yum.repos.d/backup
    mv /etc/yum.repos.d/CentOS-Messaging-rabbitmq.repo /etc/yum.repos.d/backup
    mv /etc/yum.repos.d/CentOS-NFV-OpenvSwitch.repo /etc/yum.repos.d/backup
    mv /etc/yum.repos.d/CentOS-Storage-common.repo /etc/yum.repos.d/backup

    yoga_repo_file="/etc/yum.repos.d/CentOS-OpenStack-yoga.repo"
    sed -i 's|^mirrorlist=|#mirrorlist=|g' $yoga_repo_file
    sed -i '/^#mirrorlist=/a baseurl=http://vault.centos.org/8-stream/cloud/x86_64/openstack-yoga/' $yoga_repo_file
    info "安装openstack yoga 包完成"
}

function install_nova_compute {
    info "1.安装openvswitch-selinux-extra-policy"
    cd /tmp && wget https://download.rockylinux.org/vault/centos/8-stream/nfv/x86_64/openvswitch-2/Packages/o/openvswitch-selinux-extra-policy-1.0-29.el8s.noarch.rpm
    cd /tmp && dnf install -y ./openvswitch-selinux-extra-policy-1.0-29.el8s.noarch.rpm

    info "2.安装openvswitch2.17版本"
    cd /tmp && wget https://download.rockylinux.org/vault/centos/8-stream/nfv/x86_64/openvswitch-2/Packages/o/openvswitch2.17-2.17.0-170.el8s.x86_64.rpm
    cd /tmp && dnf install -y ./openvswitch2.17-2.17.0-170.el8s.x86_64.rpm

    info "3.安装network-scripts-openvswitch2.17版本"
    cd /tmp && wget https://download.rockylinux.org/vault/centos/8-stream/nfv/x86_64/openvswitch-2/Packages/n/network-scripts-openvswitch2.17-2.17.0-170.el8s.x86_64.rpm
    cd /tmp && dnf install -y ./network-scripts-openvswitch2.17-2.17.0-170.el8s.x86_64.rpm

    info "4.安装python3-openvswitch2.17版本"
    cd /tmp && wget https://download.rockylinux.org/vault/centos/8-stream/nfv/x86_64/openvswitch-2/Packages/p/python3-openvswitch2.17-2.17.0-170.el8s.x86_64.rpm
    cd /tmp && dnf install -y ./python3-openvswitch2.17-2.17.0-170.el8s.x86_64.rpm

    info "5.安装rdo-openvswitch-2.17版本"
    cd /tmp && wget https://vault.centos.org/8-stream/cloud/x86_64/openstack-yoga/Packages/r/rdo-openvswitch-2.17-3.el8.noarch.rpm
    cd /tmp && dnf install -y ./rdo-openvswitch-2.17-3.el8.noarch.rpm

    info "6.安装python3-rdo-openvswitch-2.17版本"
    cd /tmp && wget https://vault.centos.org/8-stream/cloud/x86_64/openstack-yoga/Packages/p/python3-rdo-openvswitch-2.17-3.el8.noarch.rpm
    cd /tmp && dnf install -y ./python3-rdo-openvswitch-2.17-3.el8.noarch.rpm

    info "7.安装python3-os-vif-2.7.1版本"
    cd /tmp && wget https://vault.centos.org/8-stream/cloud/x86_64/openstack-yoga/Packages/p/python3-os-vif-2.7.1-1.el8.noarch.rpm
    cd /tmp && dnf install -y ./python3-os-vif-2.7.1-1.el8.noarch.rpm

	info "8.安装libaec(提供libsz.so.2)"
	cd /tmp && wget https://download.rockylinux.org/vault/centos/8-stream/PowerTools/x86_64/os/Packages/libaec-1.0.2-3.el8.x86_64.rpm
    cd /tmp && dnf install -y ./libaec-1.0.2-3.el8.x86_64.rpm

    info "9.安装hdf5"
    cd /tmp && https://download.rockylinux.org/vault/centos/8-stream/cloud/x86_64/openstack-yoga/Packages/h/hdf5-1.10.5-5.el8.x86_64.rpm
    cd /tmp && dnf install -y ./hdf5-1.10.5-5.el8.x86_64.rpm

    info "10.安装python3-tables"
    cd /tmp && wget https://download.rockylinux.org/vault/centos/8-stream/cloud/x86_64/openstack-yoga/Packages/p/python3-tables-3.5.2-6.el8.x86_64.rpm
    cd /tmp && dnf install -y ./python3-tables-3.5.2-6.el8.x86_64.rpm

    info "11.安装python3-pandas"
    cd /tmp && wget https://download.rockylinux.org/vault/centos/8-stream/cloud/x86_64/openstack-yoga/Packages/p/python3-pandas-0.25.3-1.el8.x86_64.rpm
    cd /tmp && dnf install -y ./python3-pandas-0.25.3-1.el8.x86_64.rpm

    info "12.安装python3-networkx"
    cd /tmp && wget https://download.rockylinux.org/vault/centos/8-stream/cloud/x86_64/openstack-yoga/Packages/p/python3-networkx-2.5-1.el8.noarch.rpm
    cd /tmp && dnf install -y ./python3-networkx-2.5-1.el8.noarch.rpm

    info "13.安装python3-taskflow"
    cd /tmp && wget https://download.rockylinux.org/vault/centos/8-stream/cloud/x86_64/openstack-yoga/Packages/p/python3-taskflow-4.6.4-1.el8.noarch.rpm
    cd /tmp && dnf install -y ./python3-taskflow-4.6.4-1.el8.noarch.rpm

    info "14.安装openstack nova组件"
    dnf install -y openstack-nova-compute

    info "15.安装libvirt组件"
    dnf install -y qemu-kvm qemu-img libvirt virt-manager virt-install libvirt-client libguestfs-tools
}

function config_nova {
    nova_file="/etc/nova/nova.conf"
    info "1.修改[DEFAULT]配置"
    sed -i 's|^#enabled_apis=.*|enabled_apis=osapi_compute,metadata|' $nova_file
    sed -i "831s|^#transport_url=.*|transport_url=rabbit://$rabbitmq_user:$rabbitmq_pass@$rabbitmq_host:5672/|" $nova_file
    sed -i "s|^#my_ip=.*|my_ip=$my_ip|" $nova_file
    sed -i "s|^#compute_driver=.*|compute_driver=libvirt.LibvirtDriver|" $nova_file
    sed -i "s|^#log_file=.*|log_file=/var/log/nova/nova-compute.log|" $nova_file
    sed -i "692s|^#log_dir=.*|log_dir=/var/log/nova|" $nova_file
    sed -i "s|^#reserved_host_cpus=.*|reserved_host_cpus=7|" $nova_file
    sed -i "s|^#reserved_host_memory_mb=.*|reserved_host_memory_mb=20480|" $nova_file
    sed -i "s|^#reserved_host_disk_mb=.*|reserved_host_disk_mb=512000|" $nova_file
    sed -i "s|^#cpu_allocation_ratio=.*|cpu_allocation_ratio=1.0|" $nova_file
    sed -i "s|^#ram_allocation_ratio=.*|ram_allocation_ratio=1.0|" $nova_file
    sed -i "s|^#disk_allocation_ratio=.*|disk_allocation_ratio=1.0|" $nova_file
    sed -i "s|^#service_down_time=.*|service_down_time=60|" $nova_file
    sed -i "s|^#rpc_response_timeout=.*|rpc_response_timeout=60|" $nova_file
    sed -i "s|^#resume_guests_state_on_host_boot=.*|resume_guests_state_on_host_boot=true|" $nova_file
    sed -i "s|^#dhcp_domain=.*|dhcp_domain=|" $nova_file

    info "2.修改[vnc]配置"
    sed -i "5432s|^#enabled=.*|enabled=true|" $nova_file
    sed -i "5438s|^#server_listen=.*|server_listen=\$my_ip|" $nova_file
    sed -i "5443s|^#server_proxyclient_address=.*|server_proxyclient_address=\$my_ip|" $nova_file
    sed -i "s|^#novncproxy_base_url=.*|novncproxy_base_url=http://$vip:6080/vnc_auto.html|" $nova_file

    info "3.修改[glance]配置"
    sed -i "s|^#api_servers=.*|api_servers=http://$vip:9292|" $nova_file

    info "4.修改nova instance配置"
    nova_dir="/data0/nova"
    if [ ! -d $nova_dir ]; then
        mkdir -p $nova_dir/{buckets,instances,keys,networks,tmp}
        chown -R nova:nova $nova_dir
    fi
    sed -i "s|^#state_path=.*|state_path=/data0/nova|" $nova_file
    sed -i "s|^#lock_path=.*|lock_path=/data0/nova/tmp|" $nova_file

    info "5.修改[api]配置"
    sed -i "s|^#auth_strategy=.*|auth_strategy=keystone|" $nova_file

    info "6.修改[libvirt]网卡多队列最大值"
    sed -i "s|^#max_queues=.*|max_queues=64|" $nova_file

    info "7.修改[keystone_authtoken]配置"
    sed -i "/^\[keystone_authtoken\]/a\
www_authenticate_uri=http://$vip:5000\n\
auth_url=http://$vip:5000\n\
memcached_servers=$vip:11211\n\
auth_type=password\n\
project_domain_name=Default\n\
user_domain_name=Default\n\
project_name=service\n\
username=nova\n\
password=$token" $nova_file

    info "8.修改[placement]配置"
    sed -i "/^\[placement\]/a\
region_name=$region\n\
project_domain_name=Default\n\
project_name=service\n\
auth_type=password\n\
user_domain_name=Default\n\
auth_url=http://$vip:5000/v3\n\
username=placement\n\
password=$token" $nova_file

    info "9.查看修改完的nova配置"
    grep -Ev '^$|^#' $nova_file
}

function boot_nova {
    info "启动libvirt和nova-compute"
    systemctl enable libvirtd.service openstack-nova-compute.service
    systemctl start libvirtd.service openstack-nova-compute.service
    systemctl status libvirtd.service openstack-nova-compute.service
}

function install_neutron_compute {
    info "安装neutron网络"
    dnf install -y openstack-neutron-linuxbridge ebtables ipset
}

function config_neutron {
    neutron_file="/etc/neutron/neutron.conf"

    info "1.修改[DEFAULT]配置"
    neutron_dir="/data0/neutron"
    if [ ! -d $neutron_dir ]; then
        mkdir -p $neutron_dir/{buckets,instances,keys,networks,tmp}
        chown -R neutron:neutron $neutron_dir
    fi
    sed -i "s|^#state_path =.*|state_path = $neutron_dir|" $neutron_file
    sed -i "s|^#core_plugin =.*|core_plugin = ml2|" $neutron_file
    sed -i "s|^#service_plugins =.*|service_plugins =|" $neutron_file
    sed -i "s|^#dhcp_agents_per_network =.*|dhcp_agents_per_network = 2|" $neutron_file
    sed -i "518s|^#transport_url =.*|transport_url = rabbit://$rabbitmq_user:$rabbitmq_pass@$rabbitmq_host:5672/|" $neutron_file
    sed -i "s|^#auth_strategy =.*|auth_strategy = keystone|" $neutron_file
    sed -i "s|^#notify_nova_on_port_status_changes =.*|notify_nova_on_port_status_changes = true|" $neutron_file
    sed -i "s|^#notify_nova_on_port_data_changes =.*|notify_nova_on_port_data_changes = true|" $neutron_file
    sed -i "s|^#dns_domain =.*|dns_domain =|" $neutron_file

    info "2.修改[keystone_authtoken]"
    sed -i "/^\[keystone_authtoken\]/a\
www_authenticate_uri = http://$vip:5000\n\
auth_url = http://$vip:5000\n\
memcached_servers = $vip:11211\n\
auth_type = password\n\
project_domain_name = Default\n\
user_domain_name = Default\n\
project_name = service\n\
username = neutron\n\
password = $token" $neutron_file

    info "3.修改[oslo_concurrency]"
    sed -i "/^\[oslo_concurrency\]/a\
lock_path = $neutron_dir/tmp" $neutron_file

    info "查看修改完的neutron_file配置"
    grep -Ev '^$|^#' $neutron_file
}

function config_linuxbridge {
    bridge_file="/etc/neutron/plugins/ml2/linuxbridge_agent.ini"

    info "1.配置[linux_bridge]配置"
    sed -i "s|^#physical_interface_mappings =.*|physical_interface_mappings = provider:$nic|" $bridge_file

    info "2.配置[securitygroup]"
    sed -i "s|^#enable_security_group =.*|enable_security_group = false|" $bridge_file
    sed -i "s|^#enable_ipset =.*|enable_ipset = false|" $bridge_file

    info "3.配置[vxlan]"
    sed -i "s|^#enable_vxlan =.*|enable_vxlan = false|" $bridge_file

    info "查看修改完的linuxbridge配置"
    grep -Ev '^$|^#' $bridge_file
}

function config_nova_neutron {
    info "修改nova配置"
    nova_file="/etc/nova/nova.conf"

    info "修改[neutron]配置"
    sed -i "/^\[neutron\]/a\
auth_url = http://$vip:5000\n\
auth_type = password\n\
project_domain_name = Default\n\
user_domain_name = Default\n\
region_name = $region\n\
project_name = service\n\
username = neutron\n\
password = $token" $nova_file

    info "查看修改完的nova配置"
    grep -Ev '^$|^#' $nova_file
}

function boot_neutron {
    info "重启nova-compute服务"
    systemctl restart openstack-nova-compute.service

    info "启动linuxbridge-agent"
    systemctl enable neutron-linuxbridge-agent.service
    systemctl start neutron-linuxbridge-agent.service

    info "查看nova-compute 与 linuxbridge-agent"
    systemctl status openstack-nova-compute.service
    systemctl status neutron-linuxbridge-agent.service
}

function close_filterref_for_vip {
    info "注释nova/virt/libvirt/config.py中的filterref, 保证虚ip不受ebtables限制"

    libvirt_config_file="/lib/python3.6/site-packages/nova/virt/libvirt/config.py"
    sed -i '1864,1870 s/^/# /' $libvirt_config_file

    info "去掉ebtalbes中的arp防护规则"
    bridge_file="/lib/python3.6/site-packages/neutron/plugins/ml2/drivers/linuxbridge/agent/arp_protect.py"
    sed -i '/def ebtables(comm, table=.*/{
n; s/^/#/;
n; s/^/#/;
n; s/^/#/;
a\    return ""
}' $bridge_file

    info "重启nova-compute"
    systemctl restart openstack-nova-compute.service neutron-linuxbridge-agent.service
    systemctl status openstack-nova-compute.service neutron-linuxbridge-agent.service
}

function set_nova_sshkey {
    info "为nova用户添加免密认证, 以实现虚拟机迁移"
    tar zxf ssh.tar.gz -C /var/lib/nova/ && chown -R nova:nova /var/lib/nova/.ssh/
}

print_param
install_openstack_yoga_package
install_nova_compute
config_nova
boot_nova
install_neutron_compute
config_neutron
config_linuxbridge
config_nova_neutron
boot_neutron
close_filterref_for_vip
set_nova_sshkey
