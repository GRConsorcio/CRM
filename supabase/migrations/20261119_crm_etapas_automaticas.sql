-- Aprovação do pós-venda leva a trilha da venda até 100% (documentação, pagamento, pós-venda, alocação).
-- Antes só a documentação andava sozinha; as outras 3 etapas dependiam de clique manual e as vendas nunca "concluíam"
-- (comissão só para vendas 100% concluídas). Desaprovar volta tudo. Admin/coordenador ainda podem desfazer etapa a etapa.
create or replace function public.crm_vendas_sincroniza_etapa_doc()
returns trigger language plpgsql security definer set search_path to 'public' as $$
begin
  if new.status_venda = 'Aprovado' and (tg_op = 'INSERT' or old.status_venda is distinct from 'Aprovado') then
    insert into crm_venda_etapas (venda_id, etapa, concluida_por)
    select new.id, e, auth.uid() from unnest(array['documentacao','pagamento','posvenda','alocacao']) e
    on conflict (venda_id, etapa) do nothing;
  elsif tg_op = 'UPDATE' and old.status_venda = 'Aprovado' and new.status_venda is distinct from 'Aprovado' then
    delete from crm_venda_etapas where venda_id = new.id;
  end if;
  return null;
end $$;

-- Vendas já aprovadas: completa as etapas que faltavam.
insert into public.crm_venda_etapas (venda_id, etapa, concluida_em)
select v.id, e, now() from public.crm_vendas v, unnest(array['documentacao','pagamento','posvenda','alocacao']) e
where v.status_venda = 'Aprovado'
on conflict (venda_id, etapa) do nothing;
