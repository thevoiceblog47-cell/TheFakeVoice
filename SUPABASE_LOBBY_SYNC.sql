-- Run this once in the Supabase SQL Editor.
-- It makes lobby updates atomic: two coaches can become ready at the same time
-- without either browser overwriting the other coach's room state.

create or replace function public.update_room_member(
  p_room text,
  p_member_id text,
  p_name text default null,
  p_ready boolean default null
)
returns table(state jsonb, updated_at timestamptz)
language plpgsql
security definer
set search_path = public
as $$
declare
  current_state jsonb;
  updated_members jsonb;
begin
  select game_rooms.state
  into current_state
  from public.game_rooms
  where game_rooms.code = p_room
  for update;

  if current_state is null then
    raise exception 'Room % does not exist', p_room;
  end if;

  select coalesce(
    jsonb_agg(
      case
        when member ->> 'id' = p_member_id then
          member || jsonb_strip_nulls(jsonb_build_object('name', p_name, 'ready', p_ready))
        else member
      end
    ),
    '[]'::jsonb
  )
  into updated_members
  from jsonb_array_elements(coalesce(current_state -> 'roomMembers', '[]'::jsonb)) as members(member);

  update public.game_rooms as room
  set
    state = jsonb_set(current_state, '{roomMembers}', updated_members, true),
    updated_at = clock_timestamp()
  where room.code = p_room
  returning room.state, room.updated_at into state, updated_at;

  return next;
end;
$$;

grant execute on function public.update_room_member(text, text, text, boolean) to anon;
