import { defineConfig } from 'vitepress'

export default defineConfig({
  base: '/multi-repo-agent/',
  title: 'mra',
  description: 'AI-powered development across multiple repositories — from a single terminal',
  lastUpdated: true,
  cleanUrls: true,
  head: [
    ['meta', { name: 'theme-color', content: '#3b82f6' }],
  ],
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
      '/guide/': [
        {
          text: 'Guide',
          items: [
            { text: 'Getting Started', link: '/guide/getting-started' },
            { text: 'Cross-Repo Development', link: '/guide/cross-repo-dev' },
          ],
        },
      ],
      '/features/': [
        {
          text: 'Features',
          items: [
            { text: 'Personas', link: '/features/personas' },
            { text: 'Mailbox Debate', link: '/features/debate' },
          ],
        },
      ],
      '/commands/': [
        {
          text: 'Commands',
          items: [
            { text: 'Overview', link: '/commands/' },
            { text: 'mra review', link: '/commands/review' },
            { text: 'mra plan', link: '/commands/plan' },
            { text: 'mra test-audit', link: '/commands/test-audit' },
            { text: 'mra analyze (PKB)', link: '/commands/pkb' },
          ],
        },
      ],
    },
    socialLinks: [
      { icon: 'github', link: 'https://github.com/hanfour/multi-repo-agent' },
    ],
    footer: {
      message: 'Released under the MIT License.',
      copyright: '© 2026 Hanfour Huang',
    },
    search: { provider: 'local' },
  },
})
