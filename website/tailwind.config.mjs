/** @type {import('tailwindcss').Config} */
export default {
  content: ['./src/**/*.{astro,html,js,ts,jsx,tsx,md,mdx,svelte,vue}'],
  theme: {
    extend: {
      colors: {
        ink: { 950: '#0A0B0F', 900: '#0E1014', 800: '#181B22', 700: '#1A1E26' },
        cy: { 300: '#5EEAD4', 400: '#38BDF8' },
        kind: {
          approval: '#5EEAD4',
          question: '#38BDF8',
          idle: '#FBBF24',
          rate:     '#E06464',
        },
        brand: { claude: '#E89E64', codex: '#10A37F' },
        mute: { fg: '#8B92A1', dim: '#5C6370' },
      },
      fontFamily: {
        sans: ['Inter', 'system-ui', '-apple-system', 'sans-serif'],
        mono: ['"JetBrains Mono"', '"SF Mono"', 'ui-monospace', 'monospace'],
      },
      maxWidth: { content: '1296px' },
      animation: {
        'pulse-ring': 'pulse-ring 2.4s cubic-bezier(0.215,0.61,0.355,1) infinite',
        'pulse-ring-delay': 'pulse-ring 2.4s cubic-bezier(0.215,0.61,0.355,1) 0.8s infinite',
      },
      keyframes: {
        'pulse-ring': {
          '0%':   { transform: 'scale(0.6)', opacity: '0.5' },
          '100%': { transform: 'scale(1.1)', opacity: '0' },
        },
      },
    },
  },
};
