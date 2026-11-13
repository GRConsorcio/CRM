-- GR CRM: comprovantes de parcela, etapas da venda, central de campanhas com aceite.
-- Migração ADITIVA: só cria objetos novos e adiciona colunas anuláveis; não altera nem remove dados existentes.

-- ───────────────────────── helpers ─────────────────────────
create or replace function public.crm_venda_visivel(p_venda uuid)
returns boolean language sql stable security definer set search_path to 'public' as $$
  select exists (
    select 1 from crm_vendas v
    where v.id = p_venda
      and ( (select crm_lead_visivel(v.lead_id)) or v.vendedor_id = (select auth.uid()) )
  );
$$;

create or replace function public.crm_pode_aprovar_venda()
returns boolean language sql stable security definer set search_path to 'public' as $$
  select coalesce(crm_current_role() in ('admin','coordenador'), false);
$$;

-- ───────────────────────── etapas da venda ─────────────────────────
-- Etapa 1 (Venda Registrada) é o próprio crm_vendas.created_at; as outras ficam aqui.
create table if not exists public.crm_venda_etapas (
  id uuid primary key default gen_random_uuid(),
  venda_id uuid not null references public.crm_vendas(id) on delete cascade,
  etapa text not null check (etapa in ('documentacao','pagamento','posvenda','alocacao')),
  concluida_em timestamptz not null default now(),
  concluida_por uuid,
  observacao text,
  unique (venda_id, etapa)
);
alter table public.crm_venda_etapas enable row level security;
drop policy if exists crm_venda_etapas_select on public.crm_venda_etapas;
create policy crm_venda_etapas_select on public.crm_venda_etapas for select to authenticated
  using ( (select crm_venda_visivel(venda_id)) );
drop policy if exists crm_venda_etapas_write on public.crm_venda_etapas;
create policy crm_venda_etapas_write on public.crm_venda_etapas for all to authenticated
  using ( (select crm_pode_aprovar_venda()) ) with check ( (select crm_pode_aprovar_venda()) );

-- Só admin e coordenador (pós-venda) levam a venda a Aprovado; vendedor não consegue pela API.
create or replace function public.crm_vendas_guarda_aprovacao()
returns trigger language plpgsql security definer set search_path to 'public' as $$
begin
  if new.status_venda = 'Aprovado'
     and (tg_op = 'INSERT' or old.status_venda is distinct from 'Aprovado')
     and auth.uid() is not null
     and not crm_pode_aprovar_venda() then
    raise exception 'Somente o pós-venda/administração pode aprovar uma venda (confira a documentação primeiro).';
  end if;
  return new;
end $$;
drop trigger if exists trg_crm_vendas_guarda_aprovacao on public.crm_vendas;
create trigger trg_crm_vendas_guarda_aprovacao before insert or update of status_venda on public.crm_vendas
  for each row execute function public.crm_vendas_guarda_aprovacao();

-- Aprovar = documentação conferida; sair de Aprovado desfaz a conferência.
create or replace function public.crm_vendas_sincroniza_etapa_doc()
returns trigger language plpgsql security definer set search_path to 'public' as $$
begin
  if new.status_venda = 'Aprovado' and (tg_op = 'INSERT' or old.status_venda is distinct from 'Aprovado') then
    insert into crm_venda_etapas (venda_id, etapa, concluida_por)
    values (new.id, 'documentacao', auth.uid())
    on conflict (venda_id, etapa) do update set concluida_em = now(), concluida_por = excluded.concluida_por;
  elsif tg_op = 'UPDATE' and old.status_venda = 'Aprovado' and new.status_venda is distinct from 'Aprovado' then
    delete from crm_venda_etapas where venda_id = new.id and etapa = 'documentacao';
  end if;
  return null;
end $$;
drop trigger if exists trg_crm_vendas_sincroniza_etapa_doc on public.crm_vendas;
create trigger trg_crm_vendas_sincroniza_etapa_doc after insert or update of status_venda on public.crm_vendas
  for each row execute function public.crm_vendas_sincroniza_etapa_doc();

-- Vendas já aprovadas antes deste recurso: marca a documentação como conferida (data original da venda).
insert into public.crm_venda_etapas (venda_id, etapa, concluida_em)
select id, 'documentacao', created_at from public.crm_vendas where status_venda = 'Aprovado'
on conflict (venda_id, etapa) do nothing;

-- ───────────────────────── comprovantes de parcela ─────────────────────────
create table if not exists public.crm_venda_comprovantes (
  id uuid primary key default gen_random_uuid(),
  venda_id uuid not null references public.crm_vendas(id) on delete cascade,
  lead_id uuid,
  numero_parcela smallint not null check (numero_parcela between 2 and 6),
  tipo text not null default 'comprovante' check (tipo in ('comprovante','inadimplencia')),
  storage_path text,
  nome_arquivo text,
  mime text,
  tamanho bigint,
  observacao text,
  status text not null default 'pendente' check (status in ('pendente','aprovado','recusado')),
  motivo_recusa text,
  enviado_por uuid not null default auth.uid(),
  enviado_em timestamptz not null default now(),
  conferido_por uuid,
  conferido_em timestamptz,
  check (tipo = 'inadimplencia' or storage_path is not null)
);
create index if not exists crm_venda_comprovantes_venda_idx on public.crm_venda_comprovantes (venda_id, numero_parcela);
create index if not exists crm_venda_comprovantes_status_idx on public.crm_venda_comprovantes (status, enviado_em desc);
alter table public.crm_venda_comprovantes enable row level security;
drop policy if exists crm_venda_comprovantes_select on public.crm_venda_comprovantes;
create policy crm_venda_comprovantes_select on public.crm_venda_comprovantes for select to authenticated
  using ( (select crm_venda_visivel(venda_id)) );
drop policy if exists crm_venda_comprovantes_insert on public.crm_venda_comprovantes;
create policy crm_venda_comprovantes_insert on public.crm_venda_comprovantes for insert to authenticated
  with check ( enviado_por = (select auth.uid()) and (select crm_venda_visivel(venda_id)) and status = 'pendente' );
drop policy if exists crm_venda_comprovantes_update on public.crm_venda_comprovantes;
create policy crm_venda_comprovantes_update on public.crm_venda_comprovantes for update to authenticated
  using ( (select crm_pode_aprovar_venda()) ) with check ( (select crm_pode_aprovar_venda()) );
drop policy if exists crm_venda_comprovantes_delete on public.crm_venda_comprovantes;
create policy crm_venda_comprovantes_delete on public.crm_venda_comprovantes for delete to authenticated
  using ( (select crm_pode_aprovar_venda()) or (enviado_por = (select auth.uid()) and status = 'pendente') );

-- Bucket privado só para comprovantes (caminho: <venda_id>/<arquivo>)
insert into storage.buckets (id, name, public) values ('crm-comprovantes', 'crm-comprovantes', false)
on conflict (id) do nothing;
drop policy if exists "comprovantes read" on storage.objects;
create policy "comprovantes read" on storage.objects for select to authenticated
  using ( bucket_id = 'crm-comprovantes' and (select crm_venda_visivel(nullif(split_part(name,'/',1),'')::uuid)) );
drop policy if exists "comprovantes upload" on storage.objects;
create policy "comprovantes upload" on storage.objects for insert to authenticated
  with check ( bucket_id = 'crm-comprovantes' and (select crm_venda_visivel(nullif(split_part(name,'/',1),'')::uuid)) );
drop policy if exists "comprovantes delete" on storage.objects;
create policy "comprovantes delete" on storage.objects for delete to authenticated
  using ( bucket_id = 'crm-comprovantes' and ( (select crm_pode_aprovar_venda()) or owner = (select auth.uid()) ) );

-- ───────────────────────── central de campanhas ─────────────────────────
alter table public.crm_campanhas
  add column if not exists subtitulo text,
  add column if not exists inicio date,
  add column if not exists premiacao text,
  add column if not exists regulamento text,
  add column if not exists exige_aceite boolean not null default false,
  add column if not exists versao_regulamento integer not null default 1,
  add column if not exists banner_path text,
  add column if not exists meta_cotas integer,
  add column if not exists meta_credito numeric;

-- Mudou o texto do regulamento? Nova versão: quem já aceitou precisa aceitar de novo.
create or replace function public.crm_campanhas_versiona_regulamento()
returns trigger language plpgsql as $$
begin
  if new.regulamento is distinct from old.regulamento
     or new.premiacao is distinct from old.premiacao
     or new.titulo is distinct from old.titulo then
    new.versao_regulamento := coalesce(old.versao_regulamento,1) + 1;
  end if;
  return new;
end $$;
drop trigger if exists trg_crm_campanhas_versiona on public.crm_campanhas;
create trigger trg_crm_campanhas_versiona before update on public.crm_campanhas
  for each row execute function public.crm_campanhas_versiona_regulamento();

create table if not exists public.crm_campanha_aceites (
  id uuid primary key default gen_random_uuid(),
  campanha_id uuid not null references public.crm_campanhas(id) on delete cascade,
  versao integer not null,
  user_id uuid not null,
  nome text,
  email text,
  decisao text not null check (decisao in ('aceito','recusado')),
  cpf text,
  texto_sha256 text not null,
  ip text,
  user_agent text,
  criado_em timestamptz not null default now(),
  anulado_em timestamptz,
  anulado_por uuid
);
create unique index if not exists crm_campanha_aceites_vigente_uk
  on public.crm_campanha_aceites (campanha_id, versao, user_id) where anulado_em is null;
alter table public.crm_campanha_aceites enable row level security;
drop policy if exists crm_campanha_aceites_select on public.crm_campanha_aceites;
create policy crm_campanha_aceites_select on public.crm_campanha_aceites for select to authenticated
  using ( user_id = (select auth.uid()) or (select crm_is_admin()) or (select crm_is_ceo()) );

create or replace function public.crm_registrar_aceite_campanha(p_campanha_id uuid, p_cpf text, p_decisao text, p_user_agent text default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_uid uuid := auth.uid(); v_u public.crm_users; v_c public.crm_campanhas; v_hdr jsonb; v_ip text; v_cpf text; v_ok boolean;
begin
  if v_uid is null then raise exception 'não autenticado'; end if;
  select * into v_u from crm_users where user_id = v_uid;
  if not found then raise exception 'usuário não encontrado'; end if;
  select * into v_c from crm_campanhas where id = p_campanha_id and ativo;
  if not found then raise exception 'campanha não está mais vigente, recarregue a página'; end if;
  v_ok := v_c.criado_por = v_uid or v_c.alvo = 'todos'
       or (v_c.alvo = 'usuarios' and v_uid = any(v_c.usuarios_alvo))
       or (v_c.alvo = 'equipes' and exists (select 1 from crm_equipe_membros m where m.user_id = v_uid and m.equipe_id = any(v_c.equipes_alvo)));
  if not v_ok then raise exception 'campanha não destinada a este usuário'; end if;
  if p_decisao not in ('aceito','recusado') then raise exception 'decisão inválida'; end if;
  if exists (select 1 from crm_campanha_aceites where campanha_id = v_c.id and versao = v_c.versao_regulamento and user_id = v_uid and anulado_em is null) then
    return jsonb_build_object('ok', true, 'ja_respondido', true);
  end if;
  v_cpf := nullif(regexp_replace(coalesce(p_cpf,''),'\D','','g'),'');
  if p_decisao = 'aceito' and not crm_cpf_valido(v_cpf) then raise exception 'CPF inválido'; end if;
  if p_decisao = 'recusado' and v_cpf is not null and not crm_cpf_valido(v_cpf) then v_cpf := null; end if;
  v_hdr := coalesce(nullif(current_setting('request.headers', true),'')::jsonb, '{}'::jsonb);
  v_ip := nullif(trim(split_part(coalesce(v_hdr->>'x-forwarded-for', v_hdr->>'cf-connecting-ip', ''), ',', 1)), '');
  insert into crm_campanha_aceites (campanha_id, versao, user_id, nome, email, decisao, cpf, texto_sha256, ip, user_agent)
  values (v_c.id, v_c.versao_regulamento, v_uid, v_u.name, v_u.email, p_decisao, v_cpf,
          encode(sha256(convert_to(v_c.titulo || E'\n' || coalesce(v_c.premiacao,'') || E'\n' || coalesce(v_c.regulamento,''), 'UTF8')), 'hex'),
          v_ip, left(p_user_agent, 400));
  return jsonb_build_object('ok', true, 'decisao', p_decisao);
end $$;
revoke all on function public.crm_registrar_aceite_campanha(uuid,text,text,text) from public, anon;
grant execute on function public.crm_registrar_aceite_campanha(uuid,text,text,text) to authenticated;

create or replace function public.crm_anular_aceite_campanha(p_id uuid)
returns void language plpgsql security definer set search_path to 'public' as $$
begin
  if not crm_is_admin() then raise exception 'somente administrador'; end if;
  update crm_campanha_aceites set anulado_em = now(), anulado_por = auth.uid() where id = p_id and anulado_em is null;
end $$;
revoke all on function public.crm_anular_aceite_campanha(uuid) from public, anon;
grant execute on function public.crm_anular_aceite_campanha(uuid) to authenticated;
