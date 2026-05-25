# x-ui + Nginx + SSL 一键安装脚本

自动部署 x-ui 面板并配置 Nginx 反向代理 + Let's Encrypt SSL 证书。

## 功能

- 自动安装 x-ui（Xray 管理面板）
- 自动安装 Nginx 并配置反向代理
- 随机生成 UUID 分流路径和端口，提高安全性
- 自动签发 Let's Encrypt ECC SSL 证书（90 天自动续期）
- 通过 x-ui API 自动配置入站规则
- 自动输出 VMess 分享链接

## 使用方式

```bash
bash <(curl -Ls https://raw.githubusercontent.com/yang639/x-ui-nginx-install/master/install.sh)
```

或本地运行：

```bash
chmod +x install.sh
./install.sh
```

按提示输入要绑定的域名即可。

## 部署架构

```
用户 → Nginx (443 SSL)
  ├── /                    → 反代 AList 站点
  ├── /{随机 UUID}         → Xray (VMess + WebSocket)
  └── /{随机 UUID}-xui     → x-ui 管理面板
```

## 注意事项

- 需要 root 权限运行
- 域名需提前解析到服务器 IP
- 80/443 端口不能被占用
- x-ui 默认账号密码为 `admin/admin`，安装后请尽快修改
