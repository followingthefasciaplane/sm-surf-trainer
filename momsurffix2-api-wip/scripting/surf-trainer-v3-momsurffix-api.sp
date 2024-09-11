#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <momsurffix2>

#pragma semicolon 1
#pragma newdecls required

#define PLUGIN_VERSION "3.0"
#define MAX_STATS_ENTRIES 100
#define MAX_PREDICTION_POINTS 10
#define STOP_EPSILON 0.1
#define STATS_UPDATE_INTERVAL 0.5
#define MAX_STUCK_POSITIONS 10
#define COORDINATES 3
#define MAX_AIR_SPEED 30.0

public Plugin myinfo = {
    name = "Surf Trainer v3",
    author = "jessetooler",
    description = "A comprehensive plugin to help players improve their surfing skills",
    version = PLUGIN_VERSION,
    url = "utube.com"
};

enum struct PlayerStats {
    float lastProcessTime;
    bool touchingRamp;
    float boardEfficiencies[MAX_STATS_ENTRIES];
    int boardEfficiencyIndex;
    float averageSpeed;
    float totalAirTime;
    float lastGroundTime;
    int totalBoards;
    float lastBumpVelocity[3];
    float lastClipVelocity[3];
    bool hasBumped;
    bool hasClipped;
    float preBoardVelocity[3];
    float currentVelocity[3];
    float currentOrigin[3];
    int bumpIterations;
    float entryAngle;
    float exitAngle;
    float speedRetention;
    int stuckCount;
    float stuckPositions[MAX_STUCK_POSITIONS * COORDINATES];
}

// Globals
ConVar g_cvDebugMode, g_cvPerfectBoardThreshold;
ConVar g_cvAirAccelerate;
PlayerStats g_PlayerStats[MAXPLAYERS + 1];
int g_BeamSprite;
Handle g_HudSync;
bool g_PluginReady = false;
float g_flTickInterval;

public void OnPluginStart() {
    LoadTranslations("surf_trainer.phrases");
    
    CreateConVar("sm_surftrainer_version", PLUGIN_VERSION, "Surf trainer version", FCVAR_NOTIFY | FCVAR_DONTRECORD);
    g_cvDebugMode = CreateConVar("sm_surftrainer_debug", "0", "Enable debug mode", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    g_cvPerfectBoardThreshold = CreateConVar("sm_surftrainer_threshold", "2.0", "Threshold for perfect board detection (in units)", FCVAR_NOTIFY, true, 0.0);

    // Find the sv_airaccelerate ConVar
    g_cvAirAccelerate = FindConVar("sv_airaccelerate");
    if (g_cvAirAccelerate == null) {
        SetFailState("Failed to find sv_airaccelerate ConVar");
    }

    AutoExecConfig(true, "surf_trainer");

    g_HudSync = CreateHudSynchronizer();

    HookEvent("player_spawn", Event_PlayerSpawn);

    RegConsoleCmd("sm_surfstats", Command_SurfStats, "Display surf statistics");
    RegConsoleCmd("sm_surfsettings", Command_SurfSettings, "Open surf trainer settings menu");

    for (int i = 1; i <= MaxClients; i++) {
        if (IsClientInGame(i)) {
            OnClientPutInServer(i);
        }
    }

    g_flTickInterval = GetTickInterval();
}

public void OnMapStart() {
    g_BeamSprite = PrecacheModel("materials/sprites/laserbeam.vmt");
    
    char currentMap[PLATFORM_MAX_PATH];
    GetCurrentMap(currentMap, sizeof(currentMap));
    LoadMapConfig(currentMap);
    
    for (int i = 1; i <= MaxClients; i++) {
        if (IsClientInGame(i)) {
            ResetClientState(i);
        }
    }
}

public void OnClientPutInServer(int client) {
    SDKHook(client, SDKHook_PostThinkPost, OnPostThinkPost);
    ResetClientState(client);
}

public void OnClientDisconnect(int client) {
    SDKUnhook(client, SDKHook_PostThinkPost, OnPostThinkPost);
    SaveClientStats(client);
}

public void Event_PlayerSpawn(Event event, const char[] name, bool dontBroadcast) {
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (IsValidClient(client)) {
        ResetClientState(client);
    }
}

public void OnPostThinkPost(int client) {
    if (!g_PluginReady || !IsValidClient(client) || !IsPlayerAlive(client)) {
        return;
    }

    float currentTime = GetGameTime();
    if (currentTime - g_PlayerStats[client].lastProcessTime < g_flTickInterval) {
        return;
    }

    g_PlayerStats[client].lastProcessTime = currentTime;
    SimulatePlayerMovement(client);
}

void SimulatePlayerMovement(int client) {
    GetEntPropVector(client, Prop_Data, "m_vecVelocity", g_PlayerStats[client].currentVelocity);
    GetClientAbsOrigin(client, g_PlayerStats[client].currentOrigin);

    float surfaceNormal[3];
    bool isOnSurfRamp = IsPlayerOnSurfRamp(client, surfaceNormal);

    if (isOnSurfRamp && !g_PlayerStats[client].touchingRamp) {
        g_PlayerStats[client].touchingRamp = true;
        CopyVector(g_PlayerStats[client].currentVelocity, g_PlayerStats[client].preBoardVelocity);
        g_PlayerStats[client].entryAngle = CalculateAngleWithSurface(g_PlayerStats[client].currentVelocity, surfaceNormal);
    }
    else if (!isOnSurfRamp && g_PlayerStats[client].touchingRamp) {
        g_PlayerStats[client].touchingRamp = false;
        g_PlayerStats[client].exitAngle = CalculateAngleWithSurface(g_PlayerStats[client].currentVelocity, surfaceNormal);
        g_PlayerStats[client].speedRetention = CalculateSpeedRetention(g_PlayerStats[client].preBoardVelocity, g_PlayerStats[client].currentVelocity);
        AnalyzePerformance(client);
    }

    VisualizePredictedTrajectory(client, g_PlayerStats[client].currentVelocity);

    if (g_cvDebugMode.BoolValue) {
        float xyVelocity[3];
        xyVelocity[0] = g_PlayerStats[client].currentVelocity[0];
        xyVelocity[1] = g_PlayerStats[client].currentVelocity[1];
        xyVelocity[2] = 0.0;
        float xySpeed = GetVectorLength(xyVelocity);
        LogMessage("Player %N - Current XY Velocity: %.2f %.2f | XY Speed: %.2f", 
            client, xyVelocity[0], xyVelocity[1], xySpeed);
    }
}

public Action MomSurfFix_OnBumpIteration(int client, int bumpcount, float velocity[3], float origin[3]) {
    if (!IsValidClient(client)) {
        return Plugin_Continue;
    }

    g_PlayerStats[client].bumpIterations++;
    CopyVector(velocity, g_PlayerStats[client].lastBumpVelocity);

    if (g_cvDebugMode.BoolValue) {
        LogMessage("MomSurfFix_OnBumpIteration - Client: %d, Bump: %d, Velocity: %.2f %.2f %.2f", 
            client, bumpcount, velocity[0], velocity[1], velocity[2]);
    }

    return Plugin_Continue;
}

public Action MomSurfFix_OnClipVelocity(int client, float inVelocity[3], float normal[3], float &overbounce) {
    if (!IsValidClient(client)) {
        return Plugin_Continue;
    }

    CopyVector(inVelocity, g_PlayerStats[client].lastClipVelocity);
    float angle = CalculateAngleWithSurface(inVelocity, normal);

    if (g_cvDebugMode.BoolValue) {
        LogMessage("MomSurfFix_OnClipVelocity - Client: %d, Angle: %.2f, Overbounce: %.2f", 
            client, angle, overbounce);
    }

    return Plugin_Continue;
}

public void MomSurfFix_OnPlayerStuckOnRamp(int client, float velocity[3], float origin[3], float validPlane[3]) {
    if (!IsValidClient(client)) {
        return;
    }

    if (g_PlayerStats[client].stuckCount < MAX_STUCK_POSITIONS) {
        int index = g_PlayerStats[client].stuckCount * COORDINATES;
        g_PlayerStats[client].stuckPositions[index] = origin[0];
        g_PlayerStats[client].stuckPositions[index + 1] = origin[1];
        g_PlayerStats[client].stuckPositions[index + 2] = origin[2];
    }
    g_PlayerStats[client].stuckCount++;

    char advice[128];
    GenerateStuckAdvice(client, velocity, validPlane, advice, sizeof(advice));
    PrintToChat(client, "You're stuck! %s", advice);

    if (g_cvDebugMode.BoolValue) {
        LogMessage("MomSurfFix_OnPlayerStuckOnRamp - Client: %d, Velocity: %.2f %.2f %.2f, Origin: %.2f %.2f %.2f",
            client, velocity[0], velocity[1], velocity[2], origin[0], origin[1], origin[2]);
    }
}

public void MomSurfFix_OnTryPlayerMovePost(int client, int blocked, float endVelocity[3], float endOrigin[3], float allFraction) {
    if (!IsValidClient(client)) {
        return;
    }

    float speedChange = GetVectorLength(endVelocity) - GetVectorLength(g_PlayerStats[client].currentVelocity);
    float distanceMoved = GetVectorDistance(endOrigin, g_PlayerStats[client].currentOrigin);

    if (g_cvDebugMode.BoolValue) {
        LogMessage("MomSurfFix_OnTryPlayerMovePost - Client: %d, Speed Change: %.2f, Distance Moved: %.2f",
            client, speedChange, distanceMoved);
    }

    UpdatePerformanceMetrics(client, speedChange, distanceMoved, allFraction);
}

public void MomSurfFix_OnPluginReady() {
    g_PluginReady = true;
    LogMessage("MomSurfFix2 API is ready. Surf Trainer is now fully operational.");
}

void AnalyzePerformance(int client) {
    float efficiency = CalculateSurfEfficiency(client);
    char feedback[256];
    GeneratePerformanceFeedback(client, efficiency, feedback, sizeof(feedback));
    DisplayPerformanceFeedback(client, feedback, efficiency);
    StoreEfficiency(client, efficiency);
}

float CalculateSurfEfficiency(int client) {
    float speedEfficiency = g_PlayerStats[client].speedRetention * 100.0;
    float angleEfficiency = (1.0 - (FloatAbs(g_PlayerStats[client].exitAngle - g_PlayerStats[client].entryAngle) / 180.0)) * 100.0;
    return (speedEfficiency + angleEfficiency) / 2.0;
}

void GeneratePerformanceFeedback(int client, float efficiency, char[] feedback, int maxlen) {
    if (efficiency >= 90.0) {
        FormatEx(feedback, maxlen, "Excellent surf! Great speed retention and angle control.");
    } else if (efficiency >= 70.0) {
        FormatEx(feedback, maxlen, "Good surf. Try to maintain your speed and angle better.");
    } else {
        FormatEx(feedback, maxlen, "Room for improvement. Focus on your entry angle and speed control.");
    }

    Format(feedback, maxlen, "%s\nEntry Angle: %.2f°, Exit Angle: %.2f°, Speed Retention: %.2f%%",
        feedback, g_PlayerStats[client].entryAngle, g_PlayerStats[client].exitAngle, g_PlayerStats[client].speedRetention * 100.0);
}

void DisplayPerformanceFeedback(int client, const char[] feedback, float efficiency) {
    if (g_HudSync == null) return;

    int color1[4], color2[4] = {0, 0, 0, 0};
    if (efficiency >= 90.0) {
        color1 = {0, 255, 0, 255};
    } else if (efficiency >= 70.0) {
        color1 = {255, 255, 0, 255};
    } else {
        color1 = {255, 0, 0, 255};
    }

    SetHudTextParamsEx(-1.0, 0.25, 5.0, color1, color2, 0, 0.1, 0.1, 0.1);
    ShowSyncHudText(client, g_HudSync, "Surf Performance:\n%s", feedback);
}

void GenerateStuckAdvice(int client, float velocity[3], float validPlane[3], char[] advice, int maxlen) {
    float angle = CalculateAngleWithSurface(velocity, validPlane);
    
    if (angle < 10.0) {
        FormatEx(advice, maxlen, "Angle < 10.");
    } else if (angle > 80.0) {
        FormatEx(advice, maxlen, "Angle > 80.");
    } else {
        FormatEx(advice, maxlen, "Angle stuck.");
    }
}

void UpdatePerformanceMetrics(int client, float speedChange, float distanceMoved, float allFraction) {
    // This function can be expanded to store more detailed metrics
    g_PlayerStats[client].averageSpeed = (g_PlayerStats[client].averageSpeed * g_PlayerStats[client].totalBoards + GetVectorLength(g_PlayerStats[client].currentVelocity)) / (g_PlayerStats[client].totalBoards + 1);
    g_PlayerStats[client].totalBoards++;
}

void VisualizePredictedTrajectory(int client, const float initialVelocity[3]) {
    float clientPos[3], eyeAngles[3];
    GetClientAbsOrigin(client, clientPos);
    GetClientEyeAngles(client, eyeAngles);
    
    int color[4] = {0, 255, 0, 255};
    float beamWidth = 1.0;
    float beamLife = 0.1;
    
    float simulatedVelocity[3], simulatedPosition[3], prevPosition[3];
    CopyVector(initialVelocity, simulatedVelocity);
    CopyVector(clientPos, simulatedPosition);
    CopyVector(clientPos, prevPosition);
    
    for (int i = 1; i <= MAX_PREDICTION_POINTS; i++) {
        float nextSimulatedVelocity[3], nextSimulatedPosition[3];
        CopyVector(simulatedVelocity, nextSimulatedVelocity);
        CopyVector(simulatedPosition, nextSimulatedPosition);
        
        SimulatePoint(client, nextSimulatedPosition, nextSimulatedVelocity, eyeAngles, g_flTickInterval);
        
        TE_SetupBeamPoints(prevPosition, nextSimulatedPosition, g_BeamSprite, 0, 0, 60, beamLife, beamWidth, beamWidth, 1, 0.0, color, 0);
        TE_SendToClient(client);
        
        CopyVector(nextSimulatedVelocity, simulatedVelocity);
        CopyVector(nextSimulatedPosition, prevPosition);
        CopyVector(nextSimulatedPosition, simulatedPosition);
    }

    char velocityText[128];
    float speed = GetVectorLength(simulatedVelocity);
    Format(velocityText, sizeof(velocityText), "Predicted Speed: %.2f u/s", speed);
    PrintHintText(client, velocityText);
}

void SimulatePoint(int client, float position[3], float velocity[3], float angles[3], float time) {
    float gravity[3] = {0.0, 0.0, -800.0}; // Assuming default gravity
    float wishdir[3], wishvel[3];
    float wishspeed;

    // Apply gravity
    for (int i = 0; i < 3; i++) {
        velocity[i] += gravity[i] * time;
    }

    // Simulate air movement
    AirMove(velocity, angles, wishdir, wishvel, wishspeed);
    AirAccelerate(velocity, wishdir, wishspeed, g_cvAirAccelerate.FloatValue, time);  // Use the ConVar value here

    // Update position
    for (int i = 0; i < 3; i++) {
        position[i] += velocity[i] * time;
    }

    // Check for collision
    Handle trace = TR_TraceRayFilterEx(position, velocity, MASK_PLAYERSOLID, RayType_Infinite, TraceFilter_WorldOnly, client);

    if (TR_DidHit(trace)) {
        float endPosition[3], normal[3];
        TR_GetEndPosition(endPosition, trace);
        TR_GetPlaneNormal(trace, normal);

        // Adjust position to the collision point
        CopyVector(endPosition, position);

        // Reflect velocity off the surface
        float dot = GetVectorDotProduct(velocity, normal);
        for (int i = 0; i < 3; i++) {
            velocity[i] = velocity[i] - (2.0 * dot * normal[i]);
        }
    }

    delete trace;
}

void AirMove(float velocity[3], float angles[3], float wishdir[3], float wishvel[3], float &wishspeed) {
    float fmove = 0.0; // Assume no forward/back movement input
    float smove = 0.0; // Assume no side movement input

    AngleVectors(angles, wishvel, NULL_VECTOR, NULL_VECTOR);
    wishvel[2] = 0.0;
    NormalizeVector(wishvel, wishdir);
    
    for (int i = 0; i < 2; i++)
        wishvel[i] = wishdir[i] * fmove + wishvel[i] * smove;
    wishvel[2] = 0.0;

    wishspeed = GetVectorLength(wishvel);
    if (wishspeed > MAX_AIR_SPEED) {
        float scale = MAX_AIR_SPEED / wishspeed;
        ScaleVector(wishvel, scale);
        wishspeed = MAX_AIR_SPEED;
    }
}

void AirAccelerate(float velocity[3], float wishdir[3], float wishspeed, float accel, float deltaTime) {
    float currentspeed = GetVectorDotProduct(velocity, wishdir);
    float addspeed = wishspeed - currentspeed;
    if (addspeed <= 0)
        return;

    float accelspeed = accel * wishspeed * deltaTime;
    if (accelspeed > addspeed)
        accelspeed = addspeed;

    for (int i = 0; i < 3; i++)
        velocity[i] += accelspeed * wishdir[i];
}

void AngleVectors(const float angles[3], float fw[3], float right[3], float up[3]) {
    float sr, sp, sy, cr, cp, cy;
    
    float radx = DegToRad(angles[0]);
    float rady = DegToRad(angles[1]);
    float radz = DegToRad(angles[2]);
    
    sp = Sine(radx);
    cp = Cosine(radx);
    sy = Sine(rady);
    cy = Cosine(rady);
    sr = Sine(radz);
    cr = Cosine(radz);
    
    if (fw[0] != 0.0 || fw[1] != 0.0 || fw[2] != 0.0) {
        fw[0] = float(cp * cy);
        fw[1] = float(cp * sy);
        fw[2] = float(-sp);
    }
    
    if (right[0] != 0.0 || right[1] != 0.0 || right[2] != 0.0) {
        right[0] = float((-1 * sr * sp * cy + -1 * cr * -sy));
        right[1] = float((-1 * sr * sp * sy + -1 * cr * cy));
        right[2] = float(-1 * sr * cp);
    }
    
    if (up[0] != 0.0 || up[1] != 0.0 || up[2] != 0.0) {
        up[0] = float((cr * sp * cy + -sr * -sy));
        up[1] = float((cr * sp * sy + -sr * cy));
        up[2] = float(cr * cp);
    }
}

public bool TraceFilter_WorldOnly(int entity, int contentsMask, any data) {
    return entity == 0;
}

float CalculateAngleWithSurface(float velocity[3], float normal[3]) {
    float normalizedVelocity[3];
    NormalizeVector(velocity, normalizedVelocity);
    return RadToDeg(ArcCosine(GetVectorDotProduct(normalizedVelocity, normal)));
}

float CalculateSpeedRetention(float initialVelocity[3], float finalVelocity[3]) {
    float initialSpeed = GetVectorLength(initialVelocity);
    float finalSpeed = GetVectorLength(finalVelocity);
    return (initialSpeed > 0.0) ? (finalSpeed / initialSpeed) : 0.0;
}

void StoreEfficiency(int client, float efficiency) {
    g_PlayerStats[client].boardEfficiencies[g_PlayerStats[client].boardEfficiencyIndex] = efficiency;
    g_PlayerStats[client].boardEfficiencyIndex = (g_PlayerStats[client].boardEfficiencyIndex + 1) % MAX_STATS_ENTRIES;
}

bool IsPlayerOnSurfRamp(int client, float surfaceNormal[3]) {
    float startPos[3], endPos[3], mins[3], maxs[3];
    GetClientAbsOrigin(client, startPos);
    GetClientMins(client, mins);
    GetClientMaxs(client, maxs);

    for (int i = 0; i < 3; i++) {
        endPos[i] = startPos[i] + (i == 2 ? -1.0 : 1.0) * 64.0;
    }

    Handle trace = TR_TraceHullFilterEx(startPos, endPos, mins, maxs, MASK_PLAYERSOLID, TraceFilter_WorldOnly, client);

    if (TR_DidHit(trace)) {
        TR_GetPlaneNormal(trace, surfaceNormal);
        delete trace;
        return (surfaceNormal[2] < 0.7 && surfaceNormal[2] > 0.0);
    }

    delete trace;
    return false;
}

public Action Command_SurfStats(int client, int args) {
    if (!IsValidClient(client)) return Plugin_Handled;

    DisplaySurfStats(client);

    return Plugin_Handled;
}

void DisplaySurfStats(int client) {
    float avgEfficiency = CalculateAverageEfficiency(client);
    int totalBoards = g_PlayerStats[client].totalBoards;
    float bestEfficiency = GetBestEfficiency(client);
    float recentAvgEfficiency = CalculateRecentAverageEfficiency(client, 10);

    char formattedAvgEfficiency[32], formattedBestEfficiency[32], formattedRecentAvgEfficiency[32];
    
    FormatEfficiencyWithColor(avgEfficiency, formattedAvgEfficiency, sizeof(formattedAvgEfficiency));
    FormatEfficiencyWithColor(bestEfficiency, formattedBestEfficiency, sizeof(formattedBestEfficiency));
    FormatEfficiencyWithColor(recentAvgEfficiency, formattedRecentAvgEfficiency, sizeof(formattedRecentAvgEfficiency));

    SetHudTextParams(-1.0, 0.1, 10.0, 255, 255, 255, 255, 0, 0.1, 0.1, 0.1);
    ShowSyncHudText(client, g_HudSync, "Surf Statistics:\nAverage Efficiency: %s\nTotal Boards: %d\nBest Efficiency: %s\nRecent Avg (Last 10): %s\nAverage Speed: %.2f\nTotal Air Time: %.2f", 
        formattedAvgEfficiency, totalBoards, formattedBestEfficiency, formattedRecentAvgEfficiency, g_PlayerStats[client].averageSpeed, g_PlayerStats[client].totalAirTime);
}

float CalculateAverageEfficiency(int client) {
    float total = 0.0;
    int count = 0;
    for (int i = 0; i < MAX_STATS_ENTRIES; i++) {
        if (g_PlayerStats[client].boardEfficiencies[i] != 0.0) {
            total += g_PlayerStats[client].boardEfficiencies[i];
            count++;
        }
    }
    return (count > 0) ? (total / float(count)) : 0.0;
}

float GetBestEfficiency(int client) {
    float best = 0.0;
    for (int i = 0; i < MAX_STATS_ENTRIES; i++) {
        if (g_PlayerStats[client].boardEfficiencies[i] > best) {
            best = g_PlayerStats[client].boardEfficiencies[i];
        }
    }
    return best;
}

float CalculateRecentAverageEfficiency(int client, int recentCount) {
    float total = 0.0;
    int count = 0;
    int startIndex = (g_PlayerStats[client].boardEfficiencyIndex - 1 + MAX_STATS_ENTRIES) % MAX_STATS_ENTRIES;
    
    for (int i = 0; i < recentCount && i < MAX_STATS_ENTRIES; i++) {
        int index = (startIndex - i + MAX_STATS_ENTRIES) % MAX_STATS_ENTRIES;
        if (g_PlayerStats[client].boardEfficiencies[index] != 0.0) {
            total += g_PlayerStats[client].boardEfficiencies[index];
            count++;
        } else {
            break;
        }
    }
    
    return (count > 0) ? (total / float(count)) : 0.0;
}

void FormatEfficiencyWithColor(float efficiency, char[] buffer, int bufferSize) {
    char colorCode[16];
    if (efficiency >= 90.0) {
        strcopy(colorCode, sizeof(colorCode), "\x04");
    } else if (efficiency >= 70.0) {
        strcopy(colorCode, sizeof(colorCode), "\x09");
    } else {
        strcopy(colorCode, sizeof(colorCode), "\x02");
    }
    
    Format(buffer, bufferSize, "%s%.2f%%\x01", colorCode, efficiency);
}

public Action Command_SurfSettings(int client, int args) {
    if (!IsValidClient(client)) return Plugin_Handled;

    OpenSettingsMenu(client);

    return Plugin_Handled;
}

void OpenSettingsMenu(int client) {
    Menu menu = new Menu(SettingsMenuHandler);
    menu.SetTitle("Surf Trainer Settings");

    menu.AddItem("debug", g_cvDebugMode.BoolValue ? "Disable Debug Mode" : "Enable Debug Mode");
    menu.AddItem("threshold", "Adjust Perfect Board Threshold");

    menu.ExitButton = true;
    menu.Display(client, MENU_TIME_FOREVER);
}

public int SettingsMenuHandler(Menu menu, MenuAction action, int param1, int param2) {
    switch (action) {
        case MenuAction_Select: {
            char info[32];
            menu.GetItem(param2, info, sizeof(info));

            if (StrEqual(info, "debug")) {
                ToggleDebugMode(param1);
            }
            else if (StrEqual(info, "threshold")) {
                OpenThresholdMenu(param1);
            }
        }
        case MenuAction_End: {
            delete menu;
        }
    }

    return 0;
}

void ToggleDebugMode(int client) {
    g_cvDebugMode.SetBool(!g_cvDebugMode.BoolValue);
    PrintToChat(client, "Debug mode %s", g_cvDebugMode.BoolValue ? "enabled" : "disabled");
    OpenSettingsMenu(client);
}

void OpenThresholdMenu(int client) {
    Menu menu = new Menu(ThresholdMenuHandler);
    menu.SetTitle("Adjust Perfect Board Threshold");

    char buffer[32];
    for (float threshold = 1.0; threshold <= 5.0; threshold += 0.5) {
        FormatEx(buffer, sizeof(buffer), "%.1f", threshold);
        menu.AddItem(buffer, buffer);
    }

    menu.ExitBackButton = true;
    menu.Display(client, MENU_TIME_FOREVER);
}

public int ThresholdMenuHandler(Menu menu, MenuAction action, int param1, int param2) {
    switch (action) {
        case MenuAction_Select: {
            char info[32];
            menu.GetItem(param2, info, sizeof(info));
            float newThreshold = StringToFloat(info);
            g_cvPerfectBoardThreshold.SetFloat(newThreshold);
            PrintToChat(param1, "Perfect board threshold set to %.1f", newThreshold);
            OpenSettingsMenu(param1);
        }
        case MenuAction_Cancel: {
            if (param2 == MenuCancel_ExitBack) {
                OpenSettingsMenu(param1);
            }
        }
        case MenuAction_End: {
            delete menu;
        }
    }

    return 0;
}

void ResetClientState(int client) {
    g_PlayerStats[client].lastProcessTime = 0.0;
    g_PlayerStats[client].touchingRamp = false;
    g_PlayerStats[client].boardEfficiencyIndex = 0;
    g_PlayerStats[client].averageSpeed = 0.0;
    g_PlayerStats[client].totalAirTime = 0.0;
    g_PlayerStats[client].lastGroundTime = GetGameTime();
    g_PlayerStats[client].totalBoards = 0;
    g_PlayerStats[client].bumpIterations = 0;
    g_PlayerStats[client].entryAngle = 0.0;
    g_PlayerStats[client].exitAngle = 0.0;
    g_PlayerStats[client].speedRetention = 0.0;
    g_PlayerStats[client].stuckCount = 0;
    
    for (int i = 0; i < MAX_STATS_ENTRIES; i++) {
        g_PlayerStats[client].boardEfficiencies[i] = 0.0;
    }
    
    ZeroVector(g_PlayerStats[client].lastBumpVelocity);
    ZeroVector(g_PlayerStats[client].lastClipVelocity);
    ZeroVector(g_PlayerStats[client].preBoardVelocity);
    ZeroVector(g_PlayerStats[client].currentVelocity);
    ZeroVector(g_PlayerStats[client].currentOrigin);
}

void SaveClientStats(int client) {
    // TODO: Implement database storage for client stats
    if (g_cvDebugMode.BoolValue) {
        LogMessage("Saving stats for client %d", client);
    }
}

void LoadMapConfig(const char[] mapName) {
    char configPath[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, configPath, sizeof(configPath), "configs/surf_trainer/maps/%s.cfg", mapName);
    
    if (FileExists(configPath)) {
        ServerCommand("exec %s", configPath);
        if (g_cvDebugMode.BoolValue) {
            LogMessage("Loaded map-specific configuration: %s", configPath);
        }
    }
}

bool IsValidClient(int client) {
    return (client > 0 && client <= MaxClients && IsClientConnected(client) && IsClientInGame(client) && !IsFakeClient(client));
}

void ZeroVector(float vec[3]) {
    vec[0] = vec[1] = vec[2] = 0.0;
}

void CopyVector(const float src[3], float dest[3]) {
    dest[0] = src[0];
    dest[1] = src[1];
    dest[2] = src[2];
}

public void OnPluginEnd() {
    for (int i = 1; i <= MaxClients; i++) {
        if (IsClientInGame(i)) {
            SaveClientStats(i);
        }
    }

    if (g_HudSync != null) {
        CloseHandle(g_HudSync);
        g_HudSync = null;
    }
}

float GetVectorLength2D(const float vec[3]) {
    return SquareRoot(vec[0] * vec[0] + vec[1] * vec[1]);
}

float ClampFloat(float value, float min, float max) {
    if (value < min) return min;
    if (value > max) return max;
    return value;
}

void LogBoardAnalysis(int client, const float preBoardVelocity[3], const float currentVelocity[3], const float surfaceNormal[3], float efficiency) {
    if (!g_cvDebugMode.BoolValue) return;

    LogMessage("Board Analysis for client %d:", client);
    LogMessage("Pre-board velocity: %.2f %.2f %.2f | Speed: %.2f", 
        preBoardVelocity[0], preBoardVelocity[1], preBoardVelocity[2], GetVectorLength(preBoardVelocity));
    LogMessage("Post-board velocity: %.2f %.2f %.2f | Speed: %.2f", 
        currentVelocity[0], currentVelocity[1], currentVelocity[2], GetVectorLength(currentVelocity));
    LogMessage("Surface normal: %.2f %.2f %.2f", surfaceNormal[0], surfaceNormal[1], surfaceNormal[2]);
    LogMessage("Entry Angle: %.2f°, Exit Angle: %.2f°, Speed Retention: %.2f%%",
        g_PlayerStats[client].entryAngle, g_PlayerStats[client].exitAngle, g_PlayerStats[client].speedRetention * 100.0);
    LogMessage("Efficiency: %.2f%%", efficiency);
    LogMessage("Bump Iterations: %d", g_PlayerStats[client].bumpIterations);
}

void AnalyzeStuckPositions(int client) {
    if (g_PlayerStats[client].stuckCount == 0) return;

    float averageStuckPosition[3];
    for (int i = 0; i < g_PlayerStats[client].stuckCount && i < MAX_STUCK_POSITIONS; i++) {
        for (int j = 0; j < COORDINATES; j++) {
            averageStuckPosition[j] += g_PlayerStats[client].stuckPositions[i * COORDINATES + j];
        }
    }
    ScaleVector(averageStuckPosition, 1.0 / float(g_PlayerStats[client].stuckCount));

    char mapName[64];
    GetCurrentMap(mapName, sizeof(mapName));

    LogMessage("Stuck Analysis for client %d on map %s:", client, mapName);
    LogMessage("Total stuck count: %d", g_PlayerStats[client].stuckCount);
    LogMessage("Average stuck position: %.2f %.2f %.2f", 
        averageStuckPosition[0], averageStuckPosition[1], averageStuckPosition[2]);

    // TODO: Implement more advanced stuck position analysis
    // For example, cluster analysis to identify problematic areas
}

public void OnGameFrame() {
    if (!g_PluginReady) return;

    for (int client = 1; client <= MaxClients; client++) {
        if (!IsValidClient(client) || !IsPlayerAlive(client)) continue;

        if (g_PlayerStats[client].touchingRamp) {
            g_PlayerStats[client].totalAirTime += GetGameFrameTime();
        } else {
            g_PlayerStats[client].lastGroundTime = GetGameTime();
        }
    }
}

void DisplayDebugInfo(int client) {
    if (!g_cvDebugMode.BoolValue) return;

    char debugInfo[256];
    Format(debugInfo, sizeof(debugInfo), "Debug Info:\nVelocity: %.2f %.2f %.2f\nSpeed: %.2f\nBump Iterations: %d\nStuck Count: %d",
        g_PlayerStats[client].currentVelocity[0], g_PlayerStats[client].currentVelocity[1], g_PlayerStats[client].currentVelocity[2],
        GetVectorLength(g_PlayerStats[client].currentVelocity),
        g_PlayerStats[client].bumpIterations,
        g_PlayerStats[client].stuckCount);

    SetHudTextParams(0.7, 0.1, 0.1, 255, 255, 255, 255, 0, 0.0, 0.0, 0.0);
    ShowHudText(client, -1, debugInfo);
}

public Action Command_ResetStats(int client, int args) {
    if (!IsValidClient(client)) return Plugin_Handled;

    ResetClientState(client);
    PrintToChat(client, "Your surf stats have been reset.");

    return Plugin_Handled;
}

public void OnMapEnd() {
    for (int client = 1; client <= MaxClients; client++) {
        if (IsValidClient(client)) {
            SaveClientStats(client);
            AnalyzeStuckPositions(client);
        }
    }
}

public Action Command_SurfHelp(int client, int args) {
    if (!IsValidClient(client)) return Plugin_Handled;

    DisplayHelpMenu(client);

    return Plugin_Handled;
}

void DisplayHelpMenu(int client) {
    Menu menu = new Menu(HelpMenuHandler);
    menu.SetTitle("Surf Trainer Help");

    menu.AddItem("basics", "Surfing Basics");
    menu.AddItem("advanced", "Advanced Techniques");
    menu.AddItem("commands", "Available Commands");
    menu.AddItem("feedback", "Understanding Feedback");

    menu.ExitButton = true;
    menu.Display(client, MENU_TIME_FOREVER);
}

public int HelpMenuHandler(Menu menu, MenuAction action, int param1, int param2) {
    switch (action) {
        case MenuAction_Select: {
            char info[32];
            menu.GetItem(param2, info, sizeof(info));

            if (StrEqual(info, "basics")) {
                DisplaySurfingBasics(param1);
            }
            else if (StrEqual(info, "advanced")) {
                DisplayAdvancedTechniques(param1);
            }
            else if (StrEqual(info, "commands")) {
                DisplayAvailableCommands(param1);
            }
            else if (StrEqual(info, "feedback")) {
                DisplayFeedbackExplanation(param1);
            }
        }
        case MenuAction_End: {
            delete menu;
        }
    }

    return 0;
}

void DisplaySurfingBasics(int client) {
    PrintToChat(client, "Surfing Basics:");
    PrintToChat(client, "1. Approach the ramp at an angle");
    PrintToChat(client, "2. Don't press any movement keys while on the ramp. Always press W on the ramp.");
    PrintToChat(client, "3. Use your mouse to control your movement. Joystick is also recommended.");
    PrintToChat(client, "4. Try to maintain a consistent angle on the ramp");
}

void DisplayAdvancedTechniques(int client) {
    PrintToChat(client, "Advanced Techniques:");
    PrintToChat(client, "1. Pre-strafing: Gain speed before hitting the ramp");
    PrintToChat(client, "2. Ramp transfers: Smoothly transition between ramps");
    PrintToChat(client, "3. Air strafing: Gain speed in the air between ramps");
    PrintToChat(client, "4. Ramp skimming: Barely touch ramps for speed boosts");
}

void DisplayAvailableCommands(int client) {
    PrintToChat(client, "Available Commands:");
    PrintToChat(client, "!surfstats - Display your surfing statistics");
    PrintToChat(client, "!surfsettings - Open the Surf Trainer settings menu");
    PrintToChat(client, "!surfhelp - Display this help menu");
    PrintToChat(client, "!resetstats - Reset your surfing statistics");
}

void DisplayFeedbackExplanation(int client) {
    PrintToChat(client, "Understanding Feedback:");
    PrintToChat(client, "Entry Angle: Your angle when entering a ramp");
    PrintToChat(client, "Exit Angle: Your angle when leaving a ramp");
    PrintToChat(client, "Speed Retention: How much speed you maintain on a ramp");
    PrintToChat(client, "Efficiency: Overall measure of your surfing performance");
}

// TODO
