---
layout: home

hero:
  name: mra
  text: Multi-Repo Agent
  tagline: AI-powered development across multiple repositories — from a single terminal
  actions:
    - theme: brand
      text: Get Started
      link: /guide/getting-started
    - theme: alt
      text: View on GitHub
      link: https://github.com/hanfour/multi-repo-agent

features:
  - icon: 🌐
    title: Cross-Repo Orchestration
    details: Launch Claude with visibility into multiple repos at once. Change an API in repo A — mra finds and updates every consumer.
    link: /guide/cross-repo-dev
    linkText: Learn more
  - icon: 🔀
    title: Branch-Aware Sync & PRs
    details: Keep many repos on one feature branch, then sync, open PRs, and merge them together in dependency order — with CI-gated auto-merge.
    link: /commands/branch
    linkText: Learn more
  - icon: 🧠
    title: Project Knowledge Base
    details: 4-layer memory stack. Review wake-up drops from 150K tokens to 250. Auto-updates after each review.
    link: /commands/pkb
  - icon: 🔍
    title: AI Code Review with Debate
    details: Auto-selects light / standard / debate based on diff size. Mailbox-voting debate mode merges findings from parallel agents.
    link: /commands/review
  - icon: 👥
    title: Named Domain Experts
    details: Opt-in --personas runs 5 named experts (Security, API Contract, Performance, Refactoring, Test Architect) in parallel.
    link: /features/personas
  - icon: 📋
    title: Council Plan
    details: mra plan convenes multiple experts to independently propose strategies, then synthesises a unified plan.
    link: /commands/plan
  - icon: 🧪
    title: Kent Beck Test Audit
    details: mra test-audit scores test files against Kent Beck's 11 principles to surface fragility and design smells.
    link: /commands/test-audit
---
