---
layout: home

hero:
  name: mra
  text: Multi-Repo Agent
  tagline: 跨多個 repository 的 AI 輔助開發工具 — 只需一個終端機
  actions:
    - theme: brand
      text: 快速開始
      link: /zh-TW/guide/getting-started
    - theme: alt
      text: 在 GitHub 上查看
      link: https://github.com/hanfour/multi-repo-agent

features:
  - icon: 🌐
    title: 跨 Repo 協作
    details: 一次啟動 Claude 同時看見多個 repo。改一個 API，mra 自動找到並更新所有下游使用者。
    link: /zh-TW/guide/cross-repo-dev
    linkText: 了解更多
  - icon: 🔀
    title: 分支感知同步與 PR
    details: 讓多個 repo 保持在同一條功能分支，再依相依順序一起同步、開 PR、合併 — 並支援以 CI 為門檻的自動合併。
    link: /zh-TW/commands/branch
    linkText: 了解更多
  - icon: 🧠
    title: 專案知識庫
    details: 四層記憶堆疊。每次 review 喚醒成本從 150K tokens 降到 250。每次 review 後自動更新。
  - icon: 🔍
    title: AI Code Review 辯論
    details: 根據 diff 大小自動選擇 light / standard / debate。Debate 模式用 mailbox voting 合併多 agent 發現。
    link: /zh-TW/commands/
  - icon: 👥
    title: 具名領域專家
    details: 可選 --personas 啟用 5 位具名專家（Security、API Contract、Performance、Refactoring、Test Architect）並行跑。
    link: /zh-TW/features/personas
  - icon: 📋
    title: Council Plan
    details: mra plan 召集多位專家獨立提策略，再合成統一計畫。
  - icon: 🧪
    title: Kent Beck 測試稽核
    details: mra test-audit 用 Kent Beck 11 原則檢視測試檔案。
---
