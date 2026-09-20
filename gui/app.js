const $ = (selector) => document.querySelector(selector);
const $$ = (selector) => [...document.querySelectorAll(selector)];

const API_BASE = "/api";
const STATUS_POLL_MS = 2000;

const sidebar = $("#sidebar");
const overlay = $("#overlay");
const openMenu = $("#openMenu");
const closeMenu = $("#closeMenu");

const pageTitle = $("#pageTitle");
const pageSubtitle = $("#pageSubtitle");

const pageNames = {
    home: ["Home", "Server control panel"],
    world: ["World", "Manage your Minecraft worlds"],
    settings: ["Settings", "Configuration for the selected world"],
    console: ["Console", "Advanced server controls"],
    diagnostics: ["Diagnostics", "Server health and troubleshooting"]
};

let selectedWorld = null;
let serverState = "STOPPED";
let startedAt = null;
let runtimeTimer = null;
let statusPollTimer = null;
let consoleStream = null;

/* =========================================================
   API CLIENT
   ========================================================= */

async function apiRequest(path, options = {}) {
    const response = await fetch(`${API_BASE}${path}`, {
        headers: {
            "Content-Type": "application/json",
            ...(options.headers || {})
        },
        ...options
    });

    let payload;

    try {
        payload = await response.json();
    } catch {
        throw new Error(`API returned invalid JSON (${response.status}).`);
    }

    if (!response.ok || payload.ok === false) {
        const message = payload?.error?.message ||
            `API request failed (${response.status}).`;
        throw new Error(message);
    }

    return payload;
}

const api = {
    status: () => apiRequest("/status"),

    worlds: () => apiRequest("/worlds"),

    world: (id) => apiRequest(`/world/${encodeURIComponent(id)}`),

    activate: (id) => apiRequest("/activate", {
        method: "POST",
        body: JSON.stringify({ id })
    }),

    createWorld: (config) => apiRequest("/create-world", {
        method: "POST",
        body: JSON.stringify(config)
    }),

    updateWorld: (id, config) => apiRequest(`/world/${encodeURIComponent(id)}`, {
        method: "PUT",
        body: JSON.stringify(config)
    }),

    start: (id) => apiRequest("/start", {
        method: "POST",
        body: JSON.stringify({ id })
    }),

    stop: () => apiRequest("/stop", {
        method: "POST",
        body: JSON.stringify({})
    }),

    console: (command) => apiRequest("/console", {
        method: "POST",
        body: JSON.stringify({ command })
    }),

    backup: (id) => apiRequest("/backup", {
        method: "POST",
        body: JSON.stringify({ id })
    }),

    backups: () => apiRequest("/backups"),

    restore: (backup) => apiRequest("/restore", {
        method: "POST",
        body: JSON.stringify({ backup })
    }),

    pregenerate: (id, radius) => apiRequest("/pregenerate", {
        method: "POST",
        body: JSON.stringify({ id, radius })
    }),

    deleteWorld: (id) => apiRequest("/delete-world", {
        method: "POST",
        body: JSON.stringify({ id })
    }),

    selfTest: () => apiRequest("/self-test", {
        method: "POST",
        body: JSON.stringify({})
    })
};

async function runApi(action, { onError, log = true } = {}) {
    try {
        return await action();
    } catch (error) {
        if (log) {
            logConsole(`[api] ${error.message}`);
        }

        if (onError) {
            onError(error);
        }

        return null;
    }
}

/* =========================================================
   SIDEBAR
   ========================================================= */

function openSidebar() {
    sidebar.classList.add("open");
    overlay.classList.add("open");
    openMenu?.setAttribute("aria-expanded", "true");
}

function closeSidebar() {
    sidebar.classList.remove("open");
    overlay.classList.remove("open");
    openMenu?.setAttribute("aria-expanded", "false");
}

openMenu?.addEventListener("click", () => {
    if (sidebar.classList.contains("open")) {
        closeSidebar();
    } else {
        openSidebar();
    }
});

closeMenu?.addEventListener("click", closeSidebar);
overlay?.addEventListener("click", closeSidebar);

document.addEventListener("keydown", (event) => {
    if (event.key === "Escape") {
        closeSidebar();

        if (createWorldModal?.classList.contains("open")) {
            closeCreateWorldModal();
        }
    }
});

/* =========================================================
   PAGE NAVIGATION
   ========================================================= */

function showPage(page) {
    $$(".page").forEach((element) => {
        element.classList.remove("active-page");
    });

    const selected = $(`#page-${page}`);

    if (selected) {
        selected.classList.add("active-page");
    }

    $$(".nav-item").forEach((item) => {
        item.classList.toggle("active", item.dataset.page === page);
    });

    if (pageNames[page]) {
        pageTitle.textContent = pageNames[page][0];
        pageSubtitle.textContent = pageNames[page][1];
    }

    closeSidebar();
}

$$('[data-page]').forEach((element) => {
    element.addEventListener("click", () => showPage(element.dataset.page));
});

$$('[data-page-target]').forEach((element) => {
    element.addEventListener("click", () => showPage(element.dataset.pageTarget));
});

/* =========================================================
   SERVER STATE
   ========================================================= */

function setServerState(state, statusData = {}) {
    serverState = state || "STOPPED";

    const running = serverState === "RUNNING";
    const transitional = ["STARTING", "STOPPING"].includes(serverState);

    document.body.dataset.server = running ? "running" : "stopped";

    $("#serverStatusText").textContent = serverState;

    $("#homeStatusText").textContent =
        serverState === "RUNNING"
            ? "Server is running"
            : serverState === "STARTING"
                ? "Server is starting"
                : serverState === "STOPPING"
                    ? "Server is stopping"
                    : "Server is stopped";

    $("#homeStatusSubtext").textContent =
        serverState === "RUNNING"
            ? "The selected world is currently active."
            : serverState === "STARTING"
                ? "Waiting for Minecraft to finish starting."
                : serverState === "STOPPING"
                    ? "Waiting for Minecraft to exit."
                    : "Ready to start the selected world.";

    $("#startButton").disabled = running || transitional;
    $("#stopButton").disabled = !running && serverState !== "STARTING";

    if (running) {
        if (statusData.uptime_seconds != null) {
            startedAt = Date.now() - Number(statusData.uptime_seconds) * 1000;
        } else if (!startedAt) {
            startedAt = Date.now();
        }
    } else if (serverState === "STOPPED") {
        startedAt = null;
        $("#runtime").textContent = "Stopped";
        $("#ramUsage").textContent = "—";
    }

    if (statusData.players) {
        const online = Number(statusData.players.online ?? 0);
        const max = Number(statusData.players.max ?? selectedWorld?.max_players ?? 0);
        $("#playerCount").textContent = `${online} / ${max}`;
    }

    if (statusData.ram) {
        const used = statusData.ram.used_mb;
        const allocated = statusData.ram.allocated_mb;
        $("#ramUsage").textContent =
            used != null && allocated != null
                ? `${used} / ${allocated} MB`
                : "—";
    }

    if (running && !runtimeTimer) {
        runtimeTimer = setInterval(updateRuntime, 1000);
    }

    if (!running && runtimeTimer) {
        clearInterval(runtimeTimer);
        runtimeTimer = null;
    }
}

function updateRuntime() {
    if (serverState !== "RUNNING" || !startedAt) {
        return;
    }

    const total = Math.floor((Date.now() - startedAt) / 1000);
    const hours = Math.floor(total / 3600);
    const minutes = Math.floor((total % 3600) / 60);
    const seconds = total % 60;

    $("#runtime").textContent =
        `${String(hours).padStart(2, "0")}:` +
        `${String(minutes).padStart(2, "0")}:` +
        `${String(seconds).padStart(2, "0")}`;
}

async function refreshStatus() {
    const result = await runApi(() => api.status(), { log: false });

    if (!result) {
        return;
    }

    const data = result.data || {};
    setServerState(data.state, data);

    if (data.active_world?.id && data.active_world.id !== selectedWorld?.id) {
        await loadWorld(data.active_world.id);
    }
}

function startStatusPolling() {
    if (statusPollTimer) {
        return;
    }

    statusPollTimer = setInterval(refreshStatus, STATUS_POLL_MS);
}

/* =========================================================
   WORLD DATA
   ========================================================= */

function normaliseWorld(world) {
    return {
        ...world,
        structures: world.structures ?? world.generate_structures ?? true,
        generate_structures: world.generate_structures ?? world.structures ?? true,
        max_players: Number(world.max_players ?? 0),
        view_distance: Number(world.view_distance ?? 0),
        simulation_distance: Number(world.simulation_distance ?? 0),
        hardcore: Boolean(world.hardcore),
        pvp: Boolean(world.pvp)
    };
}

function renderSelectedWorld() {
    if (!selectedWorld) {
        return;
    }

    const readableGamemode =
        String(selectedWorld.gamemode || "unknown").charAt(0).toUpperCase() +
        String(selectedWorld.gamemode || "unknown").slice(1);

    const readableDifficulty =
        String(selectedWorld.difficulty || "unknown").charAt(0).toUpperCase() +
        String(selectedWorld.difficulty || "unknown").slice(1);

    $("#homeWorldName").textContent = selectedWorld.name;
    $("#homeWorldId").textContent = selectedWorld.id;
    $("#worldActiveName").textContent = selectedWorld.name;
    $("#worldActiveId").textContent = selectedWorld.id;

    $("#detailId").textContent = selectedWorld.id;
    $("#detailName").textContent = selectedWorld.name;
    $("#detailGamemode").textContent = readableGamemode;
    $("#detailDifficulty").textContent = readableDifficulty;
    $("#detailSeed").textContent = selectedWorld.seed ?? "Random";
    $("#detailPlayers").textContent = selectedWorld.max_players;
    $("#detailViewDistance").textContent = selectedWorld.view_distance;
    $("#detailSimulationDistance").textContent = selectedWorld.simulation_distance;
    $("#detailHardcore").textContent = selectedWorld.hardcore ? "Enabled" : "Disabled";
    $("#detailStructures").textContent = selectedWorld.structures ? "Enabled" : "Disabled";
    $("#detailPvp").textContent = selectedWorld.pvp ? "Enabled" : "Disabled";
    $("#detailActive").textContent = "Yes";

    $("#settingsGamemode").value = selectedWorld.gamemode;
    $("#settingsDifficulty").value = selectedWorld.difficulty;
    $("#settingsMaxPlayers").value = selectedWorld.max_players;
    $("#settingsViewDistance").value = selectedWorld.view_distance;
    $("#settingsSimulationDistance").value = selectedWorld.simulation_distance;
    $("#settingsHardcore").checked = selectedWorld.hardcore;
    $("#settingsStructures").checked = selectedWorld.structures;
    $("#settingsPvp").checked = selectedWorld.pvp;

    $("#playerCount").textContent = `0 / ${selectedWorld.max_players}`;
}

async function loadWorld(id) {
    const result = await runApi(() => api.world(id));

    if (!result?.data?.world) {
        return false;
    }

    selectedWorld = normaliseWorld(result.data.world);
    renderSelectedWorld();
    return true;
}

function renderWorldList(worlds) {
    const list = $("#worldList");
    list.replaceChildren();

    for (const rawWorld of worlds) {
        const world = normaliseWorld(rawWorld);
        const entry = document.createElement("button");
        entry.type = "button";
        entry.className = "world-entry" +
            (world.id === selectedWorld?.id ? " active" : "");
        entry.dataset.worldId = world.id;

        const details = document.createElement("div");
        const name = document.createElement("strong");
        const summary = document.createElement("span");
        const status = document.createElement("span");

        name.textContent = world.name;
        summary.textContent =
            `${world.id} · ${world.gamemode} · ${world.difficulty}`;
        status.className = "world-entry-status";
        status.textContent = world.active ? "ACTIVE" : "";

        details.append(name, summary);
        entry.append(details, status);
        list.appendChild(entry);
    }
}

async function loadWorlds() {
    const result = await runApi(() => api.worlds());

    if (!result?.data?.worlds) {
        return;
    }

    const worlds = result.data.worlds;
    renderWorldList(worlds);

    const active = worlds.find((world) => world.active);

    if (active) {
        await loadWorld(active.id);
    } else if (!selectedWorld && worlds[0]) {
        await loadWorld(worlds[0].id);
    }
}

/* =========================================================
   START / STOP
   ========================================================= */

$("#startButton").addEventListener("click", async () => {
    if (!selectedWorld) {
        return;
    }

    $("#startButton").textContent = "STARTING...";
    $("#startButton").disabled = true;

    const result = await runApi(() => api.start(selectedWorld.id));

    if (result?.data) {
        setServerState(result.data.state || "STARTING", result.data);
        logConsole(`[manager] Starting ${selectedWorld.id}...`);
    } else {
        $("#startButton").textContent = "▶ Start Server";
    }
});

$("#stopButton").addEventListener("click", async () => {
    $("#stopButton").disabled = true;

    const result = await runApi(() => api.stop());

    if (result?.data) {
        setServerState(result.data.state || "STOPPING", result.data);
        logConsole("[manager] Stop requested.");
    }
});

/* =========================================================
   CONSOLE
   ========================================================= */

function logConsole(message) {
    const line = document.createElement("span");
    line.textContent = `[${new Date().toLocaleTimeString()}] ${message}`;
    $("#consoleOutput").appendChild(line);
    $("#consoleOutput").scrollTop = $("#consoleOutput").scrollHeight;
}

function appendConsoleOutput(message) {
    if (!message) {
        return;
    }

    const lines = String(message).split(/\r?\n/);
    for (const line of lines) {
        if (line.length > 0) {
            logConsole(line);
        }
    }
}

function connectConsoleStream() {
    if (consoleStream) {
        return;
    }

    consoleStream = new EventSource(`${API_BASE}/console/stream`);

    consoleStream.onmessage = (event) => {
        try {
            const payload = JSON.parse(event.data);
            appendConsoleOutput(payload.output ?? payload.message ?? event.data);
        } catch {
            appendConsoleOutput(event.data);
        }
    };

    consoleStream.onerror = () => {
        // EventSource automatically retries. Do not spam the console.
    };
}

$("#consoleForm").addEventListener("submit", async (event) => {
    event.preventDefault();

    const input = $("#consoleInput");
    const command = input.value.trim();

    if (!command) {
        return;
    }

    logConsole(`> ${command}`);
    input.value = "";

    const result = await runApi(() => api.console(command));

    if (result?.data) {
        appendConsoleOutput(result.data.stdout);
        appendConsoleOutput(result.data.stderr);
    }
});

/* =========================================================
   QUICK ACTIONS / WORLD OPERATIONS
   ========================================================= */

$("#quickConsole").addEventListener("click", () => showPage("console"));

$("#quickBackup").addEventListener("click", async () => {
    showPage("world");
    await backupSelectedWorld();
});

async function backupSelectedWorld() {
    if (!selectedWorld) return;
    const result = await runApi(() => api.backup(selectedWorld.id));
    if (result) logConsole(`[manager] Backup requested for ${selectedWorld.id}.`);
}

$("#backupButton").addEventListener("click", backupSelectedWorld);

$("#restoreButton").addEventListener("click", async () => {
    const result = await runApi(() => api.backups());
    if (!result?.data?.backups?.length) {
        alert("No backups are available.");
        return;
    }

    const choices = result.data.backups.map((backup) =>
        typeof backup === "string" ? backup : backup.filename
    ).filter(Boolean);

    const backup = prompt(`Enter the backup filename to restore:\n\n${choices.join("\n")}`);
    if (!backup) return;

    const restored = await runApi(() => api.restore(backup));
    if (restored) logConsole(`[manager] Restore requested: ${backup}`);
});

$("#pregenerateButton").addEventListener("click", async () => {
    if (!selectedWorld) return;

    const radius = Number(prompt("Pregeneration radius in chunks:", "500"));
    if (!Number.isFinite(radius) || radius <= 0) return;

    const result = await runApi(() => api.pregenerate(selectedWorld.id, radius));
    if (result) logConsole(`[manager] Pregeneration requested for ${selectedWorld.id}.`);
});

$("#deleteWorldButton").addEventListener("click", async () => {
    if (!selectedWorld) return;

    const confirmed = confirm(
        `Delete world '${selectedWorld.id}'?\n\n` +
        "The backend will enforce its own safety checks."
    );

    if (!confirmed) return;

    const result = await runApi(() => api.deleteWorld(selectedWorld.id));
    if (result) {
        logConsole(`[manager] Deleted world ${selectedWorld.id}.`);
        await loadWorlds();
    }
});

/* =========================================================
   SETTINGS
   ========================================================= */

$("#saveSettingsButton").addEventListener("click", async () => {
    if (!selectedWorld) return;

    const config = {
        ...selectedWorld,
        gamemode: $("#settingsGamemode").value,
        difficulty: $("#settingsDifficulty").value,
        max_players: Number($("#settingsMaxPlayers").value),
        view_distance: Number($("#settingsViewDistance").value),
        simulation_distance: Number($("#settingsSimulationDistance").value),
        hardcore: $("#settingsHardcore").checked,
        generate_structures: $("#settingsStructures").checked,
        structures: $("#settingsStructures").checked,
        pvp: $("#settingsPvp").checked
    };

    const result = await runApi(() => api.updateWorld(selectedWorld.id, config));

    if (result?.data?.world) {
        selectedWorld = normaliseWorld(result.data.world);
        renderSelectedWorld();
        logConsole(`[manager] Saved settings for ${selectedWorld.id}.`);
    }
});

/* =========================================================
   WORLD LIST / ACTIVATION
   ========================================================= */

$("#worldList").addEventListener("click", async (event) => {
    const entry = event.target.closest(".world-entry");
    if (!entry) return;

    const id = entry.dataset.worldId;
    if (!id || id === selectedWorld?.id) return;

    const result = await runApi(() => api.activate(id));
    if (!result) return;

    $$(".world-entry").forEach((item) => item.classList.remove("active"));
    entry.classList.add("active");

    await loadWorld(id);
    logConsole(`[manager] Activated world ${id}.`);
});

/* =========================================================
   CREATE WORLD MODAL
   ========================================================= */

const createWorldModal = $("#createWorldModal");
const createWorldButton = $("#createWorldButton");
const closeCreateWorld = $("#closeCreateWorld");
const cancelCreateWorld = $("#cancelCreateWorld");
const createWorldForm = $("#createWorldForm");
const worldSeed = $("#worldSeed");

function openCreateWorld() {
    createWorldModal.classList.add("open");
    document.body.style.overflow = "hidden";
    createWorldModal.setAttribute("aria-hidden", "false");
    requestAnimationFrame(() => $("#worldId")?.focus());
}

function closeCreateWorldModal() {
    createWorldModal.classList.remove("open");
    document.body.style.overflow = "";
    createWorldModal.setAttribute("aria-hidden", "true");
}

createWorldButton.addEventListener("click", openCreateWorld);
closeCreateWorld.addEventListener("click", closeCreateWorldModal);
cancelCreateWorld.addEventListener("click", closeCreateWorldModal);

$$('input[name="seedMode"]').forEach((radio) => {
    radio.addEventListener("change", () => {
        const custom = $('input[name="seedMode"]:checked').value === "custom";
        worldSeed.disabled = !custom;
        if (!custom) worldSeed.value = "";
    });
});

createWorldModal.addEventListener("click", (event) => {
    if (event.target === createWorldModal) closeCreateWorldModal();
});

createWorldForm.addEventListener("submit", async (event) => {
    event.preventDefault();

    const customSeed = $('input[name="seedMode"]:checked').value === "custom";

    const config = {
        id: $("#worldId").value.trim(),
        name: $("#worldName").value.trim(),
        seed: customSeed ? worldSeed.value.trim() : null,
        gamemode: $("#worldGamemode").value,
        difficulty: $("#worldDifficulty").value,
        hardcore: $("#worldHardcore").checked,
        generate_structures: $("#worldStructures").checked,
        structures: $("#worldStructures").checked,
        pvp: $("#worldPvp").checked,
        max_players: Number($("#worldMaxPlayers").value),
        view_distance: Number($("#worldViewDistance").value),
        simulation_distance: Number($("#worldSimulationDistance").value)
    };

    if (!config.id || !config.name) {
        alert("World ID and name are required.");
        return;
    }

    const result = await runApi(() => api.createWorld(config));
    if (!result) return;

    closeCreateWorldModal();
    await loadWorlds();
    logConsole(`[manager] Created world ${config.id}.`);
});

/* =========================================================
   DIAGNOSTICS
   ========================================================= */

$("#testButton").addEventListener("click", async () => {
    const button = $("#testButton");
    const status = $("#testStatus");
    const substatus = $("#testSubstatus");
    const log = $("#diagnosticLog");

    button.disabled = true;
    button.textContent = "Running...";
    status.textContent = "Running";
    substatus.textContent = "Executing the manager integration test...";
    log.textContent = "[self-test] requesting backend...\n";

    const result = await runApi(() => api.selfTest(), { log: false });

    if (!result) {
        log.textContent += "[self-test] API request failed.\n";
        status.textContent = "Failed";
        substatus.textContent = "The API could not be reached or returned an error.";
    } else {
        const data = result.data || {};
        log.textContent =
            `${data.stdout || ""}` +
            (data.stderr ? `\n${data.stderr}` : "");

        if (data.exit_code != null) {
            log.textContent += `\n\nExit code: ${data.exit_code}`;
        }

        const passed = data.passed ?? data.exit_code === 0;
        status.textContent = passed ? "Passed" : "Failed";
        substatus.textContent = passed
            ? "Backend self-test completed successfully."
            : "Backend self-test reported a failure.";
    }

    log.scrollTop = log.scrollHeight;
    button.disabled = false;
    button.textContent = "Run Full Self-Test";
});

/* =========================================================
   INITIALISATION
   ========================================================= */

async function initialise() {
    closeSidebar();
    closeCreateWorldModal();
    setServerState("STOPPED");

    connectConsoleStream();
    startStatusPolling();

    await loadWorlds();
    await refreshStatus();
}

initialise();
