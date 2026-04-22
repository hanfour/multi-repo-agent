import { defineConfig } from 'vitepress'

export default defineConfig({
  base: '/multi-repo-agent/',
  title: 'mra',
  description: 'AI-powered development across multiple repositories — from a single terminal',
  lastUpdated: true,
  cleanUrls: true,
  ignoreDeadLinks: [/^\/commands\//],
  head: [
    ['meta', { name: 'theme-color', content: '#3b82f6' }],
  ],
  themeConfig: {
    nav: [
      { text: 'Guide', link: '/guide/getting-started' },
      { text: 'Commands', link: '/commands/' },
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
