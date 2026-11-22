# EdgeOne-Sh-DDNS
应用在openwrt服务器上的腾讯CDN edge one 服务的ddns bash脚本。仅测试成功IPV6


可以。下面这份教程统一使用 **`abc.com`** 和 **`www.abc.com`** 作为示例，不再出现你的真实域名。脚本中的密钥、站点 ID、源站组 ID 全部用占位符表示，需要你按步骤替换。

---

## 一、教程目标与前提

这套方案实现的是：

> 当家庭宽带的公网 IPv6 地址发生变化时，OpenWrt 上的脚本自动调用 EdgeOne 国际站 API，把 EdgeOne **源站组**里的 IPv6 地址更新为新地址。

前提条件：

1. 你使用的是 **EdgeOne 国际站**，API 域名是 `teo.intl.tencentcloudapi.com`。
2. 加速域名 `www.abc.com` 的源站配置必须使用 **“源站组”** 模式，而不是直接填写单个 IP。
3. OpenWrt 已安装 `curl`、`openssl-util`、`jsonfilter`。
4. 你已经在 EdgeOne 控制台把 `www.abc.com` 接入并配置好 CNAME、HTTPS 等基础加速。本教程只讲 DDNS 自动更新源站 IP。

---

## 二、创建腾讯云子用户并获取 SecretId / SecretKey

不要使用主账号密钥。建议为 DDNS 创建一个只具备最小权限的子用户。

### 2.1 创建子用户

1. 登录腾讯云国际站 CAM 控制台：`https://console.tencentcloud.com/cam`。
2. 左侧选择 **用户 → 用户列表**。
3. 点击 **新建用户**，选择 **自定义创建**。
4. 访问方式只勾选 **编程访问**，不需要控制台登录密码。
5. 用户名可填 `edgeone-ddns`，完成创建。

### 2.2 创建最小权限策略

1. 在 CAM 左侧进入 **策略**。
2. 点击 **新建自定义策略**，选择 **按策略语法创建**。
3. 粘贴类似下面的策略，只允许调用 `ModifyOriginGroup`：

```json
{
  "version": "2.0",
  "statement": [
    {
      "effect": "allow",
      "action": ["teo:ModifyOriginGroup"],
      "resource": ["*"]
    }
  ]
}
```
或者选择 按策略生成器创建。进入“可视化策略生成器”后，按以下方式填写，对应你 DDNS 脚本的需求：

效果：选择 允许 (Allow)。这是策略的白名单模式。

服务：在搜索框中输入 teo 或 边缘安全加速平台，然后选中 边缘安全加速平台 (teo)。

操作：在搜索框中输入 ModifyOriginGroup，然后勾选它。只勾选这一个操作，实现最小权限。

资源：选择 全部资源。因为 ModifyOriginGroup 属于“操作级”授权的接口，不强制指定具体的资源六段式（resource），填 * 即可。

条件：保持空白，无需设置。
4. 策略名称可填 `EdgeOne-DDNS-Minimal`，保存。
5. 回到 **用户列表**，进入 `edgeone-ddns` 用户详情，在 **权限** 标签页关联这个策略。

> 如果图省事，也可以关联 `QcloudTEOFullAccess`，但权限范围更大，不如自定义策略安全。

### 2.3 创建 API 密钥

1. 在 `edgeone-ddns` 用户详情页，点击 **API 密钥** 标签页。
2. 点击 **新建密钥**。
3. 弹窗会一次性显示 `SecretId` 和 `SecretKey`。

**关键提醒**：`SecretKey` 只在创建时显示一次，关闭弹窗后无法再次查看。请立刻复制保存，并直接填入后面的脚本。`SecretId` 通常以 `IKID` 开头。

> 如果你之前已经在对话或公开渠道暴露过密钥，请先在 CAM 中 **禁用旧密钥**，再新建一对用于脚本。

---

## 三、在 EdgeOne 创建源站组并切换加速域名

这一步是 DDNS 能生效的前提。API 更新的是“源站组里的 IP”，不是直接改域名的 A/AAAA 记录。

### 3.1 创建源站组

1. 登录 EdgeOne 国际站控制台：`https://console.tencentcloud.com/edgeone`。
2. 进入站点 `abc.com`。
3. 左侧菜单找到 **源站配置 → 源站组**。
4. 点击 **新建源站组**。
5. 源站组名称可填 `home-ipv6-group`。
6. 源站类型选择 **HTTP 专用型** 或 **通用型** 均可。
7. 添加源站：类型选 **IP/域名**，地址填入你当前家庭宽带的公网 IPv6。
8. 保存后，进入该源站组详情页，记下 **GroupId**，格式通常是 `og-xxxxxxxx` 或 `origin-xxxxxxxx`。

### 3.2 把 `www.abc.com` 的源站切换为源站组

1. 在站点 `abc.com` 中进入 **域名管理** 或 **加速域名** 列表。
2. 找到 `www.abc.com`，点击 **编辑**。
3. 在 **回源配置 / 源站配置** 中，把源站类型从“IP/域名”改为 **源站组**。
4. 选择刚才创建的 `home-ipv6-group`。
5. 保存。

> 如果这一步不做，脚本虽然能更新源站组里的 IP，但 `www.abc.com` 实际回源仍然使用旧配置，DDNS 不会生效。

---

## 四、获取 ZoneId

`ZoneId` 是站点 `abc.com` 在 EdgeOne 中的唯一标识，格式为 `zone-xxxxxxxx`。

获取方式：

1. 进入 EdgeOne 控制台的 **站点列表**。
2. 找到站点 `abc.com`。
3. `ZoneId` 通常会显示在站点名称旁边，或站点概览信息中。
4. 复制完整的 `zone-` 开头字符串。

注意：`ZoneId` 不是域名，也不是源站组 ID。

---

## 五、在 OpenWrt 安装依赖

在 OpenWrt 终端执行：

```bash
opkg update
opkg install openssl-util
```

`curl` 和 `jsonfilter` 通常已内置。可以检查：

```bash
command -v curl
command -v openssl
command -v jsonfilter
```

如果缺少 `jsonfilter`，可尝试：

```bash
opkg install jsonfilter
```

同时确认系统 UTC 时间准确：

```bash
date -u
```

误差不要超过 5 分钟，否则签名可能过期。

---

## 六、写入 DDNS 脚本

在 OpenWrt 上创建 `/root/edgeddns.sh`。下面脚本中的 `SECRET_ID`、`SECRET_KEY`、`ZONE_ID`、`GROUP_ID` 都需要替换成你自己的值。

见本仓库文件。

保存后设置权限：

```bash
chmod 700 /root/edgeddns.sh
```

脚本包含密钥，建议只允许 root 读取和执行。

---

## 七、填入参数并手动测试

把脚本配置区的四个占位符替换掉：

| 变量 | 填什么 |
|---|---|
| `SECRET_ID` | CAM 子用户 API 密钥中的 SecretId |
| `SECRET_KEY` | 同一次创建时显示的 SecretKey |
| `ZONE_ID` | EdgeOne 站点 `abc.com` 的 `zone-xxxxxxxx` |
| `GROUP_ID` | 源站组详情页里的 `og-xxxxxxxx` 或 `origin-xxxxxxxx` |

然后手动运行：

```bash
/root/edgeddns.sh
cat /root/edgeddns.log
```

成功时日志会出现类似：

```text
[OK] 源站组已更新为 2409:xxxx:xxxx:xxxx:xxxx:xxxx:xxxx:xxxx (RequestId: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx)
```

此时去 EdgeOne 控制台的源站组页面，确认里面的 IPv6 已经变成当前地址。

如果 IP 没有变化，脚本会直接退出，不会写日志，也不会调用 API。如果想强制测试，可以删除状态文件：

```bash
rm -f /root/edgeddns.lastip
/root/edgeddns.sh
```

---

## 八、设置定时任务

OpenWrt 上执行：

```bash
crontab -e
```

添加一行，例如每 10 分钟检查一次：

```text
*/10 * * * * /root/edgeddns.sh
```

保存退出。如果不确定 cron 是否重载，可以执行：

```bash
service cron restart
```

之后可以用下面的命令观察日志：

```bash
tail -f /root/edgeddns.log
```

---

## 九、常见错误排查

### 9.1 `[ERROR] 缺少命令: xxx`

说明 OpenWrt 缺少依赖。安装：

```bash
opkg update
opkg install openssl-util
```

如果缺 `jsonfilter`，尝试 `opkg install jsonfilter`。

### 9.2 `[ERROR] 获取 IPv6 失败`

先在终端手动测试：

```bash
curl -6 -v --connect-timeout 10 https://6.ident.me
```

如果失败，换检测地址，例如把脚本里的：

```sh
IP_CHECK_URL="https://6.ident.me"
```

改为：

```sh
IP_CHECK_URL="https://api64.ipify.org"
```

然后重新运行。

### 9.3 `AuthFailure.SignatureFailure`

说明签名没通过。优先检查：

1. `SECRET_ID` 和 `SECRET_KEY` 是否复制完整，尤其 `SecretKey` 是否混入空格或换行。
2. 路由器 UTC 时间是否准确：`date -u`，误差不要超过 5 分钟。
3. 是否误用了中国站域名。脚本中 `DOMAIN` 必须是 `teo.intl.tencentcloudapi.com`。
4. 是否使用的是已禁用或已删除的旧密钥。

### 9.4 `ActionOffline`

说明 API 版本号不对。脚本中必须是：

```sh
-H "X-TC-Version: 2022-09-01"
```

`2022-01-06` 已经下线。

### 9.5 `UnauthorizedOperation`

说明子用户没有调用 `ModifyOriginGroup` 的权限。回到 CAM 检查 `edgeone-ddns` 用户是否已关联包含 `teo:ModifyOriginGroup` 的自定义策略。

### 9.6 `MissingParameter` 或 `InvalidParameter`

通常说明 `GROUP_ID` 填错，或者源站组不存在。回到 EdgeOne 源站组详情页重新复制 `GroupId`。API 请求字段名是 `GroupId`，值来自源站组 ID。

### 9.7 日志出现 `[OK]` 但网站不生效

检查 `www.abc.com` 的回源配置是否已经切换为 **源站组** 模式，并且选中的正是脚本更新的那个源站组。如果域名仍然直接绑定单个 IP，更新源站组不会影响实际回源。

---

## 十、安全与维护提醒

1. **旧密钥立即作废**：如果之前的 `SecretId` / `SecretKey` 曾在公开渠道出现，请到 CAM 禁用并重新生成。
2. **脚本权限设为 700**：脚本内有明文密钥，只允许 root 读写执行。
3. **不要使用主账号密钥**：子用户 + 最小权限策略更安全。
4. **日志定期清理**：`/root/edgeddns.log` 会增长，可以偶尔清空，或在脚本外做简单轮转。
5. **IP 列表与 API 变更**：EdgeOne 接口和参数可能调整。如果某天突然全部失败，先看日志错误码，再对照官方文档确认 `X-TC-Version` 和接口域名是否仍然有效。

按以上步骤配置完成后，`www.abc.com` 的源站组会在家庭 IPv6 变化后自动更新，你不需要再手动登录控制台改 IP。
