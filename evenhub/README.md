# 健康速览 — Even Hub 插件

**插件 0.5.0**：手机中的设置与历史浏览页 + G2 上的睡眠、活动、最近运动、最近心率、历史五页。读取本项目 iPhone App 上传到个人服务的最新摘要与原始历史，兼容 App / Gin 后台 0.5.0。

## 0.5.0 的变化

- 保留四页最新摘要，新增「历史」页。按类型、来源、起始日期范围筛选已上传记录；睡眠来源包括实际共享到 Apple 健康并归档的 OPPO 等来源。
- 支持睡眠、步数、距离、活动能量、锻炼分钟、心率、运动、每日活动三环八类记录。每页 50 条，可翻阅更早或较新的记录；点选一条后，预览与 G2 显示该条记录。
- 来源覆盖范围和数量来自整个类型/日期筛选范围，不只统计当前页。来源使用后台返回的精确标识，不按显示名称猜测。
- 摘要与历史独立读取：没有今日摘要仍可查看归档；历史接口不可用不会破坏原有四页摘要。刷新失败仅保留相同筛选下的内存缓存，并标注缓存。
- 修正无数据画面、配置脚本中遗留的「只读密钥」提示，继续只填写服务地址。

### 已有版本升级

拉取更新后，在仓库根目录重新运行 `bash start-evenhub.sh`。浏览器或 QR 开发模式重新加载插件；已安装的 Beta 包需要重新打包和安装，单独更新 iPhone App 或后台不会更新旧包里的插件代码。

本轮无需重装 iPhone App、重建数据库或重新生成健康数据。服务地址保持原配置。按来源筛选需要 Gin 后台 0.5.0；旧 0.4 后台可浏览不带来源筛选的历史，旧 Python 服务不提供该功能。

### 在眼镜查看历史

1. 在 iPhone「历史 → 全部记录与同步」中主动开始/继续上传，保持手机与服务互通。只刷新今日摘要，不会自动上传逐条历史。
2. 在插件填写同一服务地址，打开「历史」，选择类型、来源和日期。
3. 点选一条记录，将它显示到眼镜。上下滑动仍在五个页面间切换；历史页单击刷新当前筛选，其他页单击刷新最新摘要。不同记录在手机端选择。

历史显示完整年份与记录自身时区下的采样时间，入库时间单独标记。日期筛选使用**样本开始日**，不等于手机睡眠页面的中午到中午统计日。睡眠中的卧床、清醒、未分类与未知分类分别显示；单条睡眠区间不是整夜总时长，原始步数等也不跨来源相加。最新睡眠摘要原有的优先来源规则不会因历史筛选而改变。

归档数量只表示服务器目前保存的条数，不能证明所有历史已同步完毕。没有记录时，在 iPhone 检查「全部记录与同步」和读取权限；OPPO 未共享到 Apple 健康的私有/云端数据不会出现在本插件。演示模式不会请求或显示个人历史，需退出演示后读取。

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

打开 `http://localhost:5173`，点击 **开启演示**。也可以填写个人服务地址读取真实摘要，无需 Token。

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

用 Even App 的开发者入口扫码。设置页的服务地址填 `http://192.168.1.8:8787`，不再填写密钥。手机上的 `localhost` 是手机自身，不是 Mac。

本地 HTTP 必须显式指定 `--allow-local-http`，仅接受 localhost、私有 IPv4 或 `.local` 地址。正式构建仍需 HTTPS，但本版服务无身份认证，只能在可信私有网络使用。

插件网络需要同时满足：

1. `app.json` 的 `network.whitelist` 包含服务完整 origin（含协议与端口）。
2. 服务允许当前 WebView origin 的 CORS。在 `backend/config.local.yaml` 的 `server.allowed-origins` 中允许实际 origin；CORS 不代替身份认证。
3. iPhone 和 Mac 网络可互通，macOS 防火墙允许服务端口。

更改白名单后，Beta 包需要重新打包安装。设置页中改地址不会修改已安装包的权限。

## 3. HTTPS 与 Beta 打包

```bash
npm run configure -- --api-url https://health.example.com
npm run pack
```

输出为根目录 `artifacts/health-glance.ehpk`。生成的 `app.json` 只记录 API origin，绝不写入任何密钥。通过 Even Hub 开发者门户上传 Private 构建，再提升 Beta、激活测试者后安装。锁屏操作必须用 Beta 真机验证，QR 本地调试不能替代。

## 操作与状态

- 眼镜上下滑动：切换五页；单击：刷新当前页所属的摘要或历史；双击：调用系统退出确认。
- 普通浏览器显示“浏览器预览”，不会假装眼镜已连接。
- 原生启动页返回 success（枚举值 0）后才显示眼镜页面已创建。
- 页面写入串行执行并合并快速重复请求。原生操作超时后停止写入，提示重新打开插件，避免超时请求与后续画面竞态。
- 心率显示实际 `measuredAt`；页底汇总时间为 iPhone `generatedAt`，不是实时测量。
- 暂无数据与 0 分开显示；读取失败保留本次打开期间的真实摘要并标注缓存。
- 演示数据与真实缓存分离；退出演示只恢复真实数据或无数据状态。

## 配置保存与数据

默认不保存服务地址或健康摘要。勾选“记住连接配置”后只保存 `{origin}` 到 localStorage；升级时删除旧配置中的 Token，保留地址。再次打开按地址读取，无需密钥。清除仅作用于本机，服务端数据在 iPhone 中删除。

**免 Token 服务只适合可信局域网。任何可达客户端都能访问健康数据，勿映射公网。**

## 检查

```bash
npm run typecheck
npm test
npm run build
npm run pack
```

测试覆盖空值与零、日期/时区、旧数据、演示数据边界、活动模式、心率采样时间、SDK 事件 0、免 Token 请求与重定向、响应格式/大小、URL 校验，以及历史来源精确匹配、分页、旧后台兼容和原始分类展示。`web-admin/tests/browser.mjs` 在隔离 Gin/MySQL CI 数据库中验证浏览器联调。浏览器内容预览不能证明 HealthKit 或真机蓝牙成功。

## 官方参考

- [Even Hub 架构](https://hub.evenrealities.com/docs/get-started/architecture)
- [显示容器](https://hub.evenrealities.com/docs/build/display)
- [网络白名单与 CORS](https://hub.evenrealities.com/docs/build/networking)
- [Beta 与锁屏验收](https://hub.evenrealities.com/docs/ship/app-submission)
- 安装包中的 `node_modules/@evenrealities/even_hub_sdk/dist/index.d.ts` 是本次接口核对依据。
