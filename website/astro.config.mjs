import { defineConfig } from 'astro/config';
import tailwind from '@astrojs/tailwind';

// GitHub Pages deploys to /<repo>/ unless you use a custom domain.
// `site` is the production URL; `base` is the path prefix.
export default defineConfig({
  site: 'https://riot-io-pty-ltd.github.io',
  base: '/page/',
  trailingSlash: 'always',
  integrations: [tailwind()],
});
