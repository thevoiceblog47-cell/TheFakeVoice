/* Owns the lobby-to-season handoff. Loads after the game script. */
let lobbyWatchTimer = null;
let roomStartInFlight = false;

function enterStartedRoom(state) {
  if (!state?.roomStarted) return false;
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
  const allReady = roomMembers.length > 0 && roomMembers.every(member => member.ready && member.name);
  if (!allReady || roomHost !== clientId || roomStartInFlight) return;
  roomStartInFlight = true;
  try {
    await rosterReady;
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
    toast('The room could not start. Please try again.');
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
    console.warn(error);
  }
}

const initialStableLobby = renderStableLobby;
renderStableLobby = function renderStableLobbyWithStartHandler() {
  initialStableLobby();
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
