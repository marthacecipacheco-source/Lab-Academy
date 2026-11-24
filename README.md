# Lab Academy · Plataforma Interna de Formación Académica

Plataforma web interna de formación y entrenamiento operativo para el Laboratorio Clínico de Ecopetrol.
Primer curso: **Operación del cobas c 111** (8 módulos, lecciones interactivas, simulador de problemas reales, evaluaciones calificadas en el servidor y certificados verificables con código QR).

---

## Stack Tecnológico

- **Frontend:** Vite + React 18 + TypeScript + Tailwind CSS + React Router v6
- **Backend y Base de Datos:** Supabase (PostgreSQL, Row Level Security, Auth, RPCs y Storage)
- **Certificados y QR:** Generación en navegador de PDF horizontal A4 y matriz QR ISO/IEC 18004

---

## Ejecución en Desarrollo Local

1. **Instalar dependencias:**
   ```bash
   npm install
   # En Windows PowerShell si la política de scripts restringe npm.ps1:
   npm.cmd install
   ```

2. **Configurar variables de entorno (`.env.local`):**
   Crea el archivo `.env.local` en la raíz del proyecto (este archivo está en `.gitignore` y nunca debe subirse a GitHub):
   ```env
   VITE_SUPABASE_URL=https://TU_PROYECTO.supabase.co
   VITE_SUPABASE_ANON_KEY=TU_CLAVE_ANON_PUBLICA
   ```
   > **Seguridad:** Nunca uses ni expongas la clave `service_role` en la aplicación.

3. **Configurar la base de datos en Supabase:**
   - En **Supabase → SQL Editor**, pega y ejecuta `PASO_UNICO_SUPABASE.sql` (o en orden: `1_schema.sql`, `2_seed_cobas_c111.sql` y `3_modulo1_contenido.sql`).
   - Coloca los logos institucionales en `public/assets/logo-ecopetrol.png` y `public/assets/logo-lab-academy.png`.

4. **Iniciar el servidor de desarrollo:**
   ```bash
   npm run dev
   # O haciendo doble clic en iniciar_servidor.bat en Windows
   ```
   Abre `http://localhost:5173` en el navegador.

---

## Despliegue en GitHub y Vercel

1. **Subir a GitHub:**
   - Crea un repositorio **privado** en GitHub.
   - Verifica que `.env.local` esté ignorado en `.gitignore`.
   - Sube el código (`git init`, `git add .`, `git commit -m "Lab Academy"`, `git push`).

2. **Importar en Vercel:**
   - En [vercel.com](https://vercel.com) selecciona **Add New → Project** e importa el repositorio de GitHub.
   - En **Environment Variables** agrega:
     - `VITE_SUPABASE_URL`
     - `VITE_SUPABASE_ANON_KEY`
   - Haz clic en **Deploy**.

3. **Autorizar el dominio en Supabase:**
   - Ve a **Supabase → Authentication → URL Configuration**.
   - En **Site URL** y **Redirect URLs** agrega la dirección `https://tu-proyecto.vercel.app` asignada por Vercel.
