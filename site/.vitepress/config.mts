import { defineConfig } from 'vitepress'

export default defineConfig({
  base: '/multi-repo-agent/',
  lastUpdated: true,
  cleanUrls: true,
  head: [
    ['meta', { name: 'theme-color', content: '#3b82f6' }],
  ],
  themeConfig: {
    socialLinks: [
      { icon: 'github', link: 'https://github.com/hanfour/multi-repo-agent' },
    ],
    search: { provider: 'local' },
  },
  locales: {
    root: {
      label: 'English',
      lang: 'en',
      title: 'mra',
      description: 'AI-powered development across multiple repositories — from a single terminal',
      themeConfig: {
        nav: [
          { text: 'Guide', link: '/guide/getting-started' },
          { text: 'Features', link: '/features/personas' },
          { text: 'Commands', link: '/commands/' },
          { text: 'Architecture', link: '/architecture' },
          { text: 'FAQ', link: '/faq' },
          { text: 'GitHub', link: 'https://github.com/hanfour/multi-repo-agent' },
        ],
        sidebar: {
          '/guide/': [ { text: 'Guide', items: [
            { text: 'Getting Started', link: '/guide/getting-started' },
            { text: 'Cross-Repo Development', link: '/guide/cross-repo-dev' },
          ]}],
          '/commands/': [ { text: 'Commands', items: [
            { text: 'Overview', link: '/commands/' },
            { text: 'mra sync', link: '/commands/sync' },
            { text: 'mra branch', link: '/commands/branch' },
            { text: 'mra review', link: '/commands/review' },
            { text: 'mra plan', link: '/commands/plan' },
            { text: 'mra test-audit', link: '/commands/test-audit' },
            { text: 'mra analyze (PKB)', link: '/commands/pkb' },
          ]}],
          '/features/': [ { text: 'Features', items: [
            { text: 'Personas', link: '/features/personas' },
            { text: 'Mailbox Debate', link: '/features/debate' },
          ]}],
        },
        footer: {
          message: 'Released under the MIT License.',
          copyright: '© 2026 Hanfour Huang',
        },
      },
    },
    'zh-TW': {
      label: '繁體中文',
      lang: 'zh-TW',
      title: 'mra',
      description: '跨多個 repository 的 AI 輔助開發工具 — 只需一個終端機',
      themeConfig: {
        nav: [
          { text: '指南', link: '/zh-TW/guide/getting-started' },
          { text: '功能', link: '/zh-TW/features/personas' },
          { text: '指令', link: '/zh-TW/commands/' },
          { text: 'FAQ', link: '/zh-TW/faq' },
          { text: 'GitHub', link: 'https://github.com/hanfour/multi-repo-agent' },
        ],
        sidebar: {
          '/zh-TW/guide/': [ { text: '指南', items: [
            { text: '快速開始', link: '/zh-TW/guide/getting-started' },
            { text: '跨 Repo 開發', link: '/zh-TW/guide/cross-repo-dev' },
          ]}],
          '/zh-TW/commands/': [ { text: '指令', items: [
            { text: '總覽', link: '/zh-TW/commands/' },
            { text: 'mra sync', link: '/zh-TW/commands/sync' },
            { text: 'mra branch', link: '/zh-TW/commands/branch' },
          ]}],
          '/zh-TW/features/': [ { text: '功能', items: [
            { text: 'Personas', link: '/zh-TW/features/personas' },
          ]}],
        },
        footer: {
          message: '依 MIT 授權發佈。',
          copyright: '© 2026 Hanfour Huang',
        },
      },
    },
    ja: {
      label: '日本語',
      lang: 'ja',
      link: 'https://github.com/hanfour/multi-repo-agent/blob/main/docs/README.ja.md',
    },
    ko: {
      label: '한국어',
      lang: 'ko',
      link: 'https://github.com/hanfour/multi-repo-agent/blob/main/docs/README.ko.md',
    },
  },
})
