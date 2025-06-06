# OpenStack yoga

## keystone token

```
openssl rand -hex 10
```

## 优化项

- 禁用安全组
- 子网ip预留(起始:.2 结束.240)
- 取消虚ip限制(ebtables去除)
- ip ping检查
- 网卡多队列
- 去除openstacklocal
- 预留及超卖比
- 配额调整
- 软反亲和

## 脚本说明

```
.
├── README.md
├── compute
│   ├── deploy.yaml      -- 初始化openstack计算节点
│   └── yoga
│       ├── compute.sh
│       └── ssh.tar.gz
├── control
│   ├── control.sh       -- 初始化openstack控制节点
│   └── driver.py
└── openstack
    ├── README.md
    ├── control.sh       -- 初始化控制节点虚拟机
    └── template.xml
```
