# 常见问题

## Manager Agent 启动超时

安装完成后如果 Manager Agent 迟迟没有响应，进容器查看日志：

```bash
docker exec -it hiclaw-manager cat /var/log/hiclaw/manager-agent.log
```

**情况一：日志中有进程退出记录**

可能是 Docker VM 分配的内存不足。建议将内存调整到 4GB 以上：Docker Desktop → Settings → Resources → Memory。调整后重新执行安装命令。

**情况二：日志中没有进程退出，但某些组件起不来**

可能是配置脏数据导致的。建议到原安装目录重新执行安装命令，选择**删除重装**：

```bash
bash <(curl -sSL https://higress.ai/hiclaw/install.sh)
```

安装脚本检测到已有安装时会询问处理方式，选择删除后重装即可清除脏数据。

---

## 局域网其他电脑如何访问 Web 端

**访问 Element Web**

在局域网其他电脑的浏览器中输入：

```
http://<局域网IP>:18088
```

浏览器可能会提示"不安全"或"不支持"，忽略提示直接点 Continue 进入即可。

**修改 Matrix Server 地址**

默认配置的 Matrix Server 域名解析到 `localhost`，在其他电脑上无法连通。登录 Element Web 时，需要将 Matrix Server 地址改为：

```
http://<局域网IP>:18080
```

例如局域网 IP 是 `192.168.1.100`，则填写 `http://192.168.1.100:18080`。

---

## 本地访问 Matrix 服务器不通

如果在本机也无法连接 Matrix 服务器，请检查浏览器或系统是否开启了代理。`*-local.hiclaw.io` 域名默认解析到 `127.0.0.1`，开启代理后请求会被转发到代理服务器，无法到达本地服务。

关闭代理，或将 `*-local.hiclaw.io` / `127.0.0.1` 加入代理的绕过列表即可。
