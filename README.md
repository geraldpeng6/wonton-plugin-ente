# 云吞插件：Ente 相册

云吞（Wonton）的插件就是一个 `docker-compose.yml`，顶层多一个 `x-wonton` 字段，写明插件在云吞里的身份、网页入口和要的
权限。一个插件一个 Git 仓库，仓库根目录就是插件包，发布就是打 tag。用户在 App 里装上插件，核心按清单起容器、接好登录，
插件的网页在 App 里作为小程序打开。

这个仓库是 [Ente](https://ente.com) 相册的插件包：照片和视频以**端到端加密**备份到自己家里，云吞这边（包括数据库和对象
存储）只存加密后的数据，密钥由你的 Ente 账号密码派生。时间线、相册、搜索、分享都在网页里做，手机浏览器全功能可用。

## 为什么登录走 Ente 自己的账号，不能接 OIDC

Ente 的账号密码不只是登录凭据：主密钥用账号密码包裹，登录走 SRP（服务器只存校验器，拿不到密码），照片的加密密钥链从
账号密钥派生。也就是说，**换成任何外部身份（云吞的 OIDC 或反代头）都替代不了这个密码**——没有它就解不开照片。

而且 Ente（museum 服务端和网页应用）本身没有实现 OIDC 或反代头登录，自托管文档的流程就是在应用里注册账号。所以本插件
用 `sso: none`：云吞网关挡在外面，未登录的请求到不了插件，注册页只有主人（和配对的设备）打得开；进了网页再按 Ente 自己
的方式注册、登录。

**注册**：第一次打开时点"没有账号"，邮箱填一个 `@example.org` 结尾的地址（比如 `you@example.org`——自托管实例没配发信，
这个邮箱只是账号标识，不会真的收信），验证码填 `123456`，然后设密码。这是 museum 配置里上游自托管开发用的固定验证码，
原因和边界见 `docker-compose.yml` 里的 `hardcoded-ott` 一节。**密码和恢复密钥丢了，照片就永远解不开**：注册完成后把
24 个恢复词抄下来，和实例地址一起存好。

## 这个插件的行为

- 服务：museum（Ente 的 API 服务器，AGPL-3.0）+ Postgres + MinIO（Ente quickstart 和官方 config/compose 自带的对象存储
  镜像 `pgsty/silo`，上游没有自己的存储镜像；AGPL-3.0）+ Ente Photos 网页应用（`ghcr.io/ente/web`，AGPL-3.0）+ 一个
  nginx 入口。镜像全部按摘要固定；`ghcr.io/ente/server`、`ghcr.io/ente/web` 没有版本号 tag（分别每月、每周构建），按
  `latest` 的清单列表摘要锁定。
- 网页入口是那个 nginx（`webui` 指向它）：同一个源上，`/` 伺服 Ente 网页应用，`/api/` 转给 museum，对象存储的预签名
  请求（`/桶名/对象`）转给 MinIO。所有请求同源，不触发 CORS。
- Ente 网页应用的 API 地址是打包时写死的，镜像自带的启动脚本在容器启动时把 `ENTE_API_ORIGIN` 替换成 `${WONTON_APP_URL}/api`。
- 对象存储：museum 用自己的 endpoint（容器网络里的 `minio:3200`）签名并把地址交给客户端；浏览器到不了容器网络里的主机名，
  所以 nginx 把响应体里的 `http://minio:3200` 前缀改写成相对路径（浏览器按当前源访问），请求到 MinIO 前再把 Host 还原成
  签名用的 `minio:3200`，签名校验两边一致。网页直传（预签名 PUT）和下载（预签名 GET）都走这条路；museum 自己的对象
  操作直接访问 `minio:3200`。
- 第一个注册的账号自动是实例管理员（上游行为），管理接口走 `ente` CLI 或 Ente 官方的管理页面。
- 数据：加密后的照片在 MinIO 的卷里（插件数据目录 `minio/`），元数据在 Postgres（`postgres/`）。都是加密或私有数据，不进
  共享文件夹。磁盘用量随照片数增长。
- 权限：无（`permissions: []`）。全部服务不出网、不开局域网端口；对外的唯一入口是云吞网关后面的网页。

### 限制

- **公共相册链接打不开**：Ente 的公开相册是独立的网页应用（上游 compose 里单独一个端口），插件只开放一个网页入口，没法
  一起提供。museum 生成的分享链接指回插件网页，打开后进不了相册公开页。
- **Ente 官方手机 App 连不上**：官方 App 自定义服务器时直连 API 端口并自己管登录，云吞的网页入口只认云吞的会话，App
  不会走云吞的登录。备份请在网页里做（上传支持多选、后台继续）。
- 无服务端机器学习：Ente 的人脸、搜索都在客户端做（端到端加密的必然结果），插件不加 GPU。

## 仓库里有什么

| 路径 | 内容 |
| --- | --- |
| `docker-compose.yml` | 插件本身：compose 加上 `x-wonton` 清单，行为取舍都写在文件头注释 |
| `web/default.conf` | nginx 入口的三段路由（网页 / API / 对象存储） |
| `icon.png`、`screenshots/` | 商店图标和竖屏截图 |
| `scripts/smoke-probes.sh` | 插件探针：真实页面、Ente 账号注册与管理员断言、升级/重装保数据。探测用官方 `ente` CLI 在插件网络里直连 museum，CLI 按发布 tag 从 GitHub 下载并按 `SHA256SUMS` 校验 |
| `scripts/check.sh` 等 | 开发套件，用法见[开发指南](https://github.com/geraldpeng6/wonton-docs/blob/main/develop.md) |

插件包是 `docker-compose.yml` 加上它引用的文件（`icon.png`、`NOTICE` 和 compose 里的 `configs`）。README、截图、脚本不在
插件包里。

## 图标

`icon.png` 是 Ente 的官方圆形标志放在白色底上的合成图，未用图片模型生成；来源、版权、AGPL-3.0 全文和商标说明见
[NOTICE](NOTICE)。
