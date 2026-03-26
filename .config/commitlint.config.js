// commitlint.config.js
// 规范: https://www.conventionalcommits.org
// 规则: https://commitlint.js.org/reference/rules

/** @type {import('@commitlint/types').UserConfig} */
module.exports = {
  extends: ['@commitlint/config-conventional'],

  rules: {
    // ── type ──────────────────────────────────────────────────
    'type-empty': [2, 'never'],
    'type-case':  [2, 'always', 'lower-case'],
    'type-enum':  [2, 'always', [
      'feat',     // ✨ 新增功能
      'fix',      // 🐛 修复缺陷
      'docs',     // 📝 文档变更
      'style',    // 💄 格式调整（不影响逻辑）
      'refactor', // ♻️  代码重构
      'perf',     // ⚡️ 性能优化
      'test',     // ✅ 测试相关
      'build',    // 📦 构建 / 依赖
      'ci',       // 🎡 CI/CD
      'chore',    // 🔨 杂项维护
      'revert',   // ⏪️ 回退
    ]],

    // ── scope ─────────────────────────────────────────────────
    // warn 级别：允许 camelCase / PascalCase（适配组件/模块命名）
    'scope-case': [1, 'always', ['lower-case', 'camel-case', 'pascal-case']],

    // ── subject ───────────────────────────────────────────────
    'subject-empty':      [2, 'never'],
    'subject-full-stop':  [2, 'never', '.'],    // 结尾不加句号
    'subject-min-length': [2, 'always', 3],
    'subject-max-length': [2, 'always', 72],    // GitHub 显示截断阈值
    // warn 级别：不强制小写（中文 subject 无大小写概念）
    'subject-case': [1, 'never', ['sentence-case', 'start-case', 'pascal-case', 'upper-case']],

    // ── header ────────────────────────────────────────────────
    'header-max-length': [2, 'always', 100],

    // ── body ──────────────────────────────────────────────────
    'body-leading-blank':   [1, 'always'],      // body 前空一行
    'body-max-line-length': [2, 'always', 100],

    // ── footer ────────────────────────────────────────────────
    'footer-leading-blank':   [1, 'always'],    // footer 前空一行
    'footer-max-line-length': [2, 'always', 100],

    // Issue 关联由 commit-msg hook 独立校验，此处不重复限制
  },

  parserPreset: {
    parserOpts: {
      // 兼容 GitHub (#123) 和 Gitee (#ihq5ym, I456) 多种 Issue 编号风格
      // 支持大小写不敏感的 Issue 前缀
      issuePrefixes: ['#', 'I'],
    },
  },
};
