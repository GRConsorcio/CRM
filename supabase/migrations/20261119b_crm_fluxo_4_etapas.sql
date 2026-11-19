-- Fluxo final: Venda registrada -> Conferência de documentação (ok) -> Pós-venda (ok manual) -> Venda concluída.
-- Aprovar a documentação passa a gravar só a etapa 'documentacao'; o ok do pós-venda grava 'posvenda' (botão na venda).
-- Pagamento e alocação saem da trilha. Desaprovar a venda apaga todas as etapas.
-- Vendas já aprovadas antes desta mudança continuam concluídas (não foram reabertas).
create or replace function public.crm_vendas_sincroniza_etapa_doc()
returns trigger language plpgsql security definer set search_path to 'public' as $$
begin
  if new.status_venda = 'Aprovado' and (tg_op = 'INSERT' or old.status_venda is distinct from 'Aprovado') then
    insert into crm_venda_etapas (venda_id, etapa, concluida_por)
    values (new.id, 'documentacao', auth.uid())
    on conflict (venda_id, etapa) do update set concluida_em = now(), concluida_por = excluded.concluida_por;
  elsif tg_op = 'UPDATE' and old.status_venda = 'Aprovado' and new.status_venda is distinct from 'Aprovado' then
    delete from crm_venda_etapas where venda_id = new.id;
  end if;
  return null;
end $$;
