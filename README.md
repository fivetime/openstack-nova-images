# openstack-nova-images

为 [openstack-incus](https://github.com/fivetime/openstack-incus) Nova
驱动自动构建 guest 镜像的流水线。每次运行从
`images.linuxcontainers.org`（incus 客户端内置的 `images:` remote）
继承**最新的官方每日构建**，安装驱动镜像契约要求的软件包，产出驱动
认可的两种制品。

## 两种制品，两条根盘路径

同一份定制后的 rootfs，封装成两个 Glance 制品，分别服务驱动的两种
根盘模型，**不可互换**：

| | `<name>.tar.gz`（unified tar） | `<name>-bfv.raw.zst`（ext4 raw） |
|---|---|---|
| 根盘模型 | 本地/临时根盘（Nova 管理，大小取 Flavor `root_gb`） | 引导卷 BFV（根盘是 Cinder RBD 卷，cephext 驱动"认领"卷内 `rootfs/`） |
| 消费方式 | 驱动交给 incusd 导入为 Incus 镜像 | Glance RBD 池 → Cinder CoW 克隆（零拷贝，有 RBD parent） |
| 内容结构 | `metadata.yaml` + `templates/` + `rootfs/` | 可直接挂载的 ext4，顶层 `rootfs/` 目录 + `.incus-idmap` 标记（0600） |
| 生命周期 | 跟实例走 | 归 Cinder，可保留可另挂 |
| 热迁移 | CRIU + 根盘传输 | CRIU + 共享 Ceph 零拷贝交接 |

**禁止**：把 unified tar 当 BFV raw 上传（克隆出的卷不是文件系统）；
把 BFV raw 走镜像导入（incusd 不认）；用普通 VM qcow2 充当系统容器
根。每个镜像另附 `<name>.manifest.json`，记录上游
fingerprint/serial 和能力标志，供溯源与推送脚本使用。

## 为什么要定制镜像

* **fuse2fs 是 Cinder 数据卷的硬性要求。** 驱动在创建带初始数据卷的
  实例时要求 Glance 属性 `hw_incus_data_volume_fuse=true`，attach 时
  还会在 guest 内实测 `which fuse2fs`。租户 ext4 在用户态解析，永不
  进入计算节点内核。guest 自行运行 fuse2fs 是唯一兼容 CRIU 热迁移的
  路径。
* **cloud-init** 来自上游 `cloud` variant（user-data、密钥对、
  Neutron 网络配置）。
* **SSH** 预装并删除 host key，实例首次启动生成唯一身份。
* **Manila 不需要任何 guest 侧定制**——共享在计算宿主侧挂载，以
  Incus disk 设备暴露进容器。
* CI 对每个镜像校验 `rootfs/sbin/init`、fuse2fs 能力、
  `.incus-idmap`（0600）、15% 余量和 `e2fsck`。

## 覆盖面：上游有什么就构建什么

构建矩阵由 `discover` job **运行时发现**：查询 `images:` remote 的
权威 simplestreams 目录（不是滞后的网页），凡满足
`variant=cloud` + Incus 容器支持 + `x86_64` 的镜像自动入列——上游
新版本下次运行自动加入，下架自动退出。同一镜像的数字/代号双别名
（`debian/12` = `debian/bookworm`）按 fingerprint 去重，优先代号。
截至 2026-08 共 **41 个镜像**，覆盖 ubuntu、debian、devuan、kali、
mint、alpine、almalinux、rockylinux、centos-stream、oracle、
fedora、openeuler、opensuse、archlinux 十四族。

各族的装包规则和 BFV 大小写在 workflow 的 `discover` job 里。没有
规则的新发行版会打 `SKIP` 日志跳过，绝不静默。个别发行版失败不阻塞
其余镜像发布。

**fuse2fs 包名情报**（均由 CI 硬校验实测得出）：

| 族 | 包名 | 说明 |
|---|---|---|
| debian/ubuntu/devuan/kali/mint | `fuse2fs` | |
| alpine（3.21+ 全部） | `fuse2fs` | 独立包；`e2fsprogs-extra` 从来不含它 |
| archlinux | `fuse2fs` | 2026-03 起从 e2fsprogs 拆出的独立 core 包 |
| EL 系（alma/rocky/centos/oracle/openeuler） | `e2fsprogs` + 兜底尝试独立名 | 实测全部拿到 fuse2fs，无需收窄能力 |
| fedora/opensuse | `e2fsprogs` / `fuse2fs` | |

若某发行版确实无法提供 fuse2fs，该镜像以
`data_volume_fuse=false` 发布（manifest 与 release 表格可见），
Glance 不打对应属性，驱动会拒绝为其挂初始数据卷——能力收窄而非
造假，符合驱动契约。

## 工作流

`.github/workflows/build.yaml`，每月 1 号 00:00 UTC 自动运行，也可
手动触发。job 编排：

```
discover ─→ prepare（建 draft release）─→ build ×41（各自上传产物）
                                              └→ finalize-release（聚合校验和、发布）
                                              └→ push-to-glance（默认关闭）
```

产物由每个 build job **直接上传到 release**（41 组共 ~25GB，聚合到
单机会耗尽 runner 磁盘），收尾 job 只聚合 KB 级的 manifest 与
sha256。

## 推送到 Glance

GitHub 托管 runner **无法访问私网 OpenStack 端点**，因此推送是独立
的可选环节，两种方式：

**方式一：控制节点手动推送**（适合私网集群）：

```bash
gh release download <tag> --dir dist --repo fivetime/openstack-nova-images
source /etc/openstack/admin-openrc
IMAGE_STORE=rbd bash scripts/push-to-glance.sh dist
```

**方式二：自建 runner 自动推送**：注册一台能访问
Keystone/Glance 的 runner，设置仓库变量 `GLANCE_RUNNER`（runner
标签）、`PUSH_TO_GLANCE=true`，配置 `OS_*` secrets
（`OS_AUTH_URL`、`OS_PROJECT_NAME`、`OS_PROJECT_DOMAIN_NAME`、
`OS_USERNAME`、`OS_USER_DOMAIN_NAME`、`OS_PASSWORD`、
`OS_REGION_NAME`），可选变量 `GLANCE_IMAGE_STORE` 指定后端存储。
注意完整资产集有数十 GB，自建 runner 需备足磁盘。

推送脚本自动应用完整属性契约：

* `hypervisor_type=lxd`——nova-incus 计算节点上报的值，混合
  libvirt/incus 集群的 `ImagePropertiesFilter` 调度必需（部署不同
  可用 `HYPERVISOR_TYPE=` 覆盖）；
* fuse2fs 实测为真时打 `hw_incus_data_volume_fuse=true`；
* BFV 制品追加 `hw_incus_boot_from_volume=true`、
  `hw_incus_rootfs_idmap_provenance=v1`、
  `hw_incus_rootfs_layout=rootfs-directory`；
* 生产 BFV 必须用 `IMAGE_STORE=` 明确指定 RBD 后端，Cinder 才能
  CoW 克隆（否则退化为下载导入的全量拷贝）。

## 脚本

| 脚本 | 职责 |
|---|---|
| `scripts/build-guest-image.sh` | 从 `images:` remote 复制最新构建，chroot 装包（apk/apt/dnf/zypper/pacman 五分支），重打 unified tar，写 manifest |
| `scripts/build-bfv-image.sh` | unified tar → ext4 raw（`rootfs/` 布局 + `.incus-idmap`），校验余量与 `e2fsck` |
| `scripts/push-to-glance.sh` | 按 manifest 把两种制品带属性推入 Glance，支持多 store 的 copy-image 导入 |

## 发布 ≠ 资格

牢记 openstack-incus 的规矩：新镜像修订在通过镜像验收矩阵（创建/
删除、BFV、数据卷、硬重启、快照恢复，以及——仅在宣传时——完整热
迁移矩阵）之前，不算生产就绪。本仓库的 release 是**构建证据**，
不是资格认证。
