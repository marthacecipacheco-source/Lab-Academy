-- =====================================================================
-- LAB ACADEMY · SCRIPT TODO-EN-UNO PARA SUPABASE (SQL EDITOR)
-- Instrucciones:
-- 1. Selecciona TODO este archivo (Ctrl + A) y cópialo (Ctrl + C).
-- 2. En Supabase > SQL Editor > New query, borra lo que haya, pega esto (Ctrl + V) y pulsa RUN.
-- =====================================================================

-- ---------- 1. Tipos ----------
do $$ begin
  create type public.user_role as enum ('learner', 'supervisor', 'admin');
exception when duplicate_object then null;
end $$;

do $$ begin
  create type public.lesson_template as enum ('visual', 'procedure', 'simulator', 'activity', 'assessment');
exception when duplicate_object then null;
end $$;

-- ---------- 2. Tablas ----------
create table if not exists public.profiles (
  id          uuid primary key references auth.users(id) on delete cascade,
  full_name   text not null default '',
  email       text,
  area        text,
  role        public.user_role not null default 'learner',
  created_at  timestamptz not null default now()
);

create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, full_name, email)
  values (new.id, coalesce(new.raw_user_meta_data->>'full_name', ''), new.email)
  on conflict (id) do nothing;
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

create or replace function public.is_admin()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles where id = auth.uid() and role = 'admin');
$$;

create or replace function public.my_role()
returns public.user_role language sql stable security definer set search_path = public as $$
  select role from public.profiles where id = auth.uid();
$$;

create or replace function public.is_staff()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles where id = auth.uid() and role in ('admin', 'supervisor'));
$$;

create table if not exists public.courses (
  id           uuid primary key default gen_random_uuid(),
  slug         text unique not null,
  title        text not null,
  equipment    text,
  description  text,
  pass_score   numeric not null default 80,
  is_published boolean not null default false,
  created_at   timestamptz not null default now()
);

create table if not exists public.modules (
  id          uuid primary key default gen_random_uuid(),
  course_id   uuid not null references public.courses(id) on delete cascade,
  position    int not null,
  title       text not null,
  description text,
  unique (course_id, position)
);

create table if not exists public.lessons (
  id           uuid primary key default gen_random_uuid(),
  module_id    uuid not null references public.modules(id) on delete cascade,
  position     int not null,
  code         text,
  title        text not null,
  template     public.lesson_template not null,
  content      jsonb not null default '{}'::jsonb,
  is_published boolean not null default false,
  unique (module_id, position)
);

create table if not exists public.assessments (
  id                  uuid primary key default gen_random_uuid(),
  course_id           uuid not null references public.courses(id) on delete cascade,
  module_id           uuid references public.modules(id) on delete cascade,
  lesson_id           uuid references public.lessons(id) on delete set null,
  title               text not null,
  is_final            boolean not null default false,
  pass_score          numeric not null default 80,
  max_attempts        int,
  questions_per_attempt int not null default 5
);

create table if not exists public.questions (
  id            uuid primary key default gen_random_uuid(),
  assessment_id uuid not null references public.assessments(id) on delete cascade,
  prompt        text not null,
  scenario      text,
  image_url     text,
  options       jsonb not null,
  explanation   text,
  position      int not null default 0
);

create table if not exists public.question_keys (
  question_id uuid primary key references public.questions(id) on delete cascade,
  correct_ids text[] not null
);

create table if not exists public.enrollments (
  user_id     uuid not null references public.profiles(id) on delete cascade,
  course_id   uuid not null references public.courses(id) on delete cascade,
  assigned_by uuid references public.profiles(id),
  due_date    date,
  created_at  timestamptz not null default now(),
  primary key (user_id, course_id)
);

create table if not exists public.lesson_progress (
  user_id      uuid not null references public.profiles(id) on delete cascade,
  lesson_id    uuid not null references public.lessons(id) on delete cascade,
  completed_at timestamptz not null default now(),
  primary key (user_id, lesson_id)
);

create table if not exists public.attempts (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references public.profiles(id) on delete cascade,
  assessment_id uuid not null references public.assessments(id) on delete cascade,
  answers       jsonb not null,
  correct       int not null,
  total         int not null,
  score         numeric not null,
  passed        boolean not null,
  created_at    timestamptz not null default now()
);

create table if not exists public.certificates (
  id        uuid primary key default gen_random_uuid(),
  user_id   uuid not null references public.profiles(id) on delete cascade,
  course_id uuid not null references public.courses(id) on delete cascade,
  code      text unique not null,
  score     numeric not null,
  issued_at timestamptz not null default now(),
  unique (user_id, course_id)
);

-- ---------- 3. Funciones y Vistas ----------
create or replace function public.submit_attempt(p_assessment uuid, p_answers jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_uid     uuid := auth.uid();
  v_asmt    public.assessments%rowtype;
  v_used    int;
  v_expect  int;
  v_total   int := 0;
  v_correct int := 0;
  v_item    jsonb;
  v_keys    text[];
  v_sel     text[];
  v_score   numeric;
  v_passed  boolean;
  v_detail  jsonb := '[]'::jsonb;
  v_ok      boolean;
  v_expl    text;
begin
  if v_uid is null then raise exception 'Debe iniciar sesión'; end if;
  select * into v_asmt from public.assessments where id = p_assessment;
  if not found then raise exception 'Evaluación no existe'; end if;

  select count(*) into v_used from public.attempts where user_id = v_uid and assessment_id = p_assessment;
  if v_asmt.max_attempts is not null and v_used >= v_asmt.max_attempts then
    raise exception 'Se agotaron los intentos de esta evaluación';
  end if;

  select least(v_asmt.questions_per_attempt, count(*)) into v_expect
    from public.questions where assessment_id = p_assessment;
  if jsonb_array_length(p_answers) <> v_expect then
    raise exception 'Debe responder las % preguntas', v_expect;
  end if;

  for v_item in select * from jsonb_array_elements(p_answers) loop
    select k.correct_ids, q.explanation into v_keys, v_expl
      from public.questions q join public.question_keys k on k.question_id = q.id
     where q.id = (v_item->>'question_id')::uuid and q.assessment_id = p_assessment;
    if v_keys is null then raise exception 'Pregunta inválida'; end if;
    select coalesce(array_agg(x order by x), '{}') into v_sel
      from jsonb_array_elements_text(v_item->'selected') x;
    v_ok := (v_sel = (select array_agg(y order by y) from unnest(v_keys) y));
    v_total := v_total + 1;
    if v_ok then v_correct := v_correct + 1; end if;
    v_detail := v_detail || jsonb_build_object(
      'question_id', v_item->>'question_id', 'ok', v_ok,
      'correct_ids', to_jsonb(v_keys), 'explanation', v_expl);
  end loop;

  v_score  := round(100.0 * v_correct / greatest(v_total, 1), 1);
  v_passed := v_score >= v_asmt.pass_score;

  insert into public.attempts (user_id, assessment_id, answers, correct, total, score, passed)
  values (v_uid, p_assessment, p_answers, v_correct, v_total, v_score, v_passed);

  return jsonb_build_object('score', v_score, 'correct', v_correct, 'total', v_total,
                            'passed', v_passed, 'detail', v_detail);
end $$;

create or replace function public.issue_certificate(p_course uuid)
returns public.certificates language plpgsql security definer set search_path = public as $$
declare
  v_uid     uuid := auth.uid();
  v_pending int;
  v_best    numeric;
  v_cert    public.certificates%rowtype;
begin
  if v_uid is null then raise exception 'Debe iniciar sesión'; end if;

  select * into v_cert from public.certificates where user_id = v_uid and course_id = p_course;
  if found then return v_cert; end if;

  select count(*) into v_pending
    from public.lessons l join public.modules m on m.id = l.module_id
   where m.course_id = p_course and l.is_published
     and l.template <> 'assessment'
     and not exists (select 1 from public.lesson_progress lp where lp.lesson_id = l.id and lp.user_id = v_uid);
  if v_pending > 0 then raise exception 'Aún faltan % lecciones por completar', v_pending; end if;

  select max(at.score) into v_best
    from public.attempts at join public.assessments a on a.id = at.assessment_id
   where at.user_id = v_uid and a.course_id = p_course and a.is_final and at.passed;
  if v_best is null then raise exception 'Debe aprobar la evaluación final'; end if;

  insert into public.certificates (user_id, course_id, code, score)
  values (v_uid, p_course, 'LA-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 10)), v_best)
  returning * into v_cert;
  return v_cert;
end $$;

create or replace function public.verify_certificate(p_code text)
returns table (full_name text, course_title text, equipment text, score numeric, issued_at timestamptz)
language sql stable security definer set search_path = public as $$
  select p.full_name, c.title, c.equipment, ce.score, ce.issued_at
    from public.certificates ce
    join public.profiles p on p.id = ce.user_id
    join public.courses  c on c.id = ce.course_id
   where ce.code = upper(trim(p_code));
$$;

create or replace view public.course_progress with (security_invoker = true) as
select e.user_id, e.course_id,
       count(l.id) filter (where l.template <> 'assessment')                        as total_lessons,
       count(lp.lesson_id) filter (where l.template <> 'assessment')                as done_lessons,
       case when count(l.id) filter (where l.template <> 'assessment') = 0 then 0
            else round(100.0 * count(lp.lesson_id) filter (where l.template <> 'assessment')
                       / count(l.id) filter (where l.template <> 'assessment'), 0) end as percent
  from public.enrollments e
  join public.modules m on m.course_id = e.course_id
  join public.lessons l on l.module_id = m.id and l.is_published
  left join public.lesson_progress lp on lp.lesson_id = l.id and lp.user_id = e.user_id
 group by e.user_id, e.course_id;

-- ---------- 4. Seguridad (Row Level Security) ----------
alter table public.profiles        enable row level security;
alter table public.courses         enable row level security;
alter table public.modules         enable row level security;
alter table public.lessons         enable row level security;
alter table public.assessments     enable row level security;
alter table public.questions       enable row level security;
alter table public.question_keys   enable row level security;
alter table public.enrollments     enable row level security;
alter table public.lesson_progress enable row level security;
alter table public.attempts        enable row level security;
alter table public.certificates    enable row level security;

drop policy if exists "ver perfil propio o staff" on public.profiles;
create policy "ver perfil propio o staff" on public.profiles for select to authenticated
  using (id = auth.uid() or public.is_staff());

drop policy if exists "editar perfil propio" on public.profiles;
create policy "editar perfil propio" on public.profiles for update to authenticated
  using (id = auth.uid()) with check (id = auth.uid() and role = public.my_role());

drop policy if exists "admin gestiona perfiles" on public.profiles;
create policy "admin gestiona perfiles" on public.profiles for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

drop policy if exists "leer cursos" on public.courses;
create policy "leer cursos" on public.courses for select to authenticated using (is_published or public.is_admin());
drop policy if exists "admin cursos" on public.courses;
create policy "admin cursos" on public.courses for all to authenticated using (public.is_admin()) with check (public.is_admin());

drop policy if exists "leer módulos" on public.modules;
create policy "leer módulos" on public.modules for select to authenticated using (true);
drop policy if exists "admin módulos" on public.modules;
create policy "admin módulos" on public.modules for all to authenticated using (public.is_admin()) with check (public.is_admin());

drop policy if exists "leer lecciones" on public.lessons;
create policy "leer lecciones" on public.lessons for select to authenticated using (is_published or public.is_admin());
drop policy if exists "admin lecciones" on public.lessons;
create policy "admin lecciones" on public.lessons for all to authenticated using (public.is_admin()) with check (public.is_admin());

drop policy if exists "leer evaluaciones" on public.assessments;
create policy "leer evaluaciones" on public.assessments for select to authenticated using (true);
drop policy if exists "admin evaluaciones" on public.assessments;
create policy "admin evaluaciones" on public.assessments for all to authenticated using (public.is_admin()) with check (public.is_admin());

drop policy if exists "leer preguntas" on public.questions;
create policy "leer preguntas" on public.questions for select to authenticated using (true);
drop policy if exists "admin preguntas" on public.questions;
create policy "admin preguntas" on public.questions for all to authenticated using (public.is_admin()) with check (public.is_admin());

drop policy if exists "solo admin ve respuestas" on public.question_keys;
create policy "solo admin ve respuestas" on public.question_keys for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

drop policy if exists "ver matrículas" on public.enrollments;
create policy "ver matrículas" on public.enrollments for select to authenticated using (user_id = auth.uid() or public.is_staff());
drop policy if exists "admin matrículas" on public.enrollments;
create policy "admin matrículas" on public.enrollments for all to authenticated using (public.is_admin()) with check (public.is_admin());

drop policy if exists "ver avance" on public.lesson_progress;
create policy "ver avance" on public.lesson_progress for select to authenticated using (user_id = auth.uid() or public.is_staff());
drop policy if exists "marcar avance" on public.lesson_progress;
create policy "marcar avance" on public.lesson_progress for insert to authenticated with check (user_id = auth.uid());

drop policy if exists "ver intentos" on public.attempts;
create policy "ver intentos" on public.attempts for select to authenticated using (user_id = auth.uid() or public.is_staff());
drop policy if exists "ver certificados" on public.certificates;
create policy "ver certificados" on public.certificates for select to authenticated using (user_id = auth.uid() or public.is_staff());

revoke all on function public.submit_attempt(uuid, jsonb) from public;
revoke all on function public.issue_certificate(uuid)    from public;
grant execute on function public.submit_attempt(uuid, jsonb) to authenticated;
grant execute on function public.issue_certificate(uuid)    to authenticated;
grant execute on function public.verify_certificate(text)   to anon, authenticated;
grant execute on function public.is_admin(), public.is_staff(), public.my_role() to authenticated;

insert into storage.buckets (id, name, public) values ('lesson-media', 'lesson-media', true)
on conflict (id) do nothing;

drop policy if exists "admin sube medios" on storage.objects;
create policy "admin sube medios" on storage.objects for all to authenticated
  using (bucket_id = 'lesson-media' and public.is_admin())
  with check (bucket_id = 'lesson-media' and public.is_admin());

-- ---------- 5. Semilla del curso cobas c 111 (7 módulos, 38 lecciones) ----------
do $$
declare
  c uuid; m uuid;
begin
  if not exists (select 1 from public.courses where slug = 'cobas-c111') then
    insert into public.courses (slug, title, equipment, description, pass_score, is_published)
    values ('cobas-c111', 'Operación del cobas c 111', 'cobas c 111',
            'Formación interna para la operación diaria del analizador cobas c 111: encendido, preparación, calibración, control de calidad, muestras, validación, fin de turno y mantenimiento.',
            80, true)
    returning id into c;

    insert into public.modules (course_id, position, title, description) values (c, 1, 'Conociendo el cobas c 111', 'Equipo, componentes, seguridad y encendido.') returning id into m;
    insert into public.lessons (module_id, position, code, title, template, is_published) values
     (m,1,'1.1','¿Qué es el cobas c 111?','visual',true),
     (m,2,'1.2','Reconocimiento de las partes y componentes','visual',true),
     (m,3,'1.3','Preparación y seguridad antes de operar','activity',true),
     (m,4,'1.4','Encendido, inicio y verificación del equipo','procedure',true);
    insert into public.assessments (course_id, module_id, title, pass_score, questions_per_attempt) values (c, m, 'Evaluación del módulo 1', 80, 5);

    insert into public.modules (course_id, position, title, description) values (c, 2, 'Preparación del analizador', 'Asistente Preparar, fluidos, impresora, reactivos y cubetas.') returning id into m;
    insert into public.lessons (module_id, position, code, title, template, is_published) values
     (m,1,'2.1','Asistente Preparar','procedure',true),
     (m,2,'2.2','Contenedores externos de fluidos','procedure',true),
     (m,3,'2.3','Verificación de agua, residuos y agente limpiador','activity',true),
     (m,4,'2.4','Verificación de impresora','visual',true),
     (m,5,'2.5','Disco y reactivos','procedure',true),
     (m,6,'2.6','Segmentos de cubetas','procedure',true);
    insert into public.assessments (course_id, module_id, title, pass_score, questions_per_attempt) values (c, m, 'Evaluación del módulo 2', 80, 5);

    insert into public.modules (course_id, position, title, description) values (c, 3, 'Calibración y control de calidad', 'Calibradores, calibración, CC y validación.') returning id into m;
    insert into public.lessons (module_id, position, code, title, template, is_published) values
     (m,1,'3.1','Conceptos de calibración','visual',true),
     (m,2,'3.2','Preparación de calibradores','procedure',true),
     (m,3,'3.3','Ejecución de calibraciones','simulator',true),
     (m,4,'3.4','Validación de calibraciones','simulator',true),
     (m,5,'3.5','Control de calidad interno','procedure',true),
     (m,6,'3.6','Interpretación y validación de controles','simulator',true);
    insert into public.assessments (course_id, module_id, title, pass_score, questions_per_attempt) values (c, m, 'Evaluación del módulo 3', 80, 5);

    insert into public.modules (course_id, position, title, description) values (c, 4, 'Procesamiento de muestras', 'Órdenes, muestras rutinarias y STAT, colocación de tubos.') returning id into m;
    insert into public.lessons (module_id, position, code, title, template, is_published) values
     (m,1,'4.1','Tipos de muestras y condiciones','visual',true),
     (m,2,'4.2','Identificación y registro de órdenes','procedure',true),
     (m,3,'4.3','Procesamiento de muestras rutinarias','procedure',true),
     (m,4,'4.4','Procesamiento de muestras STAT','procedure',true),
     (m,5,'4.5','Colocación y retiro de tubos','activity',true),
     (m,6,'4.6','Simulación de procesamiento','simulator',true);
    insert into public.assessments (course_id, module_id, title, pass_score, questions_per_attempt) values (c, m, 'Evaluación del módulo 4', 80, 5);

    insert into public.modules (course_id, position, title, description) values (c, 5, 'Validación y gestión de resultados', 'Consulta, indicadores, aceptar, repetir y reprocesar.') returning id into m;
    insert into public.lessons (module_id, position, code, title, template, is_published) values
     (m,1,'5.1','Consulta de resultados','visual',true),
     (m,2,'5.2','Revisión de indicadores','visual',true),
     (m,3,'5.3','Aceptar resultados','procedure',true),
     (m,4,'5.4','Repetir o reprocesar pruebas','simulator',true),
     (m,5,'5.5','Transmisión de resultados, cuando aplique','visual',true);
    insert into public.assessments (course_id, module_id, title, pass_score, questions_per_attempt) values (c, m, 'Evaluación del módulo 5', 80, 5);

    insert into public.modules (course_id, position, title, description) values (c, 6, 'Gestión de series y fin de turno', 'Detener y reiniciar series, fin de turno y copias de seguridad.') returning id into m;
    insert into public.lessons (module_id, position, code, title, template, is_published) values
     (m,1,'6.1','Detención de una serie','procedure',true),
     (m,2,'6.2','Recuperación y reinicio','procedure',true),
     (m,3,'6.3','Verificación de órdenes pendientes','activity',true),
     (m,4,'6.4','Resultados sin validar','activity',true),
     (m,5,'6.5','Asistente Fin turno','procedure',true),
     (m,6,'6.6','Copia de seguridad y exportación','procedure',true);
    insert into public.assessments (course_id, module_id, title, pass_score, questions_per_attempt) values (c, m, 'Evaluación del módulo 6', 80, 5);

    insert into public.modules (course_id, position, title, description) values (c, 7, 'Mantenimiento y contingencias', 'Mantenimiento, limpieza, ISE, alarmas y servicio técnico.') returning id into m;
    insert into public.lessons (module_id, position, code, title, template, is_published) values
     (m,1,'7.1','Mantenimiento rutinario','procedure',true),
     (m,2,'7.2','Limpieza del equipo','procedure',true),
     (m,3,'7.3','Mantenimiento de la unidad ISE, si está instalada','procedure',true),
     (m,4,'7.4','Alarmas y situaciones de contingencia','simulator',true),
     (m,5,'7.5','Cuándo solicitar servicio técnico','visual',true);
    insert into public.assessments (course_id, module_id, title, is_final, pass_score, max_attempts, questions_per_attempt)
    values (c, null, 'Evaluación final integradora', true, 80, 3, 15);
  end if;
end $$;

-- ---------- 6. Contenido y preguntas del Módulo 1 ----------
update public.lessons set is_published = true, content = $json${"intro": "El cobas c 111 es un analizador continuo de acceso aleatorio para la determinación in vitro de parámetros clínicos y electrolitos mediante fotometría de absorbancia, con unidad ISE opcional (Na⁺, K⁺ y Cl⁻). Está optimizado para una capacidad de hasta 50 muestras diarias.", "image": "cobas-c111/modulo-1/equipo-partes.png", "hotspots": [], "key_points": ["Procesa muestras de suero, plasma, orina y sangre total con EDTA.", "Tiene 8 posiciones de muestra, un disco de reactivos refrigerado y segmentos de cubetas desechables.", "Se maneja desde una pantalla táctil y cuenta con un lector de códigos de barras de mano.", "Solo lo opera personal autorizado que ha recibido la formación del fabricante.", "Este curso se basa en el instructivo del laboratorio y en la Guía del usuario del fabricante (versión 4.3, software 4.2)."]}$json$::jsonb
 where code = '1.1' and module_id = (select m.id from public.modules m join public.courses c on c.id=m.course_id where c.slug='cobas-c111' and m.position=1);

update public.lessons set is_published = true, content = $json${"intro": "Toca cada punto de la fotografía para reconocer las partes del equipo que usarás todos los días.", "image": "cobas-c111/modulo-1/equipo-partes.png", "hotspots": [{"x": 10.9, "y": 27.5, "label": "1. Unidad de pipeteo", "text": "Aspira, dispensa y mezcla las muestras y los reactivos."}, {"x": 30.7, "y": 51.5, "label": "2. Tapa del analizador", "text": "Da acceso al sistema de reacción y medición (fotometría)."}, {"x": 53, "y": 46, "label": "3. Posiciones de muestras", "text": "Permite cargar hasta 8 muestras. Un LED indica cuándo puede colocar tubos."}, {"x": 56, "y": 55, "label": "4. Pantalla táctil", "text": "Interfaz de operación del equipo: menú de trabajo, resultados, configuración y utilidades."}, {"x": 31.9, "y": 80.2, "label": "5. Indicador de estado", "text": "Luz que muestra el estado del equipo (listo, en proceso o alerta)."}, {"x": 52.9, "y": 80.5, "label": "6. Impresora", "text": "Emite los resultados de los análisis."}], "key_points": ["Además de lo que ves en la foto, el sistema usa contenedores externos: agua (blanco), residuos (amarillo) y agente limpiador.", "El interruptor principal de corriente tiene dos posiciones: I = encendido y O = apagado.", "El software tiene tres pestañas: General, Área de trabajo y Utilidades."]}$json$::jsonb
 where code = '1.2' and module_id = (select m.id from public.modules m join public.courses c on c.id=m.course_id where c.slug='cobas-c111' and m.position=1);

update public.lessons set is_published = true, content = $json${"type": "checklist", "instructions": "Marca únicamente las acciones que son correctas y seguras antes y durante la operación del analizador. Luego pulsa Comprobar.", "items": [{"text": "Usar el equipo de protección individual (EPP) adecuado.", "correct": true, "feedback": "Correcto: el EPP es obligatorio en todas las actividades."}, {"text": "Tratar las muestras, controles, calibradores y residuos líquidos como material potencialmente biopeligroso.", "correct": true, "feedback": "Correcto."}, {"text": "Mantener cerradas todas las cubiertas y tapas mientras el sistema está en funcionamiento.", "correct": true, "feedback": "Correcto."}, {"text": "Abrir la cubierta con el sistema en funcionamiento para ver mejor el pipeteo.", "correct": false, "feedback": "Incorrecto: antes de trabajar con una cubierta abierta, el sistema debe estar apagado o en estado Mantenimiento."}, {"text": "Consultar la hoja de método y la hoja de datos de seguridad de cada reactivo antes de manipularlo.", "correct": true, "feedback": "Correcto."}, {"text": "Tocar con la mano las piezas internas cercanas a la aguja para comprobar que están bien colocadas.", "correct": false, "feedback": "Incorrecto: no toque componentes distintos de los indicados en cada procedimiento y manténgase alejado de las piezas en movimiento."}, {"text": "Si se derrama material biopeligroso, limpiarlo de inmediato y aplicar un desinfectante.", "correct": true, "feedback": "Correcto."}, {"text": "Si un reactivo toca la piel, esperar al final del turno para lavarse.", "correct": false, "feedback": "Incorrecto: lave la zona de inmediato con agua y jabón, aplique un desinfectante y consulte a un médico."}, {"text": "Usar guantes sin preocuparse: no se pueden perforar ni cortar.", "correct": false, "feedback": "Incorrecto: los guantes pueden perforarse o cortarse con facilidad; preste especial cuidado."}]}$json$::jsonb
 where code = '1.3' and module_id = (select m.id from public.modules m join public.courses c on c.id=m.course_id where c.slug='cobas-c111' and m.position=1);

update public.lessons set is_published = true, content = $json${"objective": "Encender el analizador, acceder al sistema con tu cuenta personal, reconocer la pantalla General y realizar las verificaciones previas a la operación.", "warning": "No utilices la pantalla hasta que el sistema se encuentre en estado En espera.", "steps": [{"title": "Revisa las condiciones previas", "text": "Ponte el EPP y comprueba que todas las cubiertas estén cerradas, que los contenedores externos de fluidos estén conectados y que el área de muestras esté vacía."}, {"title": "Enciende el analizador", "text": "Pulsa el interruptor de corriente hasta dejarlo en la posición I.", "note": "Duración aproximada del inicio: 5 minutos."}, {"title": "Espera la inicialización", "text": "El sistema realiza sus comprobaciones y rutinas internas. Puede tardar varios minutos y se muestra una pantalla de presentación.", "note": "No toques la pantalla hasta que indique En espera."}, {"title": "Reconoce la pantalla General", "text": "Verifica que aparezca la pestaña General con el estado En espera. Observa las tres pestañas (General, Área de trabajo y Utilidades), las 8 posiciones de muestra, los botones STAT, Orden, Preparar y Fin turno, y los botones de estado.", "image": "cobas-c111/modulo-1/pantalla-general.png", "note": "Los botones de estado con franja roja requieren atención antes de operar."}, {"title": "Accede al sistema", "text": "En la pestaña General, selecciona el botón Acceder. Escribe tu nombre de usuario con el teclado de la pantalla y confirma; luego escribe tu contraseña personal y confirma.", "note": "El nombre de usuario y la contraseña distinguen mayúsculas y minúsculas."}, {"title": "Confirma que ingresaste", "text": "Debe reaparecer la pestaña General y el botón Acceder debe mostrar tu nombre de usuario."}, {"title": "Verifica alarmas de instrumentos", "text": "En el panel del botón global, abre el botón de alarmas y resuelve todos los problemas del instrumento. Si es necesario, reinicia el sistema."}, {"title": "Verifica los contenedores externos y la impresora", "text": "En General, pulsa el botón de estado del sistema y revisa los contenedores de agua, residuos y agente limpiador, y el estado de la impresora. Sustituye lo que haga falta y confirma.", "image": "cobas-c111/modulo-1/comprobar-botellas.png"}, {"title": "Verifica cubetas y reactivos", "text": "Revisa el botón de cubetas y el de reactivos. Cambia los segmentos y reactivos que lo necesiten.", "image": "cobas-c111/modulo-1/cubetas.png"}, {"title": "Revisa el mantenimiento y la unidad ISE", "text": "Abre el panel Mantenimiento y realiza todas las acciones pendientes. Si el equipo tiene ISE, revisa el panel Estado de la ISE.", "image": "cobas-c111/modulo-1/mantenimiento-lista.png", "note": "Más adelante, en el módulo 2, aprenderás cada una de estas preparaciones con el asistente Preparar."}]}$json$::jsonb
 where code = '1.4' and module_id = (select m.id from public.modules m join public.courses c on c.id=m.course_id where c.slug='cobas-c111' and m.position=1);

do $$
declare a uuid; q uuid;
begin
  select s.id into a from public.assessments s join public.modules m on m.id=s.module_id join public.courses c on c.id=s.course_id where c.slug='cobas-c111' and m.position=1;
  delete from public.questions where assessment_id = a;
  update public.assessments set questions_per_attempt = 5, pass_score = 80 where id = a;
  insert into public.questions (assessment_id, prompt, scenario, options, explanation, position) values (a, 'Eres la primera persona en llegar y el analizador está apagado. ¿Qué haces primero?', 'Es el inicio del turno. El equipo está apagado.', '[{"id": "a", "text": "Abrir la cubierta principal y cargar las muestras del día."}, {"id": "b", "text": "Verificar EPP, cubiertas cerradas, contenedores externos conectados y área de muestras vacía; después encenderlo."}, {"id": "c", "text": "Pulsar Parar > Recuperar."}, {"id": "d", "text": "Acceder con tu usuario y contraseña."}]'::jsonb, 'Antes de encender se revisan las condiciones previas: EPP puesto, cubiertas cerradas, contenedores externos conectados y área de muestras vacía.', 1) returning id into q;
  insert into public.question_keys (question_id, correct_ids) values (q, '{b}');
  insert into public.questions (assessment_id, prompt, scenario, options, explanation, position) values (a, '¿En qué posición debes dejar el interruptor de corriente para encender el analizador?', NULL, '[{"id": "a", "text": "I"}, {"id": "b", "text": "O"}, {"id": "c", "text": "Entre I y O"}, {"id": "d", "text": "Cualquiera; el equipo enciende solo al acceder"}]'::jsonb, 'La posición I es encendido y la posición O es apagado.', 2) returning id into q;
  insert into public.question_keys (question_id, correct_ids) values (q, '{a}');
  insert into public.questions (assessment_id, prompt, scenario, options, explanation, position) values (a, 'El analizador muestra la pantalla de presentación y un compañero quiere empezar a tocar la pantalla para ingresar. ¿Qué le indicas?', 'El sistema aún está iniciando.', '[{"id": "a", "text": "Que ingrese de inmediato para ganar tiempo."}, {"id": "b", "text": "Que apague y vuelva a encender."}, {"id": "c", "text": "Que espere a que el sistema indique En espera antes de usar la pantalla."}, {"id": "d", "text": "Que abra la cubierta principal."}]'::jsonb, 'Durante la inicialización (puede tardar varios minutos) no se debe utilizar la pantalla hasta que el sistema esté En espera.', 3) returning id into q;
  insert into public.question_keys (question_id, correct_ids) values (q, '{c}');
  insert into public.questions (assessment_id, prompt, scenario, options, explanation, position) values (a, 'Escribes tu nombre de usuario “carlos” pero fue creado como “Carlos” y el sistema no te deja entrar. ¿Cuál es la causa más probable?', NULL, '[{"id": "a", "text": "El equipo está en mantenimiento."}, {"id": "b", "text": "El nombre de usuario y la contraseña distinguen entre mayúsculas y minúsculas."}, {"id": "c", "text": "Falta cambiar el papel de la impresora."}, {"id": "d", "text": "Hay que reiniciar el analizador."}]'::jsonb, 'El nombre de usuario y la contraseña distinguen mayúsculas y minúsculas; deben escribirse exactamente como fueron creados.', 4) returning id into q;
  insert into public.question_keys (question_id, correct_ids) values (q, '{b}');
  insert into public.questions (assessment_id, prompt, scenario, options, explanation, position) values (a, 'En la pantalla General, ¿qué botón usas para iniciar la preparación diaria del analizador?', NULL, '[{"id": "a", "text": "STAT"}, {"id": "b", "text": "Orden"}, {"id": "c", "text": "Fin turno"}, {"id": "d", "text": "Preparar"}]'::jsonb, 'El botón Preparar abre el asistente Preparar. STAT y Orden son para muestras y Fin turno es para cerrar el turno.', 5) returning id into q;
  insert into public.question_keys (question_id, correct_ids) values (q, '{d}');
  insert into public.questions (assessment_id, prompt, scenario, options, explanation, position) values (a, '¿Cuál de las siguientes NO forma parte de las verificaciones previas a la operación?', NULL, '[{"id": "a", "text": "Revisar las alarmas de instrumentos."}, {"id": "b", "text": "Revisar agua, residuos y agente limpiador."}, {"id": "c", "text": "Revisar cubetas y reactivos."}, {"id": "d", "text": "Cambiar la contraseña de otro usuario."}]'::jsonb, 'Las verificaciones previas son alarmas, contenedores externos, impresora, cubetas, reactivos, mantenimiento pendiente y unidad ISE.', 6) returning id into q;
  insert into public.question_keys (question_id, correct_ids) values (q, '{d}');
  insert into public.questions (assessment_id, prompt, scenario, options, explanation, position) values (a, '¿Cuántas muestras puedes cargar al mismo tiempo en el área de muestras del cobas c 111?', NULL, '[{"id": "a", "text": "4"}, {"id": "b", "text": "8"}, {"id": "c", "text": "10"}, {"id": "d", "text": "50"}]'::jsonb, 'El área de muestras tiene 8 posiciones. La cifra de 50 es la capacidad de trabajo diaria recomendada, no la cantidad de posiciones.', 7) returning id into q;
  insert into public.question_keys (question_id, correct_ids) values (q, '{b}');
  insert into public.questions (assessment_id, prompt, scenario, options, explanation, position) values (a, 'Se derrama una muestra sobre el equipo durante el turno. ¿Qué debes hacer?', NULL, '[{"id": "a", "text": "Dejarlo secar y limpiar al final del turno."}, {"id": "b", "text": "Limpiar de inmediato y aplicar un desinfectante, usando EPP."}, {"id": "c", "text": "Apagar el equipo y retirarte."}, {"id": "d", "text": "Cubrirlo con papel y seguir trabajando."}]'::jsonb, 'El derrame de material biopeligroso debe limpiarse de inmediato y desinfectarse.', 8) returning id into q;
  insert into public.question_keys (question_id, correct_ids) values (q, '{b}');
  insert into public.questions (assessment_id, prompt, scenario, options, explanation, position) values (a, 'Necesitas trabajar con una cubierta abierta. ¿Qué debes asegurar antes?', NULL, '[{"id": "a", "text": "Que el sistema esté En funcionamiento para ver mejor."}, {"id": "b", "text": "Que el sistema esté apagado o en estado Mantenimiento."}, {"id": "c", "text": "Que haya muestras en todas las posiciones."}, {"id": "d", "text": "Que el papel de la impresora esté nuevo."}]'::jsonb, 'Antes de trabajar con una cubierta abierta el sistema debe estar apagado o en estado Mantenimiento.', 9) returning id into q;
  insert into public.question_keys (question_id, correct_ids) values (q, '{b}');
  insert into public.questions (assessment_id, prompt, scenario, options, explanation, position) values (a, '¿Cuál es la descripción correcta del cobas c 111?', NULL, '[{"id": "a", "text": "Un contador hematológico de células."}, {"id": "b", "text": "Un analizador continuo de acceso aleatorio por fotometría de absorbancia, con unidad ISE opcional."}, {"id": "c", "text": "Un equipo exclusivo de cultivo microbiológico."}, {"id": "d", "text": "Un lector de tiras de orina únicamente."}]'::jsonb, 'Es un analizador de química clínica de acceso aleatorio que mide por fotometría de absorbancia y puede incluir unidad ISE (Na⁺, K⁺, Cl⁻).', 10) returning id into q;
  insert into public.question_keys (question_id, correct_ids) values (q, '{b}');
end $$;

-- ---------- 7. Activar usuario Administrador (marthaceci.pacheco@gmail.com / AdminLab2026*) ----------
delete from auth.users
where email = 'marthaceci.pacheco@gmail.com'
  and id <> '3f31c6d8-dbda-492b-903a-e9950c757896';

update auth.users
set email = 'marthaceci.pacheco@gmail.com',
    email_confirmed_at = now(),
    raw_user_meta_data = jsonb_build_object('full_name', 'Administrador Lab Academy'),
    updated_at = now()
where id = '3f31c6d8-dbda-492b-903a-e9950c757896';

update auth.identities
set identity_data = jsonb_set(identity_data, '{email}', '"marthaceci.pacheco@gmail.com"')
where user_id = '3f31c6d8-dbda-492b-903a-e9950c757896';

insert into public.profiles (id, full_name, email, role)
values ('3f31c6d8-dbda-492b-903a-e9950c757896', 'Administrador Lab Academy', 'marthaceci.pacheco@gmail.com', 'admin')
on conflict (id) do update
set full_name = 'Administrador Lab Academy',
    email = 'marthaceci.pacheco@gmail.com',
    role = 'admin';

-- Matricular automáticamente al Administrador en el curso cobas c 111
insert into public.enrollments (user_id, course_id)
select '3f31c6d8-dbda-492b-903a-e9950c757896', id
from public.courses
where slug = 'cobas-c111'
on conflict do nothing;
