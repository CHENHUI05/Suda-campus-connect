# Linux 服务器部署说明

适用于 CentOS / Ubuntu / Debian 等在校内网络环境中的 Linux 服务器，原理与 Windows 版完全一致：调用校园网 Dr.COM 网关登录，用 cron 定时重连。

## 1. 准备依赖

```bash
# CentOS / RHEL
sudo yum install -y curl iproute cronie && sudo systemctl enable --now crond

# Ubuntu / Debian
sudo apt update && sudo apt install -y curl iproute2 cron
```

## 2. 获取文件并填写配置

```bash
git clone https://github.com/你的用户名/suda-campus-connect.git
cd suda-campus-connect/linux
cp suda-campus.conf.example suda-campus.conf
vi suda-campus.conf        # 填写 USERNAME、PASSWORD，运营商后缀规则见文件内注释
chmod 600 suda-campus.conf # 仅当前用户可读写，保护明文密码
chmod +x suda-campus.sh
```

> 前提：服务器物理上已接入校园网（网线 / 校内 Wi-Fi），能访问网关 `10.9.1.3`。可先执行 `ping 10.9.1.3` 或 `curl -I http://10.9.1.3:801` 验证。

## 3. 启动

```bash
./suda-campus.sh start
```

立即登录一次，并自动写入两条 cron 任务：

- 每隔 `INTERVAL`（默认 30）分钟执行一次连接
- 开机后 15 秒自动连接（`@reboot`）

## 4. 常用命令

```bash
./suda-campus.sh status   # 查看定时任务与本机校园网 IP
./suda-campus.sh connect  # 仅手动连接一次
./suda-campus.sh logout   # 仅手动登出
./suda-campus.sh stop     # 移除定时任务并登出
tail -f campus.log        # 查看运行日志
```

## 5. 多网卡场景

默认通过 `ip route get 10.9.1.3` 自动选择通往校园网网关的网卡。若服务器有多个网卡且选择错误，在 `suda-campus.conf` 中指定：

```bash
ip addr                   # 查看网卡名，常见如 eth0、ens33、enp0s3
```

然后把 `IFACE=""` 改为 `IFACE="eth0"`，重新执行 `./suda-campus.sh start`。

## 常见问题

- **`bad interpreter: /bin/bash\r`**：脚本是 Windows 换行符。仓库已通过 `.gitattributes` 强制 LF；若仍出现，执行 `sed -i 's/\r$//' suda-campus.sh` 修复。
- **无法访问网关**：确认服务器在校内、安全组 / iptables 未拦截 801 端口、未配置 HTTP 代理。
- **密码含特殊字符**：脚本使用 `curl --data-urlencode` 自动编码，直接照填即可，无需手动转义。
- **cron 到点没执行**：检查 cron 服务状态（`systemctl status crond` 或 `cron`），以及 `crontab -l` 中脚本路径是否为绝对路径（脚本会自动写入绝对路径）。
