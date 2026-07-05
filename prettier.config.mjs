const config = {
  bracketSpacing: false,
  endOfLine: 'lf',
  singleQuote: true,
  printWidth: 80,
  plugins: ['prettier-plugin-organize-imports'],
  overrides: [
    {
      files: '*.md',
      options: {
        proseWrap: 'always',
      },
    },
  ],
};

export default config;
