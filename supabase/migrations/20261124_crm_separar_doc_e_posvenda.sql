-- Separa a Conferência de Documentação (Deivid) da Aprovação/Reprovação da Venda pelo Pós-venda (Lorrane).
-- Fluxo:
--   1) Venda nasce Pendente (etapa 1: Venda Registrada).
--   2) Deivid ('conferir_documentacao') aprova só a documentação → grava etapa 'documentacao' em crm_venda_etapas,
--      mantendo crm_vendas.status_venda = 'Pendente' (para não aparecer como Aprovada antes do pós-venda).
--      Se a documentação for inválida, Deivid também pode reprovar ('Cancelado').
--   3) Lorrane ('aprovar_posvenda') atende no pós-venda (só após 'documentacao' OK) e aprova ou reprova a venda:
--      - Aprovar venda → grava etapa 'posvenda' e atualiza crm_vendas.status_venda = 'Aprovado'.
--      - Reprovar venda → atualiza crm_vendas.status_venda = 'Cancelado'.
-- Migração ADITIVA e idempotente.

create or replace function public.crm_venda_tem_doc_conferida(p_venda uuid)
returns boolean language sql stable security definer set search_path to 'public' as $$
  select exists (
    select 1 from public.crm_venda_etapas
    where venda_id = p_venda and etapa = 'documentacao'
  );
$$;

-- 1) Policy de escrita em crm_venda_etapas:
--    - 'documentacao': somente quem tem 'conferir_documentacao' (Deivid / Thiago).
--    - 'posvenda': somente quem tem 'aprovar_posvenda' (Lorrane / Thiago), exigindo 'documentacao' já conferida
--      (sem exigir status_venda = 'Aprovado' antes).
drop policy if exists crm_venda_etapas_write on public.crm_venda_etapas;
create policy crm_venda_etapas_write on public.crm_venda_etapas for all to authenticated
  using (
    (etapa = 'documentacao' and (select crm_tem_acesso_estrito('conferir_documentacao')))
    or (etapa = 'posvenda' and (select crm_tem_acesso_estrito('aprovar_posvenda')))
  )
  with check (
    (etapa = 'documentacao' and (select crm_tem_acesso_estrito('conferir_documentacao')))
    or (
      etapa = 'posvenda'
      and (select crm_tem_acesso_estrito('aprovar_posvenda'))
      and (select crm_venda_tem_doc_conferida(venda_id))
    )
  );

-- 2) Guarda de alteração de status_venda em crm_vendas:
--    - Somente 'aprovar_posvenda' pode marcar status_venda = 'Aprovado' (exigindo documentação conferida).
--    - 'conferir_documentacao' OU 'aprovar_posvenda' pode marcar 'Cancelado' ou reabrir para 'Pendente'.
--    - Vendedor comum não consegue aprovar, reprovar nem reabrir pela API.
create or replace function public.crm_vendas_guarda_aprovacao()
returns trigger language plpgsql security definer set search_path to 'public' as $$
begin
  if auth.uid() is null then return new; end if;

  if new.status_venda = 'Aprovado' and (tg_op = 'INSERT' or old.status_venda is distinct from 'Aprovado') then
    if not crm_tem_acesso_estrito('aprovar_posvenda') then
      raise exception 'Somente o pós-venda pode aprovar a venda após a conferência de documentação.';
    end if;
    if tg_op = 'INSERT' or not crm_venda_tem_doc_conferida(new.id) then
      raise exception 'Confira e aprove a documentação antes de aprovar a venda no pós-venda.';
    end if;
  elsif tg_op = 'INSERT' then
    if new.status_venda = 'Cancelado'
       and not (crm_tem_acesso_estrito('conferir_documentacao') or crm_tem_acesso_estrito('aprovar_posvenda')) then
      raise exception 'Somente conferência de documentação ou pós-venda pode reprovar uma venda.';
    end if;
  elsif old.status_venda is distinct from new.status_venda
        and (new.status_venda in ('Aprovado','Cancelado') or old.status_venda in ('Aprovado','Cancelado'))
        and not (crm_tem_acesso_estrito('conferir_documentacao') or crm_tem_acesso_estrito('aprovar_posvenda')) then
    raise exception 'Somente conferência de documentação ou pós-venda pode alterar ou reabrir o status da venda.';
  end if;

  return new;
end $$;

-- 3) Sincronização de etapas ao aprovar/reprovar status_venda:
--    - Ao virar 'Aprovado' (pelo pós-venda): garante 'documentacao' e 'posvenda' gravadas.
--    - Ao sair de 'Aprovado': remove 'posvenda' (mantendo 'documentacao' intacta, a menos que seja desfeita).
create or replace function public.crm_vendas_sincroniza_etapa_doc()
returns trigger language plpgsql security definer set search_path to 'public' as $$
begin
  if new.status_venda = 'Aprovado' and (tg_op = 'INSERT' or old.status_venda is distinct from 'Aprovado') then
    insert into crm_venda_etapas (venda_id, etapa, concluida_por)
    select new.id, e, auth.uid() from unnest(array['documentacao','posvenda']) e
    on conflict (venda_id, etapa) do nothing;
  elsif tg_op = 'UPDATE' and old.status_venda = 'Aprovado' and new.status_venda is distinct from 'Aprovado' then
    delete from crm_venda_etapas where venda_id = new.id and etapa = 'posvenda';
  end if;
  return null;
end $$;
