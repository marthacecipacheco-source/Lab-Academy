/** @type {import('tailwindcss').Config} */
export default {
  content: [
    "./index.html",
    "./src/**/*.{js,ts,jsx,tsx}",
  ],
  theme: {
    extend: {
      colors: {
        brand: {
          dark: '#032B4D',      // Azul marino profundo
          blue: '#063B66',      // Azul institucional
          mid: '#07599A',       // Azul medio
          ice: '#EAF6FC',       // Azul hielo
          turquoise: '#00B6C5', // Turquesa brillante
          cyan: '#20D4E8',      // Cian luminoso
          teal: '#0097A7',
          light: '#EAF6FC',
        }
      },
      fontFamily: {
        sans: ['"Plus Jakarta Sans"', 'system-ui', '-apple-system', 'BlinkMacSystemFont', '"Segoe UI"', 'Roboto', 'sans-serif'],
      },
      boxShadow: {
        'card': '0 10px 30px -5px rgba(3, 43, 77, 0.07), 0 4px 12px -2px rgba(6, 59, 102, 0.04)',
        'card-hover': '0 18px 40px -6px rgba(3, 43, 77, 0.12), 0 6px 16px -3px rgba(0, 182, 197, 0.08)',
        'glow': '0 8px 24px -4px rgba(0, 182, 197, 0.45)',
      }
    },
  },
  plugins: [],
};
