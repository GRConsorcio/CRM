-- Conferência de documentação: SÓ o login do Deivid (admin 8499c7b5...). Ok do pós-venda: SÓ o login da Lorraine (05d17aef...).
-- (Thiago, admin, tambem tem os dois acessos.) Sem bypass de admin. Não dá para pular etapa: o ok do pós-venda exige documentação conferida e venda Aprovada.
alter table public.crm_acessos_extra drop constraint if exists crm_acessos_extra_recurso_check;
alter table public.crm_acessos_extra add constraint crm_acessos_extra_recurso_check
  check (recurso = any (array['campanhas','termo','conferir_documentacao','aprovar_posvenda']));

insert into public.crm_acessos_extra (user_id, recurso) values
  ('8499c7b5-8e70-4fb8-8a36-ce7aa29aede6','conferir_documentacao'),
  ('05d17aef-c94c-41ba-b337-378d9081809e','aprovar_posvenda'),
  ('3c6b237c-c777-42df-b4b0-6c0db2a3c866','conferir_documentacao'),
  ('3c6b237c-c777-42df-b4b0-6c0db2a3c866','aprovar_posvenda')
on conflict do nothing;

create or replace function public.crm_tem_acesso_estrito(p_recurso text)
returns boolean language sql stable security definer set search_path to 'public' as $$
  select exists (select 1 from crm_acessos_extra where user_id = auth.uid() and recurso = p_recurso);
$$;

create or replace function public.crm_vendas_guarda_aprovacao()
returns trigger language plpgsql security definer set search_path to 'public' as $$
begin
  if auth.uid() is null then return new; end if;
  if tg_op = 'INSERT' then
    if new.status_venda in ('Aprovado','Cancelado') and not crm_tem_acesso_estrito('conferir_documentacao') then
      raise exception 'Somente o responsavel pela conferencia de documentacao pode aprovar ou reprovar uma venda.';
    end if;
  elsif old.status_venda is distinct from new.status_venda
        and (new.status_venda in ('Aprovado','Cancelado') or old.status_venda in ('Aprovado','Cancelado'))
        and not crm_tem_acesso_estrito('conferir_documentacao') then
    raise exception 'Somente o responsavel pela conferencia de documentacao pode aprovar, reprovar ou reabrir a conferencia de uma venda.';
  end if;
  return new;
end $$;

drop policy if exists crm_venda_etapas_write on public.crm_venda_etapas;
create policy crm_venda_etapas_write on public.crm_venda_etapas for all to authenticated
  using ( etapa = 'posvenda' and (select crm_tem_acesso_estrito('aprovar_posvenda')) )
  with check (
    etapa = 'posvenda'
    and (select crm_tem_acesso_estrito('aprovar_posvenda'))
    and exists (select 1 from crm_vendas v where v.id = venda_id and v.status_venda = 'Aprovado')
    and exists (select 1 from crm_venda_etapas d where d.venda_id = crm_venda_etapas.venda_id and d.etapa = 'documentacao')
  );
