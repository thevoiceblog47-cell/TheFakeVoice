/* Owns the lobby-to-season handoff. Loads after the game script. */
let lobbyWatchTimer = null;
let roomStartInFlight = false;

async function saveLobbyMember(changes) {
  const response = await fetch(`${SUPABASE_URL}/rest/v1/rpc/update_room_member`, {
    method: 'POST',
    headers: roomHeaders(),
    body: JSON.stringify({
      p_room: roomCode,
      p_member_id: clientId,
      p_name: changes.name ?? null,
      p_ready: changes.ready ?? null
    })
  });

  if (!response.ok) {
    throw new Error('The lobby sync service is unavailable. Run SUPABASE_LOBBY_SYNC.sql in Supabase, then refresh the game.');
  }

  const [room] = await response.json();
  roomLastUpdate = room.updated_at;
  hydrateRoom(room.state);
}

function enterStartedRoom(state) {
  if (!state?.roomStarted) return false;
  if (!Array.isArray(state.artists) || state.artists.length < 48 || (state.blindRound && !state.blindRound.artist?.id)) {
    throw new Error('This room has an incomplete season state. Create a fresh room after both browsers have the latest version.');
  }
  hydrateRoom(state);
  $('#roomLobby').classList.add('hidden');
  $('#startScreen').classList.add('hidden');
  $('#app').hidden = false;
  $('#chatToggle').classList.remove('hidden');
  activateChatSidebar();
  setRoomStatus(`Team ${coaches[localSeat]} · live`);
  if (lobbyWatchTimer !== null) {
    clearInterval(lobbyWatchTimer);
    lobbyWatchTimer = null;
  }
  return true;
}

async function startOnlineSeason() {
  if (roomHost !== clientId || roomStartInFlight) return;
  roomStartInFlight = true;
  try {
    const latestRoom = await fetchRoom(roomCode);
    roomLastUpdate = latestRoom.updated_at;
    if (latestRoom.state?.roomStarted === true) {
      enterStartedRoom(latestRoom.state);
      return;
    }

    hydrateRoom(latestRoom.state);
    const allReady = roomMembers.length > 0 && roomMembers.every(member => member.ready && member.name);
    if (!allReady) {
      const waiting = roomMembers.filter(member => !member.ready || !member.name).map(member => member.name || `Coach ${member.seat + 1}`);
      toast(`Waiting for ${waiting.join(', ')} to get ready.`);
      return;
    }

    await rosterReady;
    if (contestantRoster.length < 48) {
      throw new Error('The contestant roster did not load, so the season was not started. Refresh and try again.');
    }
    roomStarted = true;
    playerCount = roomMembers.length;
    const defaults = ['Lena', 'Marcus', 'Ivy', 'Nova'];
    coaches = Array.from({ length: 4 }, (_, seat) => roomMembers.find(member => member.seat === seat)?.name || defaults[seat]);
    coachName = coaches[0];
    cpuCoachNames = coaches.slice(1);
    roomSeats = Array(4).fill(null);
    roomMembers.forEach(member => { roomSeats[member.seat] = member.id; });
    resetGame();
    await saveRoom();
    const confirmation = await fetchRoom(roomCode);
    if (!enterStartedRoom(confirmation.state)) {
      roomStarted = false;
      renderStableLobby();
      toast('The room did not start. Please try again.');
      return;
    }
    roomLastUpdate = confirmation.updated_at;
  } catch (error) {
    roomStarted = false;
    renderStableLobby();
    toast(error.message || 'The room could not start. Please try again.');
    console.warn(error);
  } finally {
    roomStartInFlight = false;
  }
}

async function watchLobbyStart() {
  if (!roomCode || roomStarted) return;
  try {
    const row = await fetchRoom(roomCode);
    if (row.state?.roomStarted === true) {
      roomLastUpdate = row.updated_at;
      enterStartedRoom(row.state);
    } else {
      roomLastUpdate = row.updated_at;
    }
  } catch (error) {
    toast(error.message || 'Could not enter the started room.');
    console.warn(error);
  }
}

const initialStableLobby = renderStableLobby;
renderStableLobby = function renderStableLobbyWithStartHandler() {
  initialStableLobby();
  const me = roomMembers.find(member => member.id === clientId);
  $('#lobbySaveName').onclick = async () => {
    if (!me) return;
    try {
      await saveLobbyMember({ name: cleanCoachName($('#lobbyName').value, me.seat), ready: false });
      renderStableLobby();
    } catch (error) {
      toast('Could not save your lobby details.');
      console.warn(error);
    }
  };
  $('#lobbyReady').onclick = async () => {
    if (!me?.name) return;
    try {
      await saveLobbyMember({ ready: true });
      renderStableLobby();
    } catch (error) {
      toast('Could not mark you ready.');
      console.warn(error);
    }
  };
  $('#lobbyStart').onclick = startOnlineSeason;
  if (lobbyWatchTimer === null) lobbyWatchTimer = setInterval(watchLobbyStart, 700);
};
showRoomLobby = renderStableLobby;

const directLobbyHydrate = hydrateRoom;
hydrateRoom = function hydrateStartedLobbyRoom(state) {
  directLobbyHydrate(state);
  if (state.roomStarted === true) {
    $('#roomLobby').classList.add('hidden');
    $('#startScreen').classList.add('hidden');
    $('#app').hidden = false;
    if (lobbyWatchTimer !== null) {
      clearInterval(lobbyWatchTimer);
      lobbyWatchTimer = null;
    }
  }
};

const renderStoredBlindRound = renderBlindFromRoom;
renderBlindFromRoom = function renderSafeStoredBlindRound() {
  if (!blindRound?.artist) {
    $('#blindDecision').classList.remove('hidden');
    $('#turnResult').classList.add('hidden');
    $('#blindDecision').innerHTML = '<p class="eyebrow">Room recovery needed</p><h2>This room has incomplete audition data.</h2><p class="copy">Ask the host to create a new room after refreshing the game.</p>';
    return;
  }
  renderStoredBlindRound();
};
