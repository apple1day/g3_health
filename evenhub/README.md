# 健康速览 — Even Hub 插件

手机中的设置页 + G2 上的睡眠、活动、最近运动、最近心率四页。读取本项目 iPhone App 上传到个人服务的摘要。

- SDK 固定 `@evenrealities/even_hub_sdk@0.0.16`，最低 Even Realities App **2.2.10**。
- CLI 固定 `@evenrealities/evenhub-cli@0.2.0`。
- 推荐 Node.js 24 LTS。可使用 Node 22.13+。
- 浏览器只做内容预览；真实眼镜显示须由 Even 官方 App 加载插件。
- 演示模式由用户明确开启，始终标注，不会作为真实数据上传或自动替代错误结果。

## 1. 浏览器预览

```bash
cd evenhub
npm ci
npm run dev
```

打开 `http://localhost:5173`，点击 **开启演示**。也可以填写个人服务地址和 `READ_TOKEN` 读取真实摘要。`UPLOAD_TOKEN` 不能用于这里。

## 2. 同一 Wi-Fi 的手机 / G2 本地测试

先按照根目录 README 启动数据服务，在 iPhone App 上传一次。假设 Mac 局域网 IP 为 `192.168.1.8`：

```bash
npm run configure -- --api-url http://192.168.1.8:8787 --allow-local-http
npm run dev
```

另开终端：

```bash
cd evenhub
npx evenhub qr --url http://192.168.1.8:5173
```

用 Even App 的开发者入口扫码。设置页的服务地址填 `http://192.168.1.8:8787`，密钥填写服务的 `READ_TOKEN`。手机上的 `localhost` 是手机自身，不是 Mac。

本地 HTTP 必须显式指定 `--allow-local-http`，仅接受 localhost、私有 IPv4 或 `.local` 地址。正式部署应使用 HTTPS。

插件网络需要同时满足：

1. `app.json` 的 `network.whitelist` 包含服务完整 origin（含协议与端口）。
2. 服务允许当前 WebView origin 的 CORS。本机开发可以显式设置 `ALLOWED_ORIGINS=*`，Bearer 密钥仍然必需。
3. iPhone 和 Mac 网络可互通，macOS 防火墙允许服务端口。

更改白名单后，Beta 包需要重新打包安装。设置页中改地址不会修改已安装包的权限。

## 3. HTTPS 与 Beta 打包

```bash
npm run configure -- --api-url https://health.example.com
npm run pack
```

输出为根目录 `artifacts/health-glance.ehpk`。生成的 `app.json` 只记录 API origin，绝不写入任何密钥。通过 Even Hub 开发者门户上传 Private 构建，再提升 Beta、激活测试者后安装。锁屏操作必须用 Beta 真机验证，QR 本地调试不能替代。

## 操作与状态

- 眼镜上下滑动：切换四页；单击：刷新个人服务摘要；双击：调用系统退出确认。
- 普通浏览器显示“浏览器预览”，不会假装眼镜已连接。
- 原生启动页返回 success（枚举值 0）后才显示眼镜页面已创建。
- 页面写入串行执行并合并快速重复请求。原生操作超时后停止写入，提示重新打开插件，避免超时请求与后续画面竞态。
- 心率显示实际 `measuredAt`；页底汇总时间为 iPhone `generatedAt`，不是实时测量。
- 暂无数据与 0 分开显示；读取失败保留本次打开期间的真实摘要并标注缓存。
- 演示数据与真实缓存分离；退出演示只恢复真实数据或无数据状态。

## 配置保存与数据

默认不持久保存只读密钥，也不把健康摘要写入浏览器磁盘。用户勾选“在此设备记住连接配置”后，服务地址和只读密钥会保存在本机 `localStorage`（不是系统钥匙串）。再次打开时自动尝试读取；不需要保存时取消勾选或点击“清除本机配置和缓存”。清除仅作用于本机，服务端删除在 iPhone App 里操作。

请求使用 `Authorization: Bearer ...`，不将密钥写入 URL；拒绝 HTTP 重定向，以避免凭据随重定向流出。生产使用 HTTPS。服务返回的健康字段与错误消息不通过 `innerHTML` 注入，不在控制台打印。

## 检查

```bash
npm run typecheck
npm test
npm run build
npm run pack
```

测试覆盖空值与零、日期/时区、旧数据、演示数据边界、活动模式、心率采样时间、SDK 事件 0、请求认证与重定向、响应格式/大小及 URL 校验。浏览器内容预览不能证明 HealthKit 或真机蓝牙成功。

## 官方参考

- [Even Hub 架构](https://hub.evenrealities.com/docs/get-started/architecture)
- [显示容器](https://hub.evenrealities.com/docs/build/display)
- [网络白名单与 CORS](https://hub.evenrealities.com/docs/build/networking)
- [Beta 与锁屏验收](https://hub.evenrealities.com/docs/ship/app-submission)
- 安装包中的 `node_modules/@evenrealities/even_hub_sdk/dist/index.d.ts` 是本次接口核对依据。
