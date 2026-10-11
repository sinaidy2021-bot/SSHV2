# PhoneProxy

把 iPhone 的蜂窝流量变成 SOCKS5 出口：手机**主动**用 SSH 连到你的 Ubuntu VPS，
建立与 `ssh -R 127.0.0.1:11080:...` 等效的反向转发。VPS 上只有 `127.0.0.1:11080`
可用，应用程序连它即可从手机蜂窝网出去。

```
应用 → VPS 127.0.0.1:11080 ══SSH 隧道══▶ iPhone SOCKS5(127.0.0.1, 需账号密码) ──蜂窝──▶ 互联网
```

## 结构

| 部分 | 说明 |
|---|---|
| `App/` | SwiftUI 界面：配置、启停、状态（隧道/网络类型/重连次数/流量）。配置存钥匙串 |
| `Tunnel/PacketTunnelProvider` | Network Extension（Packet Tunnel）。只用来让进程在后台长期存活，不接管任何流量 |
| `Tunnel/SSHReverseTunnel` | libssh2 反向转发（tcpip-forward）、心跳、主机指纹校验、自动重连 |
| `Tunnel/Socks5Server` | 仅监听手机本机回环、用户名/密码认证、TCP CONNECT；出站强制 `.cellular` |
| `Tunnel/ProxyCore` | NWPathMonitor：Wi‑Fi/蜂窝切换时打断旧连接并立即重连 |
| `project.yml` | XcodeGen 配置，工程文件由它生成 |

## 一、Apple Developer 准备（付费账号）

1. Identifiers 里创建两个 App ID，并都勾选 **Network Extensions** 能力：
   - 主 App：`com.yourname.phoneproxy`
   - 扩展：`com.yourname.phoneproxy.tunnel`（必须是主 ID + `.tunnel`）
2. 为两个 ID 各建一个描述文件（Development 或 Ad Hoc，包含你的设备 UDID）。
3. 创建对应证书（Apple Development 或 Apple Distribution）。

## 二、GitHub 构建

先把 `project.yml` 里的 `APP_BUNDLE_ID` 改成你的 ID（或在仓库 Variables 里设置 `BUNDLE_ID`）。

**A. 未签名 IPA（自己签名）**——`Build unsigned IPA`
Actions → Run workflow，下载 artifact `PhoneProxy-unsigned`：
`PhoneProxy-unsigned.ipa` 以及两个 `.entitlements` 文件。用你自己的签名工具重签时：
- 主 App 与 `PlugIns/PacketTunnel.appex` 各用各自的描述文件；
- 必须保留 `com.apple.developer.networking.networkextension = packet-tunnel-provider`
  （entitlements 文件已附上）；
- 先签 appex，再签 app。

**B. 直接签名 IPA**——`Build signed IPA`
在仓库 Secrets 添加：

```bash
base64 -i cert.p12                 | pbcopy   # CERT_P12_BASE64
# CERT_PASSWORD  = p12 密码
base64 -i app.mobileprovision      | pbcopy   # APP_PROFILE_BASE64
base64 -i tunnel.mobileprovision   | pbcopy   # EXT_PROFILE_BASE64
```
运行时选导出方式：Ad Hoc 选 `release-testing`，开发证书选 `debugging`。
Bundle ID、Team ID 会自动从描述文件读取。

## 三、VPS 端（Ubuntu，OpenSSH ≥ 7.8）

1. 生成专用密钥（在你电脑上）：`ssh-keygen -t ed25519 -f phoneproxy -C phoneproxy`，把 `phoneproxy`（私钥）导入 App。
2. 在 VPS 上把公钥写进 `~/.ssh/authorized_keys`，**限制只能做这一件事**：
   ```
   restrict,port-forwarding,permitlisten="127.0.0.1:11080" ssh-ed25519 AAAA... phoneproxy
   ```
3. `/etc/ssh/sshd_config` 建议加上（切换网络后，旧连接占着端口会导致重连失败，靠它尽快清理）：
   ```
   ClientAliveInterval 15
   ClientAliveCountMax 2
   ```
   然后 `sudo systemctl reload ssh`。保持 `GatewayPorts no`（默认），端口就只绑回环。
4. 测试：`curl -x socks5h://用户名:密码@127.0.0.1:11080 https://ifconfig.me`，应返回手机蜂窝 IP。

## 四、使用与注意

- 在 iPhone「设置 → 蜂窝网络」里给 PhoneProxy 开启蜂窝数据，并关闭低数据模式。
- 首次启动会弹出添加 VPN 配置的系统授权；运行期间状态栏会有 VPN 图标（这是保活所需）。
- 先用一次连接，在 App 里点「固定当前连接的指纹」。
- 仅支持 TCP（CONNECT）；不支持 UDP ASSOCIATE。
- 持续转发较耗电，扩展内存上限约 50MB，已限制并发 128。
- 私钥/密码通过系统 VPN 配置传给扩展，仅本 App 沙盒可读，但仍建议用专用、受限的密钥。
- libssh2 预编译包使用 OpenSSL 1.1.1w（上游已停止维护），仅用于连接你自己的服务器。
