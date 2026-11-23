-- Painel de Cobrança / Pós-venda: acesso aos comprovantes do dia (1ª a 6ª parcela) para posvenda@grconsorcio.com.br (Larissa),
-- além de admin e coordenador, com atualização em tempo real no CRM antigo.
-- Migração ADITIVA e idempotente.

-- 1) Novo recurso de acesso extra ('comprovantes_cobranca') + concessão automática para posvenda@grconsorcio.com.br
alter table public.crm_acessos_extra drop constraint if exists crm_acessos_extra_recurso_check;
alter table public.crm_acessos_extra add constraint crm_acessos_extra_recurso_check
  check (recurso = any (array['campanhas','termo','conferir_documentacao','aprovar_posvenda','comprovantes_cobranca']));

insert into public.crm_acessos_extra (user_id, recurso)
select u.user_id, 'comprovantes_cobranca'
from public.crm_users u
where lower(btrim(u.email)) = 'posvenda@grconsorcio.com.br'
on conflict do nothing;

-- 2) Função auxiliar de permissão para cobrança/pós-venda (sem depender de alterar o role do usuário)
create or replace function public.crm_pode_ver_comprovantes_cobranca()
returns boolean language sql stable security definer set search_path to 'public' as $$
  select coalesce(crm_pode_aprovar_venda(), false)
      or exists (
        select 1 from crm_acessos_extra
        where user_id = auth.uid() and recurso = 'comprovantes_cobranca'
      )
      or exists (
        select 1 from crm_users
        where user_id = auth.uid()
          and (lower(btrim(email)) = 'posvenda@grconsorcio.com.br' or lower(btrim(role)) = 'posvenda')
      );
$$;

-- 3) Policies aditivas de leitura/conferência para cobrança (comprovantes 2ª–6ª, documentos 1ª parcela, vendas/leads e storage)
drop policy if exists crm_venda_comprovantes_cobranca_select on public.crm_venda_comprovantes;
create policy crm_venda_comprovantes_cobranca_select on public.crm_venda_comprovantes for select to authenticated
  using ( (select crm_pode_ver_comprovantes_cobranca()) );

drop policy if exists crm_venda_comprovantes_cobranca_update on public.crm_venda_comprovantes;
create policy crm_venda_comprovantes_cobranca_update on public.crm_venda_comprovantes for update to authenticated
  using ( (select crm_pode_ver_comprovantes_cobranca()) )
  with check ( (select crm_pode_ver_comprovantes_cobranca()) );

drop policy if exists crm_vendas_cobranca_select on public.crm_vendas;
create policy crm_vendas_cobranca_select on public.crm_vendas for select to authenticated
  using ( (select crm_pode_ver_comprovantes_cobranca()) );

drop policy if exists crm_leads_cobranca_select on public.crm_leads;
create policy crm_leads_cobranca_select on public.crm_leads for select to authenticated
  using ( (select crm_pode_ver_comprovantes_cobranca()) );

drop policy if exists crm_documentos_cobranca_select on public.crm_documentos;
create policy crm_documentos_cobranca_select on public.crm_documentos for select to authenticated
  using ( (select crm_pode_ver_comprovantes_cobranca()) );

drop policy if exists "comprovantes cobranca read" on storage.objects;
create policy "comprovantes cobranca read" on storage.objects for select to authenticated
  using ( bucket_id in ('crm-comprovantes', 'crm-documentos') and (select crm_pode_ver_comprovantes_cobranca()) );

-- 4) Índices para filtro rápido por data de envio (hoje / período)
create index if not exists crm_venda_comprovantes_enviado_em_idx on public.crm_venda_comprovantes (enviado_em desc);
create index if not exists crm_documentos_created_at_idx on public.crm_documentos (created_at desc);

-- 5) Publicação no Realtime para aparecer na hora para a cobrança quando o vendedor anexar
do $$ begin
  alter publication supabase_realtime add table public.crm_venda_comprovantes;
exception when duplicate_object or undefined_object then null;
end $$;

do $$ begin
  alter publication supabase_realtime add table public.crm_documentos;
exception when duplicate_object or undefined_object then null;
end $$;
