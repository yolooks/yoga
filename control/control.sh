#!/bin/bash

###########################################################
# 官方安装指南: https://docs.openstack.org/install-guide/ #
###########################################################

# 当前控制节点IP
my_ip=$1
if [ -z "$my_ip" ]; then
    echo "当前本机ip必须传递: sh control.sh 本机ip"
    exit 1
fi

# region
region=""

# vip
vip=""
router_id="$(hostname)"

# 物理网卡(控制节点:eth0 计算节点:bond1)
nic="eth0"

# keystone token
token=""

# mysql账号信息
mysql_user="openstack"
mysql_port=3306
mysql_pass=""
mysql_host=""

# rabbitmq账号信息
rabbitmq_user="openstack"
rabbitmq_pass=""
rabbitmq_host=""

function info {
    echo -e "\033[0;32m[INFO] $*\033[0m"
}

function error {
    echo -e "\033[0;31m[ERROR] $*\033[0m"
}

function install_keepalived {
    info "安装keepalived, 配置vip"
    dnf install -y keepalived

cat <<EOF > /etc/keepalived/keepalived.conf
global_defs {
   router_id $router_id
}

vrrp_instance VI_1 {
    state MASTER
    interface eth0
    virtual_router_id 114

    priority 100
    advert_int 1

    authentication {
        auth_type PASS
        auth_pass openstack_yoga
    }

    virtual_ipaddress {
        $vip
    }
}
EOF

    systemctl enable keepalived.service
    systemctl start keepalived.service

    info "查看vip"
    ip a show eth0
}

function install_memcache {
    info "安装memory cache"
    dnf install -y epel-release
    dnf install -y memcached python3-memcached

    info "查询memcached"
    rpm -q memcached python3-memcached
    systemctl enable memcached.service && systemctl start memcached.service
    netstat -antlp | grep memcached
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

function create_database {
    info "安装mysql命令行，并创建相关数据库"
    dnf install -y mariadb mariadb-server python3-PyMySQL
    mysql -h $mysql_host -P $mysql_port -u $mysql_user -p"$mysql_pass" -e "CREATE DATABASE keystone;"
    mysql -h $mysql_host -P $mysql_port -u $mysql_user -p"$mysql_pass" -e "CREATE DATABASE glance;"
    mysql -h $mysql_host -P $mysql_port -u $mysql_user -p"$mysql_pass" -e "CREATE DATABASE placement;"
    mysql -h $mysql_host -P $mysql_port -u $mysql_user -p"$mysql_pass" -e "CREATE DATABASE nova;"
    mysql -h $mysql_host -P $mysql_port -u $mysql_user -p"$mysql_pass" -e "CREATE DATABASE nova_api;"
    mysql -h $mysql_host -P $mysql_port -u $mysql_user -p"$mysql_pass" -e "CREATE DATABASE nova_cell0;"
    mysql -h $mysql_host -P $mysql_port -u $mysql_user -p"$mysql_pass" -e "CREATE DATABASE neutron;"
}

function install_keystone {
    info "安装keystone"
    dnf install -y openstack-keystone httpd python3-mod_wsgi
    keystone_file="/etc/keystone/keystone.conf"
    sed -i "s|^#admin_token =.*|admin_token = $token|" $keystone_file
    sed -i "s|^#connection =.*|connection = mysql+pymysql://$mysql_user:$mysql_pass@$mysql_host/keystone|" $keystone_file
    sed -i '2590s|^#provider = fernet|provider = fernet|' $keystone_file

    su -s /bin/sh -c "keystone-manage db_sync" keystone
    if [ $? -eq 0 ]; then
        info "初始化keystone数据库成功"
    else
        error "初始化keystone数据库失败"
        exit 1
    fi

    keystone-manage fernet_setup --keystone-user keystone --keystone-group keystone
    if [ $? -eq 0 ]; then
        info "初始化Fernet keys成功"
    else
        error "初始化Fernet keys失败"
        exit 1
    fi
    info "验证fernet-keys输出:"
    ls /etc/keystone/fernet-keys/

    keystone-manage credential_setup --keystone-user keystone --keystone-group keystone
    if [ $? -eq 0 ]; then
        info "初始化Credential keys成功"
    else
        error "初始化Credential keys失败"
        exit 1
    fi
    info "验证credential keys输出:"
    ls /etc/keystone/credential-keys/

    info "初始化keystone验证服务"
    keystone-manage bootstrap --bootstrap-password $token \
--bootstrap-admin-url http://$vip:5000/v3/ \
--bootstrap-internal-url http://$vip:5000/v3/ \
--bootstrap-public-url http://$vip:5000/v3/ \
--bootstrap-region-id $region
}

function config_apache {
    sed -i "s|^#ServerName.*|ServerName $vip|" /etc/httpd/conf/httpd.conf
    info "添加ServerName成功"

    ln -s /usr/share/keystone/wsgi-keystone.conf /etc/httpd/conf.d/
    info "httpd添加WSGI成功"

    systemctl enable httpd.service
    systemctl start httpd.service
    info "查看httd监听"
    netstat -antlp | grep httpd
}

function config_admin_openrc {
    filename="/etc/profile.d/admin-openrc.sh"
cat <<EOF > $filename
export OS_USERNAME=admin
export OS_PASSWORD=$token
export OS_PROJECT_NAME=admin
export OS_USER_DOMAIN_NAME=Default
export OS_PROJECT_DOMAIN_NAME=Default
# 认证地址
export OS_AUTH_URL=http://$vip:5000/v3
# keystone版本号
export OS_IDENTITY_API_VERSION=3
# 镜像管理应用版本号
export OS_IMAGE_API_VERSION=2
# compute版本
export OS_COMPUTE_API_VERSION=2.15
EOF

    source $filename
    cat $filename
    info "admin openrc配置完成"

    info "openstack token issue output"
    openstack token issue
    info "openstack service list output"
    openstack service list
}

function config_domain_project_user_role {
    info "显示自动创建的域: default"
    openstack domain list

    info "在default域, 创建service项目"
    openstack project create --domain default --description "Service Project" service

    info "查看创建的项目:"
    openstack project list

    info "查看创建的用户:"
    openstack user list

    info "查看创建的角色:"
    openstack role list

    info "查看admin用户在所有项目下的角色:"
    openstack role assignment list --user admin --names

    info "显示创建的区域:"
    openstack region list

    info "显示自动创建的endpoint:"
    openstack endpoint list
}

function config_glance_user_info {
    info "1.创建glance用户"
    openstack user create --domain default --password $token glance

    info "2.赋予glance用户admin角色和添加到service项目上:"
    openstack role add --project service --user glance admin

    info "3.创建glance服务, 服务类型为image"
    openstack service create --name glance  --description "OpenStack Image" image

    info "4.创建image的public端点"
    openstack endpoint create --region $region image public http://$vip:9292

    info "5.创建image的internal端点"
    openstack endpoint create --region $region image internal http://$vip:9292

    info "6.创建image的admin端点"
    openstack endpoint create --region $region image admin http://$vip:9292

    info "查看glance所有端点:"
    openstack endpoint list --service glance
}

function install_glance {
    # python3-pyxattr
    cd /tmp && wget https://vault.centos.org/8-stream/PowerTools/x86_64/os/Packages/python3-pyxattr-0.5.3-18.el8.x86_64.rpm
    cd /tmp && dnf install -y python3-pyxattr-0.5.3-18.el8.x86_64.rpm

    # python3-networkx → python3-pandas → python3-tables → hdf5 → libsz.so.2 libsz.so.2 是由 libaec 提供
    cd /tmp && wget https://vault.centos.org/8-stream/PowerTools/x86_64/os/Packages/libaec-1.0.2-3.el8.x86_64.rpm
    cd /tmp && wget https://vault.centos.org/8-stream/PowerTools/x86_64/os/Packages/libaec-devel-1.0.2-3.el8.x86_64.rpm
    cd /tmp && dnf install -y libaec-1.0.2-3.el8.x86_64.rpm libaec-devel-1.0.2-3.el8.x86_64.rpm
    dnf install -y python3-networkx
    dnf install -y openstack-glance
}

function config_glance {
    glance_api_file="/etc/glance/glance-api.conf"
    sed -i "s|^#connection =.*|connection = mysql+pymysql://$mysql_user:$mysql_pass@$mysql_host/glance|" $glance_api_file

    image_dir="/data0/glance/images"
    if [ ! -d $image_dir ]; then
        mkdir -p $image_dir
        chown -R glance:nobody /data0/glance/
        chown -R glance:glance /data0/glance/images/
    fi
    sed -i "s|^#stores =.*|stores = file,http|" $glance_api_file
    sed -i "s|^#default_store =.*|default_store = file|" $glance_api_file
    sed -i "3625s|^#filesystem_store_datadir =.*|filesystem_store_datadir = $image_dir|" $glance_api_file

    sed -i "/^\[keystone_authtoken\]/a\
www_authenticate_uri = http://$vip:5000\n\
auth_url = http://$vip:5000\n\
memcached_servers = $vip:11211\n\
auth_type = password\n\
project_domain_name = Default\n\
user_domain_name = Default\n\
project_name = service\n\
username = glance\n\
password = $token" $glance_api_file
    sed -i "s|^#flavor =.*|flavor = keystone|" $glance_api_file
    info "查看修改完的glance-api配置"
    grep -Ev '^$|^#' $glance_api_file
}

function boot_glance {
    info "初始化数据库"
    su -s /bin/sh -c "glance-manage db_sync" glance
    if [ $? -ne 0 ]; then
        error "执行数据库失败"
        exit 1
    fi

    info "启动glance-api服务"
    systemctl enable openstack-glance-api.service
    systemctl start openstack-glance-api.service
    info "查看glance监听端口"
    etstat -antlp | grep LISTEN | grep python
}

function config_placement_user {
    info "1.创建placement service用户"
    openstack user create --domain default --password $token placement

    info "2.将placement用户添加到具有admin角色的service项目中"
    openstack role add --project service --user placement admin

    info "3.创建placement service项目"
    openstack service create --name placement --description "Placement API" placement

    info "4.创建placement api端点"
    openstack endpoint create --region $region placement public http://$vip:8778
    openstack endpoint create --region $region placement internal http://$vip:8778
    openstack endpoint create --region $region placement admin http://$vip:8778

    info "5.查看placement所有端点"
    openstack endpoint list --service placement
}

function config_placement {
    dnf install -y openstack-placement-api

    placement_file="/etc/placement/placement.conf"
    sed -i "s|^#connection =.*|connection = mysql+pymysql://$mysql_user:$mysql_pass@$mysql_host/placement|" $placement_file
    sed -i "s|^#auth_strategy =.*|auth_strategy = keystone|" $placement_file

    sed -i "/^\[keystone_authtoken\]/a\
www_authenticate_uri = http://$vip:5000\n\
auth_url = http://$vip:5000\n\
memcached_servers = $vip:11211\n\
auth_type = password\n\
project_domain_name = Default\n\
user_domain_name = Default\n\
project_name = service\n\
username = placement\n\
password = $token" $placement_file
    info "placement配置完成"
    grep -Ev '^$|^#' $placement_file
}

function boot_placement {
    su -s /bin/sh -c "placement-manage db sync" placement
    if [ $? -ne 0 ]; then
        error "执行数据库失败"
        exit 1
    fi

    info "修改00-placement-api.conf"
    httpd_placement_file="/etc/httpd/conf.d/00-placement-api.conf"
    sed -i '/<\/IfVersion>/a\
<Directory /usr/bin>\
   <IfVersion >= 2.4>\
      Require all granted\
   </IfVersion>\
   <IfVersion < 2.4>\
      Order allow,deny\
      Allow from all\
   </IfVersion>\
</Directory>' $httpd_placement_file
    systemctl restart httpd
    info "查看监听端口"
    netstat -antlp | grep LISTEN | grep httpd
}

function placement_check {
    info "安装osc-placement插件"
    pip3 install osc-placement

    info "列出可用的资源类和特征："
    openstack --os-placement-api-version 1.2 resource class list --sort-column name

    # 在新的版本中，oslo 策略将移除对 JSON 格式的策略文件的支持
    info "将policy.json文件格式转成yaml格式"
    cd /etc/placement/ && oslopolicy-convert-json-to-yaml --namespace placement --policy-file policy.json --output-file policy.yaml
    cd /etc/placement/ && mv policy.json policy.json.bak

    info "执行状态检查"
    placement-status upgrade check
}

function config_nova_user {
    info "1.创建nova用户"
    openstack user create --domain default --password $token nova

    info "2.添加admin角色"
    openstack role add --project service --user nova admin

    info "3.创建nova服务实体"
    openstack service create --name nova --description "OpenStack Compute" compute

    info "4.创建nova端点"
    openstack endpoint create --region $region compute public http://$vip:8774/v2.1
    openstack endpoint create --region $region compute internal http://$vip:8774/v2.1
    openstack endpoint create --region $region compute admin http://$vip:8774/v2.1

    info "5.查看nova endpoint"
    openstack endpoint list --service=nova
}

function install_nova {
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

    info "8.安装openstack nova组件"
    dnf install -y openstack-nova-api openstack-nova-conductor openstack-nova-novncproxy openstack-nova-scheduler
}

function config_nova {
    info "修改nova配置"
    nova_file="/etc/nova/nova.conf"

    info "修改[DEFAULT]配置"
    nova_dir="/data0/nova"
    if [ ! -d $nova_dir ]; then
        mkdir -p $nova_dir/{buckets,instances,keys,networks,tmp}
        chown -R nova:nova $nova_dir
    fi
    sed -i "s|^#state_path=.*|state_path=$nova_dir|" $nova_file
    sed -i 's|^#enabled_apis=.*|enabled_apis=osapi_compute,metadata|' $nova_file
    sed -i "831s|^#transport_url=.*|transport_url=rabbit://$rabbitmq_user:$rabbitmq_pass@$rabbitmq_host:5672/|" $nova_file
    sed -i "s|^#my_ip=.*|my_ip=$my_ip|" $nova_file
    sed -i "692s|^#log_dir=.*|log_dir=/var/log/nova|" $nova_file
    sed -i "s|^#reserved_host_cpus=.*|reserved_host_cpus=7|" $nova_file
    sed -i "s|^#reserved_host_memory_mb=.*|reserved_host_memory_mb=20480|" $nova_file
    sed -i "s|^#reserved_host_disk_mb=.*|reserved_host_disk_mb=512000|" $nova_file
    sed -i "s|^#cpu_allocation_ratio=.*|cpu_allocation_ratio=1.0|" $nova_file
    sed -i "s|^#ram_allocation_ratio=.*|ram_allocation_ratio=1.0|" $nova_file
    sed -i "s|^#disk_allocation_ratio=.*|disk_allocation_ratio=1.0|" $nova_file
    sed -i "s|^#service_down_time=.*|service_down_time=60|" $nova_file
    sed -i "s|^#rpc_response_timeout=.*|rpc_response_timeout=60|" $nova_file

    info "修改[api_database]配置"
    sed -i "1108s|^#connection=.*|connection=mysql+pymysql://$mysql_user:$mysql_pass@$mysql_host/nova_api|" $nova_file

    info "修改[database]配置"
    sed -i "1848s|^#connection=.*|connection=mysql+pymysql://$mysql_user:$mysql_pass@$mysql_host/nova|" $nova_file

    info "修改[api]配置"
    sed -i "s|^#auth_strategy=.*|auth_strategy=keystone|" $nova_file

    info "修改[vnc]配置"
    sed -i "5432s|^#enabled=.*|enabled=true|" $nova_file
    sed -i "5438s|^#server_listen=.*|server_listen=\$my_ip|" $nova_file
    sed -i "5443s|^#server_proxyclient_address=.*|server_proxyclient_address=\$my_ip|" $nova_file

    info "修改[glance]配置"
    sed -i "s|^#api_servers=.*|api_servers=http://$vip:9292|" $nova_file

    info "修改[oslo_concurrency]配置"
    sed -i "s|^#lock_path=.*|lock_path=$nova_dir/tmp|" $nova_file

    info "修改[scheduler], 配置每隔60秒自动发现计算节点"
    sed -i "s|^#discover_hosts_in_cells_interval=.*|discover_hosts_in_cells_interval=60|" $nova_file

    info "修改[libvirt]网卡多队列最大值"
    sed -i "s|^#max_queues=.*|max_queues=64|" $nova_file

    info "修改[keystone_authtoken]配置"
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

    info "修改[placement]配置"
    sed -i "/^\[placement\]/a\
region_name=$region\n\
project_domain_name=Default\n\
project_name=service\n\
auth_type=password\n\
user_domain_name=Default\n\
auth_url=http://$vip:5000/v3\n\
username=placement\n\
password=$token" $nova_file

    info "查看修改完的nova配置"
    grep -Ev '^$|^#' $nova_file
}

function convert_nova_policy_json {
    cd /etc/nova/ && oslopolicy-convert-json-to-yaml --namespace placement --policy-file policy.json --output-file policy.yaml
    cd /etc/nova/ && mv policy.json policy.json.bak

    info "1.填充nova_api数据库"
    su -s /bin/sh -c "nova-manage api_db sync" nova

    info "2.注册cell0数据库"
    su -s /bin/sh -c "nova-manage cell_v2 map_cell0" nova

    info "3.创建cell1单元格"
    su -s /bin/sh -c "nova-manage cell_v2 create_cell --name=cell1 --verbose" nova

    info "4.填充 nova 数据库"
    su -s /bin/sh -c "nova-manage db sync" nova

    info "5.验证nova cell0 和 cell1 是否已正确注册"
    su -s /bin/sh -c "nova-manage cell_v2 list_cells" nova
}

function boot_nova_service {
    info "启动nova相关服务"
    systemctl enable openstack-nova-api.service openstack-nova-scheduler.service openstack-nova-conductor.service openstack-nova-novncproxy.service
    systemctl start openstack-nova-api.service openstack-nova-scheduler.service openstack-nova-conductor.service openstack-nova-novncproxy.service
    systemctl status openstack-nova-api.service openstack-nova-scheduler.service openstack-nova-conductor.service openstack-nova-novncproxy.service
}

function config_neutron_user {
    info "1.创建neutron用户"
    openstack user create --domain default --password $token neutron

    info "2.添加admin角色"
    openstack role add --project service --user neutron admin

    info "3.创建neutron服务实体"
    openstack service create --name neutron --description "OpenStack Networking" network

    info "4.创建neutron端点"
    openstack endpoint create --region $region network public http://$vip:9696
    openstack endpoint create --region $region network internal http://$vip:9696
    openstack endpoint create --region $region network admin http://$vip:9696

    info "5.查看neutron所有端点"
    openstack endpoint list --service neutron
}

function install_neutron {
    dnf install -y openstack-neutron openstack-neutron-ml2 openstack-neutron-linuxbridge ebtables
}

function config_neutron {
    neutron_file="/etc/neutron/neutron.conf"

    info "1.修改[database]"
    sed -i "s|^#connection =.*|connection = mysql+pymysql://$mysql_user:$mysql_pass@$mysql_host/neutron|" $neutron_file

    info "2.修改[DEFAULT]"
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

    info "3.修改[keystone_authtoken]"
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

    info "4.修改[nova]"
    sed -i "/^\[nova\]/a\
auth_url = http://$vip:5000\n\
auth_type = password\n\
project_domain_name = Default\n\
user_domain_name = Default\n\
region_name = $region\n\
project_name = service\n\
username = nova\n\
password = $token" $neutron_file

    info "5.修改[oslo_concurrency]"
    sed -i "/^\[oslo_concurrency\]/a\
lock_path = $neutron_dir/tmp" $neutron_file

    info "查看修改完的neutron_file配置"
    grep -Ev '^$|^#' $neutron_file
}

function config_ml2 {
    ml2_file="/etc/neutron/plugins/ml2/ml2_conf.ini"

    info "1.修改[ml2]配置"
    sed -i "s|^#type_drivers =.*|type_drivers = flat,vlan|" $ml2_file
    sed -i "s|^#tenant_network_types =.*|tenant_network_types = vlan|" $ml2_file
    sed -i "s|^#mechanism_drivers =.*|mechanism_drivers = linuxbridge|" $ml2_file

    info "2.修改[ml2_type_flat]配置"
    sed -i "s|^#flat_networks =.*|flat_networks = provider|" $ml2_file

    info "3.修改[ml2_type_vlan]配置"
    sed -i "s|^#network_vlan_ranges =.*|network_vlan_ranges = provider|" $ml2_file

    info "4.修改[securitygroup]配置"
    # 禁用安全组
    sed -i "s|^#enable_security_group =.*|enable_security_group = false|" $ml2_file
    sed -i "s|^#enable_ipset =.*|enable_ipset = false|" $ml2_file

    info "查看修改完的ml2_conf配置"
    grep -Ev '^$|^#' $ml2_file
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

function config_dhcp_agent {
    dhcp_file="/etc/neutron/dhcp_agent.ini"

    info "1.修改[DEFAULT]配置"
    sed -i "s|^#interface_driver =.*|interface_driver = linuxbridge|" $dhcp_file
    sed -i "s|^#dhcp_driver =.*|dhcp_driver = neutron.agent.linux.dhcp.Dnsmasq|" $dhcp_file
    sed -i "s|^#enable_isolated_metadata =.*|enable_isolated_metadata = true|" $dhcp_file
    sed -i "s|^#dnsmasq_local_resolv =.*|dnsmasq_local_resolv = false|" $dhcp_file
    sed -i "s|^#dnsmasq_base_log_dir =.*|dnsmasq_base_log_dir = /var/log/neutron|" $dhcp_file

    info "查看修改完的dhcp_agent配置"
    grep -Ev '^$|^#' $dhcp_file
}

function config_metadata_agent {
    metadata_file="/etc/neutron/metadata_agent.ini"

    info "1.修改[DEFAULT]配置"
    sed -i "s|^#nova_metadata_host =.*|nova_metadata_host = $vip|" $metadata_file
    sed -i "s|^#metadata_proxy_shared_secret =.*|metadata_proxy_shared_secret = $token|" $metadata_file

    info "查看修改完的metadata_file配置"
    grep -Ev '^$|^#' $metadata_file
}

function config_nova_use_neutron {
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
password = $token\n\
service_metadata_proxy = true\n\
metadata_proxy_shared_secret = $token" $nova_file

    info "查看修改完的nova配置"
    grep -Ev '^$|^#' $nova_file
}

function neutron_init {
    info "安装bridge-utils"
    dnf install -y bridge-utils

    info "创建ml2软连"
    ln -s /etc/neutron/plugins/ml2/ml2_conf.ini /etc/neutron/plugin.ini

    info "填充neutron数据库"
    su -s /bin/sh -c "neutron-db-manage --config-file /etc/neutron/neutron.conf --config-file /etc/neutron/plugins/ml2/ml2_conf.ini upgrade head" neutron

    info "重启nova-api服务"
    systemctl restart openstack-nova-api.service

    info "启动neutron服务"
    systemctl enable neutron-server.service neutron-linuxbridge-agent.service neutron-dhcp-agent.service neutron-metadata-agent.service
    systemctl start neutron-server.service neutron-linuxbridge-agent.service neutron-dhcp-agent.service neutron-metadata-agent.service
}

function config_horizon {
    info "安装dashboard"
    dnf install -y openstack-dashboard

    setting_file="/etc/openstack-dashboard/local_settings"

    info "修改local-settings配置"
    sed -i "s|^OPENSTACK_HOST =.*|OPENSTACK_HOST = '$vip'|" $setting_file
    sed -i "s|^OPENSTACK_KEYSTONE_URL =.*|OPENSTACK_KEYSTONE_URL = \"http://%s:5000/v3\" % OPENSTACK_HOST|" $setting_file
    sed -i "s|^TIME_ZONE =.*|TIME_ZONE = \"Asia/Shanghai\"|" $setting_file
    sed -i "s|^ALLOWED_HOSTS =.*|ALLOWED_HOSTS = ['*']|" $setting_file
    sed -i "s|^#SESSION_ENGINE =.*|SESSION_ENGINE = 'django.contrib.sessions.backends.file'|" $setting_file
    sed -i "/^SESSION_ENGINE = 'django.contrib.sessions.backends.file'/a\
CACHES = {\n\
    'default': {\n\
        'BACKEND': 'django.core.cache.backends.memcached.MemcachedCache',\n\
        'LOCATION': '$vip:11211',\n\
    }\n\
}" $setting_file

    echo "OPENSTACK_KEYSTONE_MULTIDOMAIN_SUPPORT = True" >> $setting_file
    echo "OPENSTACK_KEYSTONE_DEFAULT_DOMAIN = \"Default\"" >> $setting_file
    echo "OPENSTACK_KEYSTONE_DEFAULT_ROLE = \"user"\" >> $setting_file

    sed -i '$a\
OPENSTACK_API_VERSIONS = {\
    "identity": 3,\
    "image": 2,\
    "volume": 3,\
}' $setting_file

    echo "
OPENSTACK_NEUTRON_NETWORK = {
    'enable_router': False,
    'enable_quotas': False,
    'enable_distributed_router': False,
    'enable_ha_router': False,
    'enable_fip_topology_check': False,
}
" >> $setting_file

    info "修改openstac-dashboard配置"
    httpd_file="/etc/httpd/conf.d/openstack-dashboard.conf"
    sed -i '/^WSGISocketPrefix.*$/a WSGIApplicationGroup %{GLOBAL}' $httpd_file

    info "重建apache的dashboard配置文件"
    cd /usr/share/openstack-dashboard && python3 manage.py make_web_conf --apache > /etc/httpd/conf.d/openstack-dashboard.conf

    info "建立策略文件（policy.json）的软链接"
    ln -s /etc/openstack-dashboard /usr/share/openstack-dashboard/openstack_dashboard/conf
}

function boot_horizon {
    info "启动horizon、memcached"
    systemctl restart httpd.service memcached.service
}

function neutron_add_ip_ping {
    info "覆盖neutron driver.py 添加ip ping"
    /bin/cp -f driver.py /lib/python3.6/site-packages/neutron/ipam/drivers/neutrondb_ipam/driver.py

    info "重启neutron服务"
    systemctl restart neutron-server.service neutron-linuxbridge-agent.service neutron-dhcp-agent.service neutron-metadata-agent.service
}

install_keepalived
install_memcache
install_openstack_yoga_package
create_database
install_keystone
config_apache
config_admin_openrc
config_domain_project_user_role
config_glance_user_info
install_glance
config_glance
boot_glance
config_placement_user
config_placement
boot_placement
placement_check
config_nova_user
install_nova
config_nova
convert_nova_policy_json
boot_nova_service
config_neutron_user
install_neutron
config_neutron
config_ml2
config_linuxbridge
config_dhcp_agent
config_metadata_agent
config_nova_use_neutron
neutron_init
config_horizon
boot_horizon
neutron_add_ip_ping
