# 双色球推演器 · Web 版（Vercel 纯前端）

16 种统计方法加权推演 + 反拥挤过滤（P1 形态 / P2 生日号 / P4 历史重复），纯前端运行，零后端。

## 文件
- `index.html` — 手机友好界面（推演 / 记录 / 过程日志）
- `predictor.js` — 核心算法（16方法 + 加权随机 + 组合枚举 + 过滤）
- `history.json` — 3506 期历史数据（2003-02-23 ~ 2026-09-20，源 17500.cn）
- `vercel.json` — 纯静态部署配置

## 本地预览
直接双击 `index.html` 即可在浏览器打开（需 history.json 在同目录）。

## 部署到 Vercel
1. 把本目录推到 GitHub 仓库（如 `ssq-predictor`）
2. 登录 [vercel.com](https://vercel.com) → Import Project → 选该仓库
3. Vercel 自动识别 `vercel.json`，部署完成拿到 `https://xxx.vercel.app`
4. iPhone 打开网址 → 分享 → 添加到主屏，像 App 一样用

## 更新数据
history.json 打包在前端，新期开奖后：
1. 本地更新 history.json（可跑 Python 版 ssq-web/datastore.py 增量导入）
2. 把新 history.json 推上仓库
3. Vercel 自动重新部署

## 合规
个人自用工具，不上架公开传播。页面已含"仅供娱乐参考"提示。
