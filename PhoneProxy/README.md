# PhoneProxy（无扩展版）

把 iPhone 的蜂窝流量变成 SOCKS5 出口：手机**主动**用 SSH 连到你的 Ubuntu VPS，
建立与 `ssh -R 127.0.0.1:11080:...` 等效的反向转发。VPS 上只有 `127.0.0.1:11080` 可用。

```
应用 → VPS 127.0.0.1:11080 ══SSH 隧道══▶ iPhone SOCKS5(127.0.0.1, 需账号密码) ──蜂窝──▶ 互联网
```

## 结构

| 部分 | 说明 |
|---|---|
| `App/` | SwiftUI 界面（配置、启停、状态）、钥匙串存储、静音音频保活 |
| `Core/SSHReverseTunnel` | libssh2 反向转发（tcpip-forward）、心跳、主机指纹校验、自动重连 |
| `Core/Socks5Server` | 仅监听手机本机回环、用户名/密码认证、TCP CONNECT；出站强制 `.cellular` |
| `Core/ProxyCore` | NWPathMonitor：Wi‑Fi/蜂窝切换时打断旧连接并立即重连 |
| `project.yml` | XcodeGen 配置，工程文件由它生成 |

## 签名

本版本不需要任何特殊权限（没有 Network Extension、没有 entitlements）。
任何普通的 `.p12` + `.mobileprovision`（包括通配符描述文件）都可以重签，Bundle ID 可随意改。

## VPS 端（Ubuntu，OpenSSH ≥ 7.8）

1. 生成专用密钥：`ssh-keygen -t ed25519 -f phoneproxy -C phoneproxy`，把私钥 `phoneproxy` 导入 App。
2. 在 VPS 的 `~/.ssh/authorized_keys` 写入公钥，并限制只能做这一件事：
   ```
   restrict,port-forwarding,permitlisten="127.0.0.1:11080" ssh-ed25519 AAAA... phoneproxy
   ```
3. `/etc/ssh/sshd_config` 建议加上（网络切换后旧连接占着端口会导致重连失败，靠它尽快清理）：
   ```
   ClientAliveInterval 15
   ClientAliveCountMax 2
   ```
   然后 `sudo systemctl reload ssh`。保持 `GatewayPorts no`（默认）。
4. 测试：`curl -x socks5h://用户名:密码@127.0.0.1:11080 https://ifconfig.me`，应返回手机蜂窝 IP。

## 使用与注意

- 后台保活靠循环播放静音音频（UIBackgroundModes=audio）。**不要在后台划掉 App**；
  iOS 偶尔仍会杀进程，打开 App 会自动恢复运行（可在选项里关闭）。
- 在「设置 → 蜂窝网络」里给 PhoneProxy 开启蜂窝数据，并关闭低数据模式。
- 首次连接后点「固定当前连接的指纹」。
- 仅支持 TCP（CONNECT），不支持 UDP。持续转发较耗电。
- libssh2 预编译包使用 OpenSSL 1.1.1w（上游已停止维护），仅用于连接你自己的服务器。
