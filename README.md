# 双色球推演器 · 纯前端版（Cloudflare Pages）

16 种统计方法加权推演 + 反拥挤过滤（P1 形态 / P2 生日号 / P4 历史重复），零后端。

## 文件
- `index.html` — 手机界面
- `predictor.js` — 核心算法
- `history.json` — 3506 期历史数据（2003-02-23 ~ 2026-09-20）
- `.gitignore`

## 部署到 Cloudflare Pages
1. 登录 dash.cloudflare.com → Create → Pages → Connect to Git → 选本仓库
2. 不填任何构建命令（纯静态），直接 Deploy
3. 拿到 `*.pages.dev` 域名

## 本地预览
直接双击 `index.html`（需 `history.json`、`predictor.js` 同目录）。

## 更新数据
本地跑 Python 版增量导入后，把新 `history.json` 推上仓库，Pages 自动重新部署。

## 合规
个人自用工具，不上架公开传播。理性购彩。
